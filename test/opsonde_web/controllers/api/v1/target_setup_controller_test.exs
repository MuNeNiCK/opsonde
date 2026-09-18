defmodule OpsondeWeb.API.V1.TargetSetupControllerTest do
  use OpsondeWeb.ConnCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Targets.{PolicyError, PolicyRequest}

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
      admin_token: token!(admin.email),
      operator: operator,
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email),
      target_provider: target_provider,
      inventory_provider: inventory_provider
    }
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

    bmc = create_target!(context.admin_token, "bmc-01", "bmc", "redfish", boundary["id"])

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
        "junos",
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
        "linux",
        "ssh",
        ["observe.command", "effect.command"]
      )

    generic_ssh =
      create_access_method!(
        context,
        junos,
        "generic-ssh",
        "generic",
        "ssh",
        ["observe.command"]
      )

    ios_ssh =
      create_access_method!(
        context,
        ios_xe,
        "ios-ssh",
        "cisco_ios_xe",
        "ssh_cli",
        ["observe.command", "effect.command"]
      )

    ios_netconf =
      create_access_method!(
        context,
        ios_xe,
        "ios-netconf",
        "cisco_ios_xe",
        "netconf",
        ["observe.config", "effect.config"]
      )

    assert generic_ssh["platform"] == "generic"
    assert Enum.sort([ios_ssh["method"], ios_netconf["method"]]) == ["netconf", "ssh_cli"]
    assert linux_ssh["provider_id"] == context.target_provider.id

    hosted_by = create_relationship!(context.admin_token, kubernetes, linux, "hosted_by")
    managed_by = create_relationship!(context.admin_token, linux, bmc, "managed_by")
    assert hosted_by["source_target_id"] == kubernetes["id"]
    assert managed_by["destination_target_id"] == bmc["id"]

    policy =
      post_data!(
        "/api/v1/target-policies",
        %{
          "target_policy" => %{
            "target_id" => linux["id"],
            "name" => "protect-credentials",
            "request_kinds" => ["observation", "effect"],
            "capabilities" => [],
            "operations" => [],
            "selector_match" => %{"path" => %{"prefix" => "/usr/credential"}},
            "parameter_match" => %{},
            "reason" => "credential directory is forbidden"
          }
        },
        context.admin_token
      )

    assert policy["target_id"] == linux["id"]

    blocked_request = %PolicyRequest{
      kind: :observation,
      authority_mode: :full_access,
      target_id: linux["id"],
      target_revision: linux["revision"],
      access_method_id: linux_ssh["id"],
      access_method_revision: linux_ssh["revision"],
      capability: "observe.command",
      operation: "filesystem.read",
      selectors: %{"path" => "/usr/credential/service/token"}
    }

    assert {:error, error} =
             Targets.clear_target_request(blocked_request, actor: context.operator)

    assert %PolicyError{category: :denied, policy_id: policy_id} = policy_error(error)
    assert policy_id == policy["id"]

    target_page = get_json("/api/v1/targets?limit=3", context.viewer_token)

    assert %{"data" => first_targets, "page" => %{"next" => cursor}} =
             json_response(target_page, 200)

    assert length(first_targets) == 3
    assert is_binary(cursor)

    method_page = get_json("/api/v1/access-methods", context.viewer_token)
    assert %{"data" => methods} = json_response(method_page, 200)

    assert Enum.sort(Enum.map(methods, & &1["name"])) ==
             ~w(generic-ssh ios-netconf ios-ssh linux-ssh)

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
              "platform" => "linux",
              "facts" => %{}
            }
          },
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      assert %{"data" => %{"id" => id}} =
               get_json("/api/v1/targets/#{target["id"]}", token) |> json_response(200)

      assert id == target["id"]
    end
  end

  test "manual and Provider inventory previews expose rows and apply only the accepted digest",
       context do
    csv =
      "external_id,identity_kind,name,kind,platform,facts_json\r\n" <>
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

  defp create_target!(token, name, kind, platform, boundary_id) do
    post_data!(
      "/api/v1/targets",
      %{
        "target" => %{
          "name" => name,
          "kind" => kind,
          "platform" => platform,
          "facts" => %{},
          "management_boundary_id" => boundary_id
        }
      },
      token
    )
  end

  defp create_access_method!(context, target, name, platform, method, capabilities) do
    post_data!(
      "/api/v1/access-methods",
      %{
        "access_method" => %{
          "target_id" => target["id"],
          "provider_id" => context.target_provider.id,
          "name" => name,
          "platform" => platform,
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
    post_json(path, body, token)
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => email, "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp post_json(path, body, token), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp policy_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %PolicyError{} = error -> error
      nested when is_map(nested) -> policy_error(nested)
      _other -> nil
    end)
  end

  defp policy_error(_error), do: nil
end
