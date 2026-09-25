defmodule OpsondeWeb.API.V1.ProviderControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Opsonde.{Accounts, Cases, Providers}

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

        assert_operation_response(response)
        assert_secret_free(response, Map.values(credentials))

        checked =
          post_json(
            "/api/v1/providers/#{id}/check",
            %{"provider" => %{"expected_revision" => 1}},
            context.admin_token
          )

        assert %{"data" => %{"check" => %{"status" => "passed", "checked_revision" => 1}}} =
                 json_response(checked, 200)

        assert_operation_response(checked)

        enabled =
          post_json(
            "/api/v1/providers/#{id}/enable",
            %{"provider" => %{"expected_revision" => 1}},
            context.admin_token
          )

        assert %{"data" => %{"enabled" => true}} = json_response(enabled, 200)
        assert_operation_response(enabled)
        assert_secret_free(enabled, Map.values(credentials))
        id
      end)

    first_page = get_json("/api/v1/providers?limit=2", context.viewer_token)

    assert %{"data" => first, "page" => %{"next" => cursor}} =
             json_response(first_page, 200)

    assert_operation_response(first_page)

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

  test "AI connection usage defaults to ALL and changes both roles atomically", context do
    ai =
      create_provider!(
        context.admin_token,
        "ai-role-provider",
        "ai",
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => "role-secret"}
      )

    [resolver, reviewer] = assignments_for!(context.admin_token, ai["id"])

    assert resolver["provider_id"] == reviewer["provider_id"]
    assert resolver["role"] == "resolver"
    assert reviewer["role"] == "reviewer"

    assert resolver["enabled"] && reviewer["enabled"]
    assert resolver["priority"] == 100

    body = %{
      "usage" => %{
        "scope" => "reviewer",
        "priority" => 5,
        "expected_resolver_revision" => resolver["revision"],
        "expected_reviewer_revision" => reviewer["revision"]
      }
    }

    assert response(
             put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, context.admin_token),
             204
           ) == ""

    [updated_resolver, updated_reviewer] = assignments_for!(context.admin_token, ai["id"])
    assert updated_resolver["id"] == resolver["id"]
    assert updated_reviewer["id"] == reviewer["id"]
    assert updated_resolver["priority"] == 5
    refute updated_resolver["enabled"]
    assert updated_reviewer["enabled"]
    assert updated_reviewer["revision"] == 2

    stale =
      put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, context.admin_token)

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    partially_stale =
      put_json(
        "/api/v1/providers/#{ai["id"]}/ai-usage",
        %{
          "usage" => %{
            "scope" => "all",
            "priority" => 8,
            "expected_resolver_revision" => updated_resolver["revision"],
            "expected_reviewer_revision" => reviewer["revision"]
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(partially_stale, 409)

    assert [^updated_resolver, ^updated_reviewer] =
             assignments_for!(context.admin_token, ai["id"])

    target = create_target!(context.admin_token, "reachable", "target-role-secret")

    wrong_kind =
      put_json("/api/v1/providers/#{target["id"]}/ai-usage", body, context.admin_token)

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(wrong_kind, 422)

    assert %{"error" => %{"code" => "forbidden"}} =
             put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, context.operator_token)
             |> json_response(403)

    listed = get_json("/api/v1/ai-usage-role-assignments?limit=1", context.viewer_token)
    assert %{"data" => [_one], "page" => %{"next" => cursor}} = json_response(listed, 200)
    assert is_binary(cursor)
    assert_secret_free(listed, ["role-secret", "target-role-secret"])
  end

  test "AI creation accepts an initial usage choice and rejects usage on other kinds", context do
    created =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "name" => "review-only",
            "kind" => "ai",
            "adapter_type" => "fixture-ai",
            "configuration" => %{"model" => "test-model"},
            "credentials" => %{"api_key" => "initial-secret"},
            "usage_scope" => "reviewer",
            "usage_priority" => 7
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"id" => id}} = json_response(created, 201)
    [resolver, reviewer] = assignments_for!(context.admin_token, id)
    refute resolver["enabled"]
    assert reviewer["enabled"]
    assert resolver["priority"] == 7
    assert reviewer["priority"] == 7

    rejected =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "name" => "target-with-ai-usage",
            "kind" => "target",
            "adapter_type" => "fixture-target",
            "configuration" => %{"endpoint" => "reachable"},
            "credentials" => %{"token" => "test-token"},
            "usage_scope" => "all"
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(rejected, 400)
  end

  test "administrator deletes an AI connection and revokes its active use", context do
    name = "retired-ai-#{System.unique_integer([:positive])}"
    secret = "credential-to-erase"

    ai =
      create_provider!(
        context.admin_token,
        name,
        "ai",
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => secret}
      )

    [resolver, reviewer] = assignments_for!(context.admin_token, ai["id"])

    incident =
      Cases.open_case!(
        :manual,
        "web",
        "delete-ai-history-#{System.unique_integer([:positive])}",
        "Historical AI reference",
        :warning,
        :not_applicable,
        %{},
        nil,
        :en,
        authorize?: false
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    turn =
      Cases.create_turn_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          ordinal: 1,
          idempotency_key: "historical-turn",
          status: :started,
          intent: %{},
          started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    invocation =
      Cases.create_ai_invocation_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          turn_id: turn.id,
          provider_id: ai["id"],
          assignment_id: resolver["id"],
          role: :resolver,
          idempotency_key: "historical-ai-invocation",
          request_digest: String.duplicate("a", 64),
          provider_revision: 1,
          assignment_revision: 1,
          selection_source: :assignment,
          reserved_units: 1,
          dispatch_started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    assert %{"data" => %{"check" => %{"status" => "passed"}}} =
             post_json(
               "/api/v1/providers/#{ai["id"]}/check",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(200)

    assert %{"data" => %{"enabled" => true}} =
             post_json(
               "/api/v1/providers/#{ai["id"]}/enable",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(200)

    assert {:ok, eligible} =
             Providers.load_provider_for_invocation(ai["id"], 1, :ai, authorize?: false)

    assert eligible.id == ai["id"]

    assert %{"error" => %{"code" => "forbidden"}} =
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.operator_token
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "conflict"}} =
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 2}},
               context.admin_token
             )
             |> json_response(409)

    deleted =
      delete_json(
        "/api/v1/providers/#{ai["id"]}",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert response(deleted, 204) == ""
    assert_operation_response(deleted)

    assert response(
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             ),
             204
           ) == ""

    assert %{"data" => active} =
             get_json("/api/v1/providers", context.admin_token) |> json_response(200)

    refute Enum.any?(active, &(&1["id"] == ai["id"]))

    assert %{"data" => roles} =
             get_json("/api/v1/ai-usage-role-assignments", context.admin_token)
             |> json_response(200)

    refute Enum.any?(roles, &(&1["provider_id"] == ai["id"]))

    for path <- [
          "/api/v1/providers/#{ai["id"]}/check",
          "/api/v1/providers/#{ai["id"]}/enable"
        ] do
      assert %{"error" => %{"code" => "not_found"}} =
               post_json(path, %{"provider" => %{"expected_revision" => 1}}, context.admin_token)
               |> json_response(404)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/providers/#{ai["id"]}", context.admin_token)
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             put_json(
               "/api/v1/providers/#{ai["id"]}/ai-usage",
               %{
                 "usage" => %{
                   "scope" => "all",
                   "priority" => 10,
                   "expected_resolver_revision" => 2,
                   "expected_reviewer_revision" => 2
                 }
               },
               context.admin_token
             )
             |> json_response(404)

    assert {:ok, stored} = Providers.get_provider(ai["id"], authorize?: false)
    assert stored.retired_at
    assert stored.configuration == %{}
    assert stored.enabled == false
    assert {:ok, stored} = Ash.load(stored, :credentials, authorize?: false)
    assert stored.credentials == %{}

    assert {:error, _error} =
             Providers.load_provider_for_invocation(ai["id"], 1, :ai, authorize?: false)

    assert {:error, _error} = Providers.select_resolver_ai(authorize?: false)

    assert {:ok, retained} =
             Cases.ai_invocation_by_idempotency("historical-ai-invocation", authorize?: false)

    assert retained.id == invocation.id
    assert retained.provider_id == ai["id"]
    assert retained.assignment_id == resolver["id"]
    assert Cases.get_case!(incident.id, authorize?: false).id == incident.id

    for role_id <- [resolver["id"], reviewer["id"]] do
      assert {:ok, assignment} =
               Providers.get_ai_usage_role_assignment(role_id, authorize?: false)

      assert assignment.enabled == false
    end

    replacement =
      create_provider!(
        context.admin_token,
        name,
        "ai",
        "fixture-ai",
        %{"model" => "replacement-model"},
        %{"api_key" => "replacement-secret"}
      )

    refute replacement["id"] == ai["id"]
    assert replacement["name"] == name
  end

  test "non-AI Provider cannot be deleted through AI removal", context do
    target = create_target!(context.admin_token, "reachable", "target-secret")

    assert %{"error" => %{"code" => "validation_failed"}} =
             delete_json(
               "/api/v1/providers/#{target["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(422)

    assert %{"data" => %{"id" => id}} =
             get_json("/api/v1/providers/#{target["id"]}", context.admin_token)
             |> json_response(200)

    assert id == target["id"]
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

  test "enabled Target Provider exposes adapter capabilities to administrators and operators",
       context do
    provider =
      create_target!(context.admin_token, "reachable", "capability-secret")
      |> then(fn provider ->
        post_json(
          "/api/v1/providers/#{provider["id"]}/check",
          %{"provider" => %{"expected_revision" => provider["revision"]}},
          context.admin_token
        )
        |> json_response(200)
        |> Map.fetch!("data")
      end)
      |> then(fn provider ->
        post_json(
          "/api/v1/providers/#{provider["id"]}/enable",
          %{"provider" => %{"expected_revision" => provider["revision"]}},
          context.admin_token
        )
        |> json_response(200)
        |> Map.fetch!("data")
      end)

    for token <- [context.admin_token, context.operator_token] do
      response =
        post_json(
          "/api/v1/providers/#{provider["id"]}/target-capabilities",
          %{"provider" => %{"expected_revision" => provider["revision"]}},
          token
        )

      assert %{"data" => %{"observations" => [], "effects" => []}} =
               json_response(response, 200)

      assert_secret_free(response, ["capability-secret"])
    end

    forbidden =
      post_json(
        "/api/v1/providers/#{provider["id"]}/target-capabilities",
        %{"provider" => %{"expected_revision" => provider["revision"]}},
        context.viewer_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

    bad_body =
      post_json(
        "/api/v1/providers/#{provider["id"]}/target-capabilities",
        %{},
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(bad_body, 400)
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

  defp assignments_for!(token, provider_id) do
    get_json("/api/v1/ai-usage-role-assignments", token)
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.filter(&(&1["provider_id"] == provider_id))
    |> Enum.sort_by(& &1["role"])
  end

  defp token!(email) do
    post_json("/api/v1/sessions", %{
      "session" => %{"email" => to_string(email), "password" => @password}
    })
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
  defp put_json(path, body, token), do: request(:put, path, body, token)
  defp delete_json(path, body, token), do: request(:delete, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp dispatch_request(conn, :delete, path, body), do: delete(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn

  defp maybe_authorize(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)
end
