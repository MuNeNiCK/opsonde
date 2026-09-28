defmodule Opsonde.Targets.GenericHTTPTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.TargetPolicy.PolicyRequest

  @password "correct horse battery staple"

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      Agent.update(
        agent,
        &Map.update!(&1, :requests, fn requests ->
          [{conn.method, conn.request_path} | requests]
        end)
      )

      case conn.request_path do
        "/metrics" ->
          state = Agent.get(agent, & &1)

          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(state.status, state.body)

        "/redirect" ->
          conn
          |> put_resp_header("location", "/elsewhere")
          |> send_resp(302, "redirect")

        _other ->
          send_resp(conn, 404, "missing")
      end
    end
  end

  setup do
    agent =
      start_supervised!({Agent, fn -> %{status: 503, body: "guest_alive 0", requests: []} end})

    server =
      start_supervised!({Bandit, plug: {Stub, agent}, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}/metrics"
    admin = Accounts.bootstrap!("generic-http-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("generic-http-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "guest-metrics-http",
        :target,
        "generic-http",
        %{"endpoint" => endpoint},
        %{},
        actor: admin
      )

    checked =
      Providers.check_provider!(provider.id, provider.revision, %{"endpoint" => endpoint},
        actor: admin
      )

    assert checked.check_status == :passed
    provider = Providers.enable_provider!(checked, checked.revision, actor: admin)
    target = Targets.create_target!("guest", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "guest metrics",
        "generic",
        "http_get",
        endpoint,
        provider.revision,
        100,
        ["observe.http"],
        actor: admin
      )

    %{
      admin: admin,
      operator: operator,
      target: target,
      provider: provider,
      method: method,
      endpoint: endpoint,
      agent: agent
    }
  end

  test "public Target path observes an exact HTTP symptom and rejects AI URL input", context do
    assert %Target.Capabilities{observations: [tool], effects: []} =
             Providers.target_capabilities!(context.provider.id, context.provider.revision, %{},
               actor: context.operator
             )

    assert tool.operation == "http.get"
    assert tool.capability == "observe.http"

    request = request(context.target, context.method)
    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.Observation{facts: %{"status" => 503, "body" => "guest_alive 0"}} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    Agent.update(context.agent, &%{&1 | status: 200, body: "guest_alive 1"})

    assert %Target.Observation{facts: %{"status" => 200, "body" => "guest_alive 1"}} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    assert {:error, _error} =
             Targets.clear_target_request(
               %{request | parameters: %{"url" => "http://127.0.0.1:1/"}},
               actor: context.operator
             )

    assert {:error, _error} =
             Targets.clear_target_request(
               %{request | parameters: %{"method" => "POST"}},
               actor: context.operator
             )

    assert Agent.get(context.agent, &Enum.reverse(&1.requests)) == [
             {"GET", "/metrics"},
             {"GET", "/metrics"},
             {"GET", "/metrics"}
           ]
  end

  test "registration binds checked Provider endpoint and capability", context do
    assert {:error, _error} =
             Targets.create_access_method(
               context.target.id,
               context.provider.id,
               "off-host",
               "generic",
               "http_get",
               "http://127.0.0.1:1/other",
               context.provider.revision,
               100,
               ["observe.http"],
               actor: context.admin
             )

    assert {:error, _error} =
             Targets.update_access_method(
               context.method,
               context.method.revision,
               %{capabilities: ["observe.http", "effect.http"]},
               actor: context.admin
             )
  end

  test "a changed Access Method invalidates an already cleared HTTP request", context do
    clearance =
      Targets.clear_target_request!(request(context.target, context.method),
        actor: context.operator
      )

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: 80},
      actor: context.admin
    )

    assert {:error, _error} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

    assert Agent.get(context.agent, &Enum.reverse(&1.requests)) == [{"GET", "/metrics"}]
  end

  test "response preview is bounded and redirects are observed without following", context do
    Agent.update(context.agent, &%{&1 | body: String.duplicate("x", 30_000)})

    clearance =
      Targets.clear_target_request!(request(context.target, context.method),
        actor: context.operator
      )

    assert %Target.Observation{facts: facts} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    assert facts["status"] == 503
    assert facts["body_truncated"] == true
    assert byte_size(facts["body"]) == 8_192

    redirect_endpoint = String.replace(context.endpoint, "/metrics", "/redirect")

    assert {:ok, state} =
             Opsonde.Targets.Generic.HTTP.build(%{"endpoint" => redirect_endpoint}, %{})

    assert :ok = Opsonde.Targets.Generic.HTTP.check(state, %{"endpoint" => redirect_endpoint})

    assert Agent.get(context.agent, &Enum.reverse(&1.requests)) == [
             {"GET", "/metrics"},
             {"GET", "/metrics"},
             {"GET", "/redirect"}
           ]
  end

  defp request(target, method) do
    struct!(PolicyRequest,
      kind: :observation,
      authority_mode: :readonly,
      target_id: target.id,
      target_revision: target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: "observe.http",
      operation: "http.get",
      selectors: %{},
      parameters: %{}
    )
  end
end
