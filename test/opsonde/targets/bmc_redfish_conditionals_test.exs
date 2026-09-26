defmodule Opsonde.Targets.BMCRedfishConditionalsTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Targets.BMC.OperationKey
  alias Opsonde.Targets.PolicyRequest

  @system_path "/redfish/v1/Systems/1"
  @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

  defmodule Stub do
    import Plug.Conn

    @system_path "/redfish/v1/Systems/1"
    @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

    def init(agent), do: agent

    def call(conn, agent) do
      if get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("tester:secret")] do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Systems"} = conn, _agent) do
      json(conn, 200, %{"Members" => [%{"@odata.id" => @system_path}]})
    end

    defp route(%{method: "GET", request_path: @system_path} = conn, agent) do
      state = Agent.get(agent, & &1)

      conn
      |> put_resp_header("etag", ~s("rev-#{state.revision}"))
      |> json(200, %{
        "@odata.id" => @system_path,
        "UUID" => @uuid,
        "PowerState" => "On",
        "Name" => state.name
      })
    end

    defp route(%{method: "PATCH", request_path: @system_path} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      expected = Agent.get(agent, &~s("rev-#{&1.revision}"))

      if get_req_header(conn, "if-match") == [expected] do
        %{"Name" => name} = Jason.decode!(body)
        Agent.update(agent, &%{&1 | name: name, revision: &1.revision + 1, writes: &1.writes + 1})
        send_resp(conn, 204, "")
      else
        send_resp(conn, 412, Jason.encode!(%{"error" => "precondition failed"}))
      end
    end

    defp route(conn, _agent), do: send_resp(conn, 404, "")

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{revision: 1, name: "original", writes: 0} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "bmc-etag-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!("bmc-etag-operator@example.invalid", "test-only-password", :operator,
        actor: admin
      )

    target =
      Targets.create_target!("etag-host", "physical_host", "bare_metal", %{}, nil, actor: admin)

    provider =
      Providers.create_provider!(
        "etag-bmc",
        :target,
        "bmc-redfish",
        %{
          "endpoint" => endpoint,
          "system_path" => @system_path,
          "expected_uuid" => @uuid,
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "tester", "password" => "secret"}, actor: admin)

    checked =
      Providers.check_provider!(provider.id, provider.revision, %{"endpoint" => endpoint},
        actor: admin
      )

    assert checked.check_status == :passed
    provider = Providers.enable_provider!(checked, checked.revision, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Redfish",
        "bare_metal",
        "redfish",
        endpoint,
        provider.revision,
        100,
        ["observe.power", "observe.bmc_api", "effect.bmc_api"], actor: admin)

    read_schema =
      input_schema(
        %{"type" => "object", "additionalProperties" => false},
        %{"type" => "object", "additionalProperties" => false}
      )

    write_schema =
      input_schema(
        %{
          "type" => "object",
          "properties" => %{
            "if_match" => %{"type" => "string", "maxLength" => 256}
          },
          "required" => ["if_match"],
          "additionalProperties" => false
        },
        %{
          "type" => "object",
          "properties" => %{"Name" => %{"type" => "string"}},
          "required" => ["Name"],
          "additionalProperties" => false
        }
      )

    read =
      Targets.create_bmc_operation!(
        method.id,
        "Read System",
        "Read ETag",
        :observation,
        %{"method" => "GET", "uri" => @system_path},
        read_schema,
        %{"type" => "object"},
        nil, actor: admin)

    write =
      Targets.create_bmc_operation!(
        method.id,
        "Rename System",
        "Conditional write",
        :effect,
        %{"method" => "PATCH", "uri" => @system_path},
        write_schema,
        %{"type" => "object"},
        nil,
        %{parameter_classes: %{"/Name" => "public"}}, actor: admin)

    %{
      admin: admin,
      operator: operator,
      target: target,
      method: method,
      read: read,
      write: write,
      agent: agent
    }
  end

  test "registered read ETag protects writes and stale ETag does not mutate", context do
    read_request = request(context, context.read, :observation)
    read_clearance = Targets.clear_target_request!(read_request, actor: context.operator)

    before =
      Targets.dispatch_target_observation!(read_clearance, %{},
        actor: context.operator,
        authorize?: false
      )

    assert before.facts["Name"] == "original"
    assert [%{"etag" => ~s("rev-1"), "uri" => @system_path}] = before.evidence

    stale_request = %{
      request(context, context.write, :effect)
      | selectors: %{"if_match" => ~s("rev-0")},
        parameters: %{"Name" => "wrong"}
    }

    stale_clearance = Targets.clear_target_request!(stale_request, actor: context.operator)

    assert {:error, stale_error} =
             Targets.dispatch_target_effect(stale_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(stale_error) =~ "HTTP 412"

    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"original", 0}

    fresh_request = %{
      stale_request
      | selectors: %{"if_match" => ~s("rev-1")},
        parameters: %{"Name" => "updated"},
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
    }

    fresh_clearance = Targets.clear_target_request!(fresh_request, actor: context.operator)

    assert {:ok, %{status: :applied, details: %{"http_status" => 204}}} =
             Targets.dispatch_target_effect(fresh_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"updated", 1}

    after_read =
      Targets.dispatch_target_observation!(read_clearance, %{},
        actor: context.operator,
        authorize?: false
      )

    assert [%{"etag" => ~s("rev-2")}] = after_read.evidence

    assert {:error, _} =
             Targets.clear_target_request(%{fresh_request | selectors: %{}},
               actor: context.operator
             )

    assert {:error, _} =
             Targets.clear_target_request(
               %{fresh_request | selectors: %{"if_match" => String.duplicate("x", 257)}},
               actor: context.operator
             )

    assert {:error, _} =
             Targets.dispatch_target_effect(
               Targets.clear_target_request!(
                 %{fresh_request | selectors: %{"if_match" => "\r\n"}}, actor: context.operator),
               %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.writes) == 1
  end

  defp input_schema(selectors, parameters) do
    %{
      "type" => "object",
      "properties" => %{"selectors" => selectors, "parameters" => parameters},
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp request(context, definition, kind) do
    %PolicyRequest{
      kind: kind,
      authority_mode: :ask,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: OperationKey.capability(definition.request_kind),
      operation: OperationKey.format(definition),
      operation_id: if(kind == :effect, do: Ecto.UUID.generate(), else: nil),
      idempotency_key: if(kind == :effect, do: Ecto.UUID.generate(), else: nil)
    }
  end
end
