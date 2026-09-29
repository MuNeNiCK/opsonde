defmodule Opsonde.Targets.BMCRedfishConditionalsTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.Redfish
  alias Opsonde.Targets.BMC.OperationKey
  alias Opsonde.Targets.TargetPolicy.PolicyRequest

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

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Pages"} = conn, _agent) do
      case conn.query_string do
        "page=2" ->
          json(conn, 200, %{"Members" => [%{"Id" => "second"}]})

        "" ->
          json(conn, 200, %{
            "Members" => [%{"Id" => "first"}],
            "Members@odata.nextLink" => "?page=2"
          })
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Loop"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [%{"Id" => "repeated"}],
        "Members@odata.nextLink" => "/redfish/v1/Oem/Loop"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Endless"} = conn, _agent) do
      page =
        case URI.decode_query(conn.query_string) do
          %{"page" => value} -> String.to_integer(value)
          _ -> 1
        end

      json(conn, 200, %{
        "Members" => [%{"Id" => Integer.to_string(page)}],
        "Members@odata.nextLink" => "?page=#{page + 1}"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Cross"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [],
        "Members@odata.nextLink" => "https://other.example/redfish/v1/Oem/Pages"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Large"} = conn, _agent) do
      json(conn, 200, %{"Value" => String.duplicate("x", 70_000)})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Visible"} = conn, _agent) do
      json(conn, 200, %{
        "Result" => "safe",
        "hidden" => "private-value",
        "Nested" => %{"Public" => "visible", "Private" => "private-value"}
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      json(conn, 200, %{"Result" => "safe", "Password" => "fixture-secret"})
    end

    defp route(%{method: "HEAD", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      conn
      |> put_resp_header("etag", ~s("oem-1"))
      |> send_resp(200, "")
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Wrong"} = conn, _agent) do
      json(conn, 200, %{"Result" => %{"unexpected" => "object"}})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Echo"} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      %{"Password" => secret} = Jason.decode!(body)
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      json(conn, 200, %{"Result" => Base.encode64(secret), "Message" => "changed"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Plain"} = conn, _agent) do
      json(conn, 200, %{"Result" => "done", "hidden" => "private-value"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Async"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/1?token=private-value")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/AsyncSafe"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/2")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Drop"} = _conn, agent) do
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      Process.exit(self(), :kill)
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Malformed"} = conn, _agent),
      do: send_resp(conn, 200, "[")

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Redirect"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/Oem/Pages")
      |> send_resp(302, "")
    end

    defp route(conn, _agent), do: send_resp(conn, 404, "")

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  test "Redfish Method effects validate URI and ETag and preserve uncertain results", context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.effects, fn operation ->
             operation.capability == "request.redfish.effect"
           end)

    assert "request.redfish.effect" in Redfish.access_method_profile().capabilities

    request = method_effect_request(context, "PATCH", @system_path, %{"Name" => "requested"})
    request = %{request | selectors: %{"if_match" => ~s("rev-1")}}

    assert {:ok, %{status: :applied, details: %{"http_status" => 204}}} =
             Redfish.effect(state, request, %{})

    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"requested", 1}

    for uri <- ["https://other.example/redfish/v1/Systems/1", "/redfish/v1/../Oem/Plain"] do
      assert {:error, :failed, _} =
               Redfish.effect(state, method_effect_request(context, "POST", uri, %{}), %{})
    end

    oversized =
      method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{
        "Value" => String.duplicate("x", 70_000)
      })

    assert {:error, :failed, _} = Redfish.effect(state, oversized, %{})

    assert {:ok, %{status: :applied, details: plain}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{}),
               %{}
             )

    assert plain == %{"http_status" => 200, "response_redacted" => true}

    assert {:ok, %{status: :unknown, details: async}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/AsyncSafe", %{}),
               %{}
             )

    assert async["task_location"] == "/redfish/v1/TaskService/TaskMonitors/2"

    assert {:ok, %{status: :unknown, details: lost}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Drop", %{}),
               %{}
             )

    assert lost["reason"] =~ "lost"
    assert Agent.get(context.agent, & &1.echo_calls) == 1
  end

  defp method_effect_request(context, method, uri, body) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: %{"method" => method, "uri" => uri, "body" => body}
    }
  end

  test "Redfish Method reads standard and OEM resources without operation registration",
       context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.observations, fn operation ->
             operation.capability == "request.redfish.observe"
           end)

    assert "request.redfish.observe" in Redfish.access_method_profile().capabilities

    assert %Target.Capabilities{} =
             Providers.target_capabilities!(
               context.method.provider_id,
               context.method.provider_revision,
               %{},
               actor: context.operator
             )

    request = %Target.ObservationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture"
    }

    for {uri, expected} <- [
          {@system_path, "original"},
          {"/redfish/v1/Oem/Example", "safe"}
        ] do
      assert {:ok, observation} =
               Redfish.observe(
                 state,
                 %{request | parameters: %{"method" => "GET", "uri" => uri}},
                 %{}
               )

      assert observation.facts["response"]["Name"] == expected or
               observation.facts["response"]["Result"] == expected

      refute inspect(observation) =~ "fixture-secret"
    end

    assert {:ok, head} =
             Redfish.observe(
               state,
               %{
                 request
                 | parameters: %{"method" => "HEAD", "uri" => "/redfish/v1/Oem/Example"}
               },
               %{}
             )

    assert head.facts == %{"http_status" => 200, "response" => %{}}
    assert [%{"etag" => ~s("oem-1")}] = Enum.map(head.evidence, &Map.take(&1, ["etag"]))

    for parameters <- [
          %{"method" => "POST", "uri" => "/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "https://other.example/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example", "extra" => true}
        ] do
      assert {:error, :failed, _} =
               Redfish.observe(state, %{request | parameters: parameters}, %{})
    end

    assert {:error, :failed, _} =
             Redfish.observe(
               state,
               %{request | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Large"}},
               %{}
             )
  end

  defp redfish_state(endpoint) do
    Redfish.build(
      %{
        "endpoint" => endpoint,
        "system_path" => @system_path,
        "expected_uuid" => @uuid,
        "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
      },
      %{"username" => "tester", "password" => "secret"}
    )
  end

  setup do
    agent =
      start_supervised!(
        {Agent, fn -> %{revision: 1, name: "original", writes: 0, echo_calls: 0} end}
      )

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
      Targets.create_target!("etag-host", "management_plane", "bmc", %{}, nil, actor: admin)

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
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

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
        "redfish",
        endpoint,
        provider.revision,
        100,
        ["observe.power", "observe.bmc_api", "effect.bmc_api"],
        actor: admin
      )

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
        %{
          "type" => "object",
          "properties" => %{"Name" => %{"type" => "string"}},
          "additionalProperties" => false
        },
        nil,
        actor: admin
      )

    write =
      Targets.create_bmc_operation!(
        method.id,
        "Rename System",
        "Conditional write",
        :effect,
        %{"method" => "PATCH", "uri" => @system_path},
        write_schema,
        %{"type" => "object", "additionalProperties" => false},
        nil,
        %{parameter_classes: %{"/Name" => "public"}},
        actor: admin
      )

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
                 %{fresh_request | selectors: %{"if_match" => "\r\n"}},
                 actor: context.operator
               ),
               %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.writes) == 1
  end

  test "registered OEM reads bound pagination and reject malformed or unsupported replies",
       context do
    assert {:ok, pages} = read_oem(context, "Pages")
    assert Enum.map(pages.facts["Members"], & &1["Id"]) == ["first", "second"]
    assert [%{"pages" => 2, "http_status" => 200}] = pages.evidence

    for path <- ~w(Loop Endless Cross Large Malformed Redirect Absent) do
      assert {:error, error} = read_oem(context, path)
      assert byte_size(Exception.message(error)) < 1_024
    end

    assert Agent.get(context.agent, & &1.writes) == 0
  end

  test "closed output exposes approved fields and suppresses secret-bound replies", context do
    empty_input =
      input_schema(
        %{"type" => "object", "additionalProperties" => false},
        %{"type" => "object", "additionalProperties" => false}
      )

    visible_output = %{
      "type" => "object",
      "properties" => %{
        "Result" => %{"type" => "string"},
        "Nested" => %{
          "type" => "object",
          "properties" => %{"Public" => %{"type" => "string"}},
          "additionalProperties" => false
        }
      },
      "additionalProperties" => false
    }

    visible =
      Targets.create_bmc_operation!(
        context.method.id,
        "Visible OEM output",
        "Select public fields",
        :observation,
        %{"method" => "GET", "uri" => "/redfish/v1/Oem/Visible"},
        empty_input,
        visible_output,
        nil,
        actor: context.admin
      )

    visible_clearance =
      Targets.clear_target_request!(request(context, visible, :observation),
        actor: context.operator
      )

    result =
      Targets.dispatch_target_observation!(visible_clearance, %{},
        actor: context.operator,
        authorize?: false
      )

    assert result.facts == %{"Result" => "safe", "Nested" => %{"Public" => "visible"}}
    refute inspect(result) =~ "private-value"

    wrong =
      Targets.create_bmc_operation!(
        context.method.id,
        "Wrong OEM output",
        "Reject wrong type",
        :observation,
        %{"method" => "GET", "uri" => "/redfish/v1/Oem/Wrong"},
        empty_input,
        visible_output,
        nil,
        actor: context.admin
      )

    wrong_clearance =
      Targets.clear_target_request!(request(context, wrong, :observation),
        actor: context.operator
      )

    assert {:error, _} =
             Targets.dispatch_target_observation(wrong_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    secret_value = "bound-test-only-secret"

    secret =
      Targets.create_bmc_secret!(context.method.id, "echo-test", secret_value,
        actor: context.admin
      )

    echo =
      Targets.create_bmc_operation!(
        context.method.id,
        "Echo effect",
        "Bound secret echo proof",
        :effect,
        %{"method" => "POST", "uri" => "/redfish/v1/Oem/Echo"},
        empty_input,
        %{"type" => "object", "additionalProperties" => false},
        nil,
        %{
          secret_bindings: %{"/Password" => %{"id" => secret.id, "revision" => secret.revision}},
          parameter_classes: %{"/Password" => "secret"}
        },
        actor: context.admin
      )

    echo_clearance =
      Targets.clear_target_request!(request(context, echo, :effect), actor: context.operator)

    assert {:ok, %{status: :applied, details: details}} =
             Targets.dispatch_target_effect(echo_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert details == %{"http_status" => 200}
    assert Agent.get(context.agent, & &1.echo_calls) == 1
    refute inspect(details) =~ Base.encode64(secret_value)

    plain =
      Targets.create_bmc_operation!(
        context.method.id,
        "Plain effect",
        "Approved effect output proof",
        :effect,
        %{"method" => "POST", "uri" => "/redfish/v1/Oem/Plain"},
        empty_input,
        %{
          "type" => "object",
          "properties" => %{"Result" => %{"type" => "string"}},
          "additionalProperties" => false
        },
        nil,
        actor: context.admin
      )

    plain_clearance =
      Targets.clear_target_request!(request(context, plain, :effect), actor: context.operator)

    assert {:ok, %{status: :applied, details: plain_details}} =
             Targets.dispatch_target_effect(plain_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert plain_details == %{"http_status" => 200, "response" => %{"Result" => "done"}}
    refute inspect(plain_details) =~ "private-value"

    async =
      Targets.create_bmc_operation!(
        context.method.id,
        "Async effect",
        "Task reference proof",
        :effect,
        %{"method" => "POST", "uri" => "/redfish/v1/Oem/Async"},
        empty_input,
        %{"type" => "object", "additionalProperties" => false},
        nil,
        actor: context.admin
      )

    async_clearance =
      Targets.clear_target_request!(request(context, async, :effect), actor: context.operator)

    assert {:ok, %{status: :unknown, details: async_details}} =
             Targets.dispatch_target_effect(async_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert async_details == %{"http_status" => 202}
    refute inspect(async_details) =~ "private-value"

    async_safe =
      Targets.create_bmc_operation!(
        context.method.id,
        "Async safe effect",
        "Safe task reference proof",
        :effect,
        %{"method" => "POST", "uri" => "/redfish/v1/Oem/AsyncSafe"},
        empty_input,
        %{"type" => "object", "additionalProperties" => false},
        nil,
        actor: context.admin
      )

    safe_clearance =
      Targets.clear_target_request!(request(context, async_safe, :effect),
        actor: context.operator
      )

    assert {:ok, %{status: :unknown, details: safe_details}} =
             Targets.dispatch_target_effect(safe_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert safe_details["task_location"] == "/redfish/v1/TaskService/TaskMonitors/2"
  end

  defp read_oem(context, path) do
    definition =
      Targets.create_bmc_operation!(
        context.method.id,
        "Read OEM #{path}",
        "Read registered OEM resource",
        :observation,
        %{"method" => "GET", "uri" => "/redfish/v1/Oem/#{path}"},
        input_schema(
          %{"type" => "object", "additionalProperties" => false},
          %{"type" => "object", "additionalProperties" => false}
        ),
        %{
          "type" => "object",
          "properties" => %{
            "Members" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{"Id" => %{"type" => "string"}},
                "additionalProperties" => false
              }
            }
          },
          "additionalProperties" => false
        },
        nil,
        actor: context.admin
      )

    clearance =
      context
      |> request(definition, :observation)
      |> Targets.clear_target_request!(actor: context.operator)

    Targets.dispatch_target_observation(clearance, %{},
      actor: context.operator,
      authorize?: false
    )
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
