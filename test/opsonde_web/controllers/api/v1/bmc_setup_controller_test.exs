defmodule OpsondeWeb.API.V1.BMCSetupControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Opsonde.{Accounts, Providers, Targets}

  @password "correct horse battery staple"
  @input_schema %{
    "type" => "object",
    "properties" => %{
      "selectors" => %{"type" => "object", "additionalProperties" => false},
      "parameters" => %{"type" => "object", "additionalProperties" => false}
    },
    "required" => ["selectors", "parameters"],
    "additionalProperties" => false
  }
  @output_schema %{"type" => "object", "additionalProperties" => false}

  setup do
    admin =
      Accounts.bootstrap!("bmc-api-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("bmc-api-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("bmc-api-viewer@example.com", @password, :viewer, actor: admin)

    target =
      Targets.create_target!("rack-01", "physical_host", "bare_metal", %{}, nil, actor: admin)

    methods =
      for {adapter, method, endpoint} <- [
            {"bmc-redfish", "redfish", "https://bmc.example.test:8443"},
            {"bmc-ipmi", "ipmi", "ipmi://bmc.example.test:623"}
          ] do
        provider =
          Providers.create_provider!(
            adapter,
            :target,
            adapter,
            %{"endpoint" => endpoint},
            %{"username" => "admin", "password" => "test-only"},
            actor: admin
          )

        checked =
          Providers.record_provider_check!(provider, provider.revision, :passed, nil, nil,
            authorize?: false
          )

        enabled = Providers.enable_provider!(checked, checked.revision, actor: admin)

        access =
          Targets.create_access_method!(
            target.id,
            enabled.id,
            method,
            "bare_metal",
            method,
            endpoint,
            enabled.revision,
            100,
            ["observe.power", "observe.bmc_api", "effect.bmc_api"],
            actor: admin
          )

        {method, access}
      end

    %{
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email),
      methods: Map.new(methods)
    }
  end

  test "Redfish and IPMI definitions survive lost responses and honor revision and read policy",
       context do
    for {kind, method} <- context.methods do
      request =
        if kind == "redfish",
          do: %{"method" => "GET", "uri" => "/redfish/v1/Chassis/1/Thermal"},
          else: %{"netfn" => 6, "command" => 1}

      body = %{
        "bmc_operation" => %{
          "name" => "Observe #{kind}",
          "description" => "Read BMC status",
          "request_kind" => "observation",
          "protocol_request" => request,
          "input_schema" => @input_schema,
          "output_schema" => @output_schema
        }
      }

      created_response =
        request(
          :post,
          "/api/v1/access-methods/#{method.id}/bmc-operations",
          body,
          context.admin_token
        )

      assert_operation_response(created_response)
      assert %{"data" => %{"id" => id, "revision" => 1}} = json_response(created_response, 201)

      # Re-read after discarding the create response, as after a lost HTTP response or client restart.
      listed =
        request(
          :get,
          "/api/v1/access-methods/#{method.id}/bmc-operations",
          nil,
          context.operator_token
        )

      assert_operation_response(listed)

      assert %{"data" => [%{"id" => ^id}], "page" => %{"next" => nil}} =
               json_response(listed, 200)

      shown = request(:get, "/api/v1/bmc-operations/#{id}", nil, context.viewer_token)
      assert_operation_response(shown)
      assert get_in(json_response(shown, 200), ["data", "protocol_request"]) == request

      update =
        request(
          :patch,
          "/api/v1/bmc-operations/#{id}",
          %{"bmc_operation" => %{"expected_revision" => 1, "description" => "Updated"}},
          context.admin_token
        )

      assert %{"data" => %{"revision" => 2}} = json_response(update, 200)
      assert_operation_response(update)

      stale =
        request(
          :patch,
          "/api/v1/bmc-operations/#{id}",
          %{"bmc_operation" => %{"expected_revision" => 1, "description" => "Stale"}},
          context.admin_token
        )

      assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

      forbidden =
        request(
          :post,
          "/api/v1/access-methods/#{method.id}/bmc-operations",
          body,
          context.operator_token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      deactivated =
        request(
          :post,
          "/api/v1/bmc-operations/#{id}/deactivate",
          %{"bmc_operation" => %{"expected_revision" => 2}},
          context.admin_token
        )

      assert %{"data" => %{"active" => false, "revision" => 3}} = json_response(deactivated, 200)
      assert_operation_response(deactivated)
    end
  end

  test "BMC secrets are rotatable and never returned as plaintext", context do
    for {_kind, method} <- context.methods do
      value = "private-secret-#{method.id}"

      assert Phoenix.Logger.filter_values(%{"bmc_secret" => %{"value" => value}}) ==
               %{"bmc_secret" => "[FILTERED]"}

      created =
        request(
          :post,
          "/api/v1/access-methods/#{method.id}/bmc-secrets",
          %{"bmc_secret" => %{"name" => "credential", "value" => value}},
          context.admin_token
        )

      assert_operation_response(created)
      assert %{"data" => %{"id" => id, "revision" => 1}} = json_response(created, 201)
      refute created.resp_body =~ value
      refute created.resp_body =~ ~s("value")

      for {path, token} <- [
            {"/api/v1/access-methods/#{method.id}/bmc-secrets", context.operator_token},
            {"/api/v1/bmc-secrets/#{id}", context.operator_token}
          ] do
        response = request(:get, path, nil, token)
        assert_operation_response(response)
        assert json_response(response, 200)["data"]
        refute response.resp_body =~ value
        refute response.resp_body =~ ~s("value")
      end

      rotated =
        request(
          :patch,
          "/api/v1/bmc-secrets/#{id}",
          %{"bmc_secret" => %{"expected_revision" => 1, "value" => "replacement-#{value}"}},
          context.admin_token
        )

      assert %{"data" => %{"revision" => 2}} = json_response(rotated, 200)
      assert_operation_response(rotated)
      refute rotated.resp_body =~ value

      viewer = request(:get, "/api/v1/bmc-secrets/#{id}", nil, context.viewer_token)
      assert %{"error" => %{"code" => "not_found"}} = json_response(viewer, 404)

      deactivated =
        request(
          :post,
          "/api/v1/bmc-secrets/#{id}/deactivate",
          %{"bmc_secret" => %{"expected_revision" => 2}},
          context.admin_token
        )

      assert %{"data" => %{"active" => false, "revision" => 3}} = json_response(deactivated, 200)
      assert_operation_response(deactivated)
    end
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

  defp request(method, path, body, token) do
    conn = build_json_conn(body)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, body)
      :patch -> patch(conn, path, body)
    end
  end
end
