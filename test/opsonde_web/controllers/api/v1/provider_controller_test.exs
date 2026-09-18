defmodule OpsondeWeb.API.V1.ProviderControllerTest do
  use OpsondeWeb.ConnCase, async: false

  alias Opsonde.Accounts

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("provider-api-admin@example.com", @password, @password,
        authorize?: true
      )

    operator =
      Accounts.create_user!("provider-api-operator@example.com", @password, :operator,
        actor: admin
      )

    viewer =
      Accounts.create_user!("provider-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  test "administrator configures every Provider kind without exposing credentials", context do
    providers =
      [
        {"ai", "fixture-ai", %{"model" => "test-model"}, %{"api_key" => "ai-secret"}},
        {"signal", "fixture-signal", %{"source" => "zabbix"}, %{"secret" => "signal-secret"}},
        {"target", "fixture-target", %{"endpoint" => "reachable"}, %{"token" => "target-secret"}},
        {"inventory", "fixture-inventory", %{"source" => "netbox"},
         %{"token" => "inventory-secret"}},
        {"notification", "fixture-notification", %{"destination" => "webhook"},
         %{"token" => "notification-secret"}}
      ]
      |> Enum.map(fn {kind, adapter, configuration, credentials} ->
        response =
          post_json(
            "/api/v1/providers",
            %{
              "provider" => %{
                "name" => "#{kind}-primary",
                "kind" => kind,
                "adapter_type" => adapter,
                "configuration" => configuration,
                "credentials" => credentials
              }
            },
            context.admin_token
          )

        assert %{"data" => %{"id" => id, "kind" => ^kind, "revision" => 1}} =
                 json_response(response, 201)

        assert_secret_free(response, Map.values(credentials))

        checked =
          post_json(
            "/api/v1/providers/#{id}/check",
            %{"provider" => %{"expected_revision" => 1}},
            context.admin_token
          )

        assert %{"data" => %{"check" => %{"status" => "passed", "checked_revision" => 1}}} =
                 json_response(checked, 200)

        enabled =
          post_json(
            "/api/v1/providers/#{id}/enable",
            %{"provider" => %{"expected_revision" => 1}},
            context.admin_token
          )

        assert %{"data" => %{"enabled" => true}} = json_response(enabled, 200)
        assert_secret_free(enabled, Map.values(credentials))
        id
      end)

    first_page = get_json("/api/v1/providers?limit=2", context.viewer_token)

    assert %{"data" => first, "page" => %{"next" => cursor}} =
             json_response(first_page, 200)

    assert length(first) == 2
    assert is_binary(cursor)

    assert_secret_free(first_page, [
      "ai-secret",
      "signal-secret",
      "target-secret",
      "inventory-secret",
      "notification-secret"
    ])

    second_page =
      get_json(
        "/api/v1/providers?limit=3&after=#{URI.encode_www_form(cursor)}",
        context.operator_token
      )

    assert %{"data" => remaining, "page" => %{"next" => nil}} =
             json_response(second_page, 200)

    assert length(remaining) == 3
    assert Enum.sort(Enum.map(first ++ remaining, & &1["id"])) == Enum.sort(providers)
  end

  test "Provider lifecycle preserves failed checks and rejects stale revisions", context do
    secret = "credential-never-returned"
    provider = create_target!(context.admin_token, "echo", secret)

    failed =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{
             "data" => %{
               "enabled" => false,
               "check" => %{
                 "status" => "failed",
                 "category" => "authentication",
                 "message" => "credential [REDACTED] was rejected"
               }
             }
           } = json_response(failed, 200)

    assert_secret_free(failed, [secret])

    updated =
      patch_json(
        "/api/v1/providers/#{provider["id"]}",
        %{
          "provider" => %{
            "expected_revision" => 1,
            "configuration" => %{"endpoint" => "reachable"},
            "credentials" => %{"token" => "replacement-secret"}
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"revision" => 2, "enabled" => false, "check" => %{"status" => nil}}} =
             json_response(updated, 200)

    assert_secret_free(updated, [secret, "replacement-secret"])

    stale =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    current =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 2}},
        context.admin_token
      )

    assert %{"data" => %{"check" => %{"status" => "passed"}}} = json_response(current, 200)

    disabled =
      post_json(
        "/api/v1/providers/#{provider["id"]}/disable",
        %{"provider" => %{"expected_revision" => 2}},
        context.admin_token
      )

    assert %{"data" => %{"enabled" => false}} = json_response(disabled, 200)
  end

  test "AI providers receive independent Resolver and Reviewer roles", context do
    ai =
      create_provider!(
        context.admin_token,
        "ai-role-provider",
        "ai",
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => "role-secret"}
      )

    resolver = create_assignment!(context.admin_token, ai["id"], "resolver", 20)
    reviewer = create_assignment!(context.admin_token, ai["id"], "reviewer", 10)

    assert resolver["provider_id"] == reviewer["provider_id"]
    assert resolver["role"] == "resolver"
    assert reviewer["role"] == "reviewer"

    duplicate =
      post_json(
        "/api/v1/ai-usage-role-assignments",
        %{"assignment" => %{"provider_id" => ai["id"], "role" => "resolver", "priority" => 30}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(duplicate, 409)

    updated =
      patch_json(
        "/api/v1/ai-usage-role-assignments/#{resolver["id"]}",
        %{"assignment" => %{"expected_revision" => 1, "priority" => 5, "enabled" => false}},
        context.admin_token
      )

    assert %{"data" => %{"priority" => 5, "enabled" => false, "revision" => 2}} =
             json_response(updated, 200)

    stale =
      patch_json(
        "/api/v1/ai-usage-role-assignments/#{resolver["id"]}",
        %{"assignment" => %{"expected_revision" => 1, "enabled" => true}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    target = create_target!(context.admin_token, "reachable", "target-role-secret")

    wrong_kind =
      post_json(
        "/api/v1/ai-usage-role-assignments",
        %{
          "assignment" => %{"provider_id" => target["id"], "role" => "reviewer", "priority" => 10}
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(wrong_kind, 422)

    listed = get_json("/api/v1/ai-usage-role-assignments?limit=1", context.viewer_token)
    assert %{"data" => [_one], "page" => %{"next" => cursor}} = json_response(listed, 200)
    assert is_binary(cursor)
    assert_secret_free(listed, ["role-secret", "target-role-secret"])
  end

  test "operator and viewer can read setup but cannot mutate it", context do
    provider = create_target!(context.admin_token, "reachable", "policy-secret")

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"data" => %{"id" => id}} =
               get_json("/api/v1/providers/#{provider["id"]}", token) |> json_response(200)

      assert id == provider["id"]

      forbidden =
        post_json(
          "/api/v1/providers/#{provider["id"]}/check",
          %{"provider" => %{"expected_revision" => 1}},
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)
      assert_secret_free(forbidden, ["policy-secret"])
    end

    bad_body = post_json("/api/v1/providers", %{}, context.admin_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(bad_body, 400)

    invalid_cursor = get_json("/api/v1/providers?after=not-a-keyset", context.admin_token)

    assert %{"error" => %{"code" => "invalid_pagination"}} =
             json_response(invalid_cursor, 422)
  end

  defp create_target!(token, endpoint, secret) do
    create_provider!(
      token,
      "target-#{System.unique_integer([:positive])}",
      "target",
      "fixture-target",
      %{"endpoint" => endpoint},
      %{"token" => secret}
    )
  end

  defp create_provider!(token, name, kind, adapter_type, configuration, credentials) do
    post_json(
      "/api/v1/providers",
      %{
        "provider" => %{
          "name" => name,
          "kind" => kind,
          "adapter_type" => adapter_type,
          "configuration" => configuration,
          "credentials" => credentials
        }
      },
      token
    )
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp create_assignment!(token, provider_id, role, priority) do
    post_json(
      "/api/v1/ai-usage-role-assignments",
      %{"assignment" => %{"provider_id" => provider_id, "role" => role, "priority" => priority}},
      token
    )
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp token!(email) do
    post_json("/api/v1/sessions", %{"session" => %{"email" => email, "password" => @password}})
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp assert_secret_free(conn, secrets) do
    refute conn.resp_body =~ "credentials"
    refute conn.resp_body =~ "encrypted_credentials"
    Enum.each(secrets, &refute(conn.resp_body =~ &1))
  end

  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn

  defp maybe_authorize(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)
end
