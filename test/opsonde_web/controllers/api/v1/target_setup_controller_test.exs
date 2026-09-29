defmodule OpsondeWeb.API.V1.TargetSetupControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Opsonde.{Accounts, Providers}
  alias Opsonde.Providers.Registry

  @password "correct horse battery staple"
  @provider_secret "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("target-api-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("target-api-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("target-api-viewer@example.com", @password, :viewer, actor: admin)

    target_provider =
      Providers.create_provider!(
        "target-api-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @provider_secret},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    inventory_provider =
      Providers.create_provider!(
        "inventory-api-provider",
        :inventory,
        "fixture-inventory",
        %{"source" => "netbox"},
        %{"token" => "inventory-provider-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{
      admin: admin,
      admin_token: token!(admin.email),
      operator: operator,
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email),
      target_provider: target_provider,
      inventory_provider: inventory_provider
    }
  end

  test "Target type catalog publishes custom choices per supported category", context do
    response = get_json("/api/v1/target-types", context.viewer_token)
    assert_operation_response(response)
    %{"data" => %{"categories" => categories, "types" => types}} = json_response(response, 200)

    assert length(categories) == 9
    assert Enum.any?(categories, &(&1["id"] == "storage"))

    by_id = Map.new(types, &{&1["id"], &1})
    refute Map.has_key?(by_id, "generic")

    assert by_id["custom-network-device"]["category_id"] == "network-device"

    assert by_id["custom-network-device"]["access_method_types"] == [
             "ssh",
             "netconf",
             "http-api"
           ]

    assert by_id["custom-os"]["category_id"] == "os"
    assert by_id["bmc"]["access_method_types"] == ["bmc-redfish", "bmc-ipmi"]
    assert by_id["cisco_ios_xe"]["category_id"] == "network-device"

    for type <- types, adapter_type <- type["access_method_types"] do
      assert {:ok, adapter} = Registry.fetch(adapter_type, Providers.Target)
      assert %Providers.Target.AccessMethodProfile{} = adapter.access_method_profile()
    end
  end

  test "Target creation enforces the published type and its kind", context do
    for {kind, type_id} <- [{"host", "unsupported-device"}, {"cluster", "linux"}] do
      response =
        post_json(
          "/api/v1/targets",
          %{
            "target" => %{
              "name" => "invalid-target",
              "kind" => kind,
              "type_id" => type_id,
              "facts" => %{}
            }
          },
          context.admin_token
        )

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    end
  end

  test "Access Method API rejects a Provider mismatch and accepts its declared binding",
       context do
    endpoint = "https://example.test"

    provider =
      Providers.create_provider!(
        "http-binding-provider",
        :target,
        "http-api",
        %{"endpoint" => endpoint},
        %{},
        actor: context.admin
      )
      |> then(
        &Providers.record_provider_check!(&1, &1.revision, :passed, nil, nil, authorize?: false)
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target = create_target!(context.admin_token, "http-binding-target", "host", "linux", nil)

    method = %{
      "target_id" => target["id"],
      "provider_id" => provider.id,
      "name" => "http-api",
      "method" => "http",
      "endpoint" => endpoint,
      "provider_revision" => provider.revision,
      "priority" => 100,
      "capabilities" => ["request.http.observe", "request.http.effect"]
    }

    invalid =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => %{method | "method" => "ipmi"}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)

    unknown_field =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => Map.put(method, "unexpected_property", "ignored")},
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(unknown_field, 400)

    bmc = create_target!(context.admin_token, "bmc-http-mismatch", "management_plane", "bmc", nil)

    wrong_target =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => %{method | "target_id" => bmc["id"]}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(wrong_target, 422)

    registered =
      post_data!("/api/v1/access-methods", %{"access_method" => method}, context.admin_token)

    assert registered["method"] == "http"
    assert registered["provider_id"] == provider.id
  end

  test "administrator registers a layered environment and every permitted access path", context do
    boundary =
      post_data!(
        "/api/v1/management-boundaries",
        %{
          "management_boundary" => %{
            "name" => "primary-dc",
            "kind" => "datacenter",
            "facts" => %{"region" => "jp"}
          }
        },
        context.admin_token
      )

    linux = create_target!(context.admin_token, "linux-01", "host", "linux", boundary["id"])

    kubernetes =
      create_target!(
        context.admin_token,
        "cluster-01",
        "cluster",
        "kubernetes",
        boundary["id"]
      )

    bmc = create_target!(context.admin_token, "bmc-01", "management_plane", "bmc", boundary["id"])

    ios_xe =
      create_target!(
        context.admin_token,
        "edge-01",
        "network_device",
        "cisco_ios_xe",
        boundary["id"]
      )

    junos =
      create_target!(
        context.admin_token,
        "edge-future",
        "network_device",
        "custom-network-device",
        boundary["id"]
      )

    identity =
      post_data!(
        "/api/v1/external-identities",
        %{
          "external_identity" => %{
            "target_id" => linux["id"],
            "source" => "zabbix",
            "kind" => "hostid",
            "value" => "10427"
          }
        },
        context.admin_token
      )

    assert identity["target_id"] == linux["id"]

    linux_ssh =
      create_access_method!(
        context,
        linux,
        "linux-ssh",
        "ssh",
        ["observe.command", "effect.command"]
      )

    ssh_exec =
      create_access_method!(
        context,
        junos,
        "ssh",
        "ssh",
        ["observe.command"]
      )

    ios_ssh =
      create_access_method!(
        context,
        ios_xe,
        "ios-ssh",
        "ssh_cli",
        ["observe.command", "effect.command"]
      )

    ios_netconf =
      create_access_method!(
        context,
        ios_xe,
        "ios-netconf",
        "netconf",
        ["observe.config", "effect.config"]
      )

    assert ssh_exec["method"] == "ssh"
    assert Enum.sort([ios_ssh["method"], ios_netconf["method"]]) == ["netconf", "ssh_cli"]
    assert linux_ssh["provider_id"] == context.target_provider.id

    hosted_by = create_relationship!(context.admin_token, kubernetes, linux, "hosted_by")
    managed_by = create_relationship!(context.admin_token, linux, bmc, "managed_by")
    assert hosted_by["source_target_id"] == kubernetes["id"]
    assert managed_by["destination_target_id"] == bmc["id"]

    updated =
      patch_json(
        "/api/v1/targets/#{linux["id"]}",
        %{
          "target" => %{
            "expected_revision" => linux["revision"],
            "operating_instructions" => "Do not modify root"
          }
        },
        context.admin_token
      )
      |> json_response(200)
      |> Map.fetch!("data")

    assert updated["operating_instructions"] == "Do not modify root"

    target_page = get_json("/api/v1/targets?limit=3", context.viewer_token)

    assert %{"data" => first_targets, "page" => %{"next" => cursor}} =
             json_response(target_page, 200)

    assert_operation_response(target_page)

    assert length(first_targets) == 3
    assert is_binary(cursor)

    method_page = get_json("/api/v1/access-methods", context.viewer_token)
    assert %{"data" => methods} = json_response(method_page, 200)
    assert_operation_response(method_page)

    assert Enum.sort(Enum.map(methods, & &1["name"])) ==
             ~w(ios-netconf ios-ssh linux-ssh ssh)

    for response <- [target_page, method_page] do
      refute response.resp_body =~ @provider_secret
      refute response.resp_body =~ "credentials"
      refute response.resp_body =~ "search_text"
    end
  end

  test "revision conflicts, invalid relationships and mutation policy are stable", context do
    target = create_target!(context.admin_token, "linux-02", "host", "linux", nil)

    updated =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 1, "facts" => %{"site" => "tokyo"}}},
        context.admin_token
      )

    assert %{"data" => %{"revision" => 2}} = json_response(updated, 200)
    assert_operation_response(updated)

    stale =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 1, "name" => "stale-name"}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    invalid_relationship =
      post_json(
        "/api/v1/target-relationships",
        %{
          "relationship" => %{
            "source_target_id" => target["id"],
            "destination_target_id" => target["id"],
            "kind" => "runs_on",
            "facts" => %{}
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(invalid_relationship, 422)

    for token <- [context.operator_token, context.viewer_token] do
      forbidden =
        post_json(
          "/api/v1/targets",
          %{
            "target" => %{
              "name" => "forbidden",
              "kind" => "host",
              "type_id" => "linux",
              "facts" => %{}
            }
          },
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      shown = get_json("/api/v1/targets/#{target["id"]}", token)
      assert %{"data" => %{"id" => id}} = json_response(shown, 200)
      assert_operation_response(shown)

      assert id == target["id"]
    end
  end

  test "manual and Provider inventory previews expose rows and apply only the accepted digest",
       context do
    csv =
      "external_id,identity_kind,name,kind,type_id,facts_json\r\n" <>
        "server-1,linux,linux-imported,host,linux,\"{\"\"cpu\"\":8}\"\r\n"

    preview =
      post_data!(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "netbox", "csv" => csv}},
        context.admin_token
      )

    assert preview["status"] == "previewed"
    assert preview["row_count"] == 1
    assert preview["error_count"] == 0

    imports = get_json("/api/v1/inventory-imports", context.viewer_token)
    assert %{"data" => [%{"id" => import_id}]} = json_response(imports, 200)
    assert import_id == preview["id"]
    assert_operation_response(imports)

    shown = get_json("/api/v1/inventory-imports/#{preview["id"]}", context.viewer_token)
    assert %{"data" => %{"id" => ^import_id}} = json_response(shown, 200)
    assert_operation_response(shown)

    rows = get_json("/api/v1/inventory-imports/#{preview["id"]}/rows", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "disposition" => "create",
                 "identity_value" => "server-1",
                 "errors" => []
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(rows, 200)

    assert_operation_response(rows)

    wrong_digest =
      post_json(
        "/api/v1/inventory-imports/#{preview["id"]}/apply",
        %{
          "inventory_import" => %{
            "expected_revision" => preview["revision"],
            "expected_digest" => String.duplicate("0", 64)
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(wrong_digest, 409)

    applied =
      post_json(
        "/api/v1/inventory-imports/#{preview["id"]}/apply",
        %{
          "inventory_import" => %{
            "expected_revision" => preview["revision"],
            "expected_digest" => preview["content_digest"]
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"status" => "applied", "revision" => 2}} =
             json_response(applied, 200)

    assert_operation_response(applied)

    assert %{"data" => targets} =
             get_json("/api/v1/targets", context.viewer_token) |> json_response(200)

    assert Enum.any?(targets, &(&1["name"] == "linux-imported"))

    provider_preview =
      post_data!(
        "/api/v1/inventory-imports/provider-preview",
        %{
          "inventory_import" => %{
            "source" => "netbox-provider",
            "provider_id" => context.inventory_provider.id,
            "provider_revision" => context.inventory_provider.revision,
            "scope" => %{}
          }
        },
        context.admin_token
      )

    assert provider_preview["source_type"] == "inventory"
    assert provider_preview["snapshot_status"] == "complete"
    assert provider_preview["row_count"] == 0

    forbidden =
      post_json(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "forbidden", "csv" => csv}},
        context.operator_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

    for response <- [rows, applied] do
      refute response.resp_body =~ "inventory-provider-secret"
      refute response.resp_body =~ "credentials"
    end
  end

  test "contract rejects malformed Target and inventory inputs before domain actions", context do
    invalid_id = get_json("/api/v1/targets/not-a-uuid", context.viewer_token)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => ["id"]}}} =
             json_response(invalid_id, 422)

    assert_operation_response(invalid_id)

    target = create_target!(context.admin_token, "revision-contract", "host", "linux", nil)

    invalid_revision =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 0, "name" => "invalid"}},
        context.admin_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["expected_revision"]}
             }
           } = json_response(invalid_revision, 422)

    assert_operation_response(invalid_revision)

    invalid_preview =
      post_json(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "netbox", "csv" => ""}},
        context.admin_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["csv"]}
             }
           } = json_response(invalid_preview, 422)

    assert_operation_response(invalid_preview)
  end

  defp create_target!(token, name, kind, type_id, boundary_id) do
    post_data!(
      "/api/v1/targets",
      %{
        "target" => %{
          "name" => name,
          "kind" => kind,
          "type_id" => type_id,
          "facts" => %{},
          "management_boundary_id" => boundary_id
        }
      },
      token
    )
  end

  defp create_access_method!(context, target, name, method, capabilities) do
    post_data!(
      "/api/v1/access-methods",
      %{
        "access_method" => %{
          "target_id" => target["id"],
          "provider_id" => context.target_provider.id,
          "name" => name,
          "method" => method,
          "endpoint" => "ssh://192.0.2.10:22",
          "provider_revision" => context.target_provider.revision,
          "priority" => 100,
          "capabilities" => capabilities
        }
      },
      context.admin_token
    )
  end

  defp create_relationship!(token, source, destination, kind) do
    post_data!(
      "/api/v1/target-relationships",
      %{
        "relationship" => %{
          "source_target_id" => source["id"],
          "destination_target_id" => destination["id"],
          "kind" => kind,
          "facts" => %{}
        }
      },
      token
    )
  end

  defp post_data!(path, body, token) do
    response = post_json(path, body, token)
    assert_operation_response(response)

    response
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => to_string(email), "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp post_json(path, body, token), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)
end
