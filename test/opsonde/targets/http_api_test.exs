defmodule Opsonde.Targets.HTTPAPITest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.HTTP
  alias Opsonde.Targets.TargetRequest.{RequestError, Request}

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      if get_req_header(conn, "authorization") == ["Bearer fixture-token"] and
           Agent.get(agent, &Map.get(&1, :authorized, true)) do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(conn, agent) do
      case {conn.method, conn.request_path} do
        {"GET", "/api/status"} ->
          status = Agent.get(agent, &Map.get(&1, :status, "ready"))
          conn |> put_resp_header("etag", ~s("rev-1")) |> send_resp(200, status)

        {"HEAD", "/api/status"} ->
          send_resp(conn, 200, "")

        {"POST", "/api/action"} ->
          {:ok, body, conn} = read_body(conn)
          etag = get_req_header(conn, "if-match")
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [{body, etag} | writes] end))
          conn |> put_resp_header("location", "/api/jobs/1") |> send_resp(202, "pending")

        {"POST", "/api/drop"} ->
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> ["drop" | writes] end))
          Process.exit(self(), :kill)

        {"GET", "/api/large"} ->
          send_resp(conn, 200, String.duplicate("x", 30_000))

        _ ->
          send_resp(conn, 404, "missing")
      end
    end
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{writes: []} end})

    server =
      start_supervised!({Bandit, plug: {Stub, agent}, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "http-api-method-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!(
        "http-api-method-operator@example.invalid",
        "test-only-password",
        :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "http-api-method",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => "fixture-token"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(
        "unknown-router",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "HTTP API",
        "http",
        endpoint,
        provider.revision,
        100,
        ["request.http.observe", "request.http.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    {:ok, state} = HTTP.build(%{}, %{"bearer_token" => "fixture-token"})
    {:ok, state} = HTTP.bind_connection(state, %Target.Connection{endpoint: endpoint})

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      endpoint: endpoint,
      state: state,
      agent: agent
    }
  end

  test "a registered Method check records connection facts separately from operator grants",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    assert checked.check_status == :passed
    assert checked.checked_target_revision == context.target.revision
    assert checked.checked_connection_revision == checked.connection_revision
    assert checked.capabilities == ["request.http.observe", "request.http.effect"]
    assert checked.observed_capabilities == ["request.http.observe", "request.http.effect"]
    reread = Targets.get_access_method!(checked.id, actor: context.admin)
    assert reread.checked_at == checked.checked_at
    assert reread.check_status == :passed
    assert reread.operation_catalog == checked.operation_catalog

    assert %Target.Operation{operation: "request.observe"} =
             hd(reread.operation_catalog.observations)
  end

  test "Method grants and display edits preserve a check but an endpoint edit invalidates it",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    edited =
      Targets.update_access_method!(
        checked,
        checked.revision,
        %{name: "renamed", priority: 20, capabilities: []},
        actor: context.admin
      )

    assert edited.check_status == :passed
    assert edited.checked_at == checked.checked_at
    assert edited.observed_capabilities == ["request.http.observe", "request.http.effect"]
    assert edited.capabilities == []

    changed =
      Targets.update_access_method!(edited, edited.revision, %{endpoint: context.endpoint <> "/"},
        actor: context.admin
      )

    assert is_nil(changed.check_status)
    assert changed.observed_capabilities == []
    assert is_nil(changed.operation_catalog)
  end

  test "a failed Method recheck clears earlier connection facts without disabling shared credentials",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    Agent.update(context.agent, &Map.put(&1, :authorized, false))
    failed = Targets.check_access_method!(checked.id, checked.revision, %{}, actor: context.admin)
    assert failed.check_status == :failed
    assert failed.observed_capabilities == []
    assert is_nil(failed.operation_catalog)
    assert Providers.get_provider!(context.provider.id, actor: context.admin).enabled

    request = %Request{
      kind: :effect,
      authority_mode: :auto,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: failed.id,
      access_method_revision: failed.revision,
      capability: "request.http.effect",
      operation: "request.effect",
      parameters: %{"method" => "POST", "path" => "/api/action", "body" => "{}"}
    }

    assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    assert Agent.get(context.agent, & &1.writes) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.check_access_method(context.method.id, failed.revision, %{},
               actor: context.operator
             )
  end

  test "two registered Methods share credentials but reach their own HTTP endpoints", context do
    second_agent =
      start_supervised!(%{
        id: :second_http_state,
        start: {Agent, :start_link, [fn -> %{writes: [], status: "second-device"} end]}
      })

    second_server =
      start_supervised!(%{
        id: :second_http_server,
        start:
          {Bandit, :start_link,
           [[plug: {Stub, second_agent}, scheme: :http, port: 0, startup_log: false]]}
      })

    {:ok, {_address, port}} = ThousandIsland.listener_info(second_server)
    second_endpoint = "http://127.0.0.1:#{port}"

    provider =
      Providers.create_provider!(
        "shared-http-credentials",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => "fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    refute Map.has_key?(provider.configuration, "endpoint")

    for {name, endpoint, body} <- [
          {"first", context.endpoint, "ready"},
          {"second", second_endpoint, "second-device"},
          {"root-alias", context.endpoint <> "/", "ready"}
        ] do
      method =
        Targets.create_access_method!(
          context.target.id,
          provider.id,
          name,
          "http",
          endpoint,
          provider.revision,
          100,
          ["request.http.observe"],
          actor: context.admin
        )
        |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

      request = %Request{
        kind: :observation,
        authority_mode: :readonly,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: method.id,
        access_method_revision: method.revision,
        capability: "request.http.observe",
        operation: "request.observe",
        selectors: %{},
        parameters: %{"method" => "GET", "path" => "/api/status"}
      }

      observation =
        request
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert observation.facts["body"] == body
      assert observation.facts["url"] == String.trim_trailing(endpoint, "/") <> "/api/status"
    end
  end

  test "an unlisted device uses the same HTTP Method for reads and effects", context do
    assert %Target.Capabilities{observations: observations, effects: effects} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: context.endpoint}
               },
               %{},
               actor: context.admin
             )

    assert Enum.any?(observations, &(&1.capability == "request.http.observe"))
    assert Enum.any?(effects, &(&1.capability == "request.http.effect"))

    assert {:ok, observation} =
             HTTP.observe(context.state, read_request(context, "GET", "/api/status"), %{})

    assert observation.facts["status"] == 200
    assert observation.facts["body"] == "ready"

    assert {:ok, head} =
             HTTP.observe(context.state, read_request(context, "HEAD", "/api/status"), %{})

    assert head.facts["status"] == 200

    request = write_request(context, "POST", "/api/action", "{\"apply\":true}")

    request = %{
      request
      | parameters: Map.put(request.parameters, "headers", %{"if-match" => ~s("rev-1")})
    }

    assert {:ok, %{status: :unknown, details: details}} = HTTP.effect(context.state, request, %{})
    assert details["status"] == 202
    assert details["response_redacted"] == true
    assert Agent.get(context.agent, & &1.writes) == [{"{\"apply\":true}", [~s("rev-1")]}]

    verify = %Target.VerificationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      parameters: %{"method" => "GET", "path" => "/api/status"},
      expected: %{"status" => 200}
    }

    assert {:ok, %{status: :verified}} = HTTP.verify(context.state, verify, %{})
  end

  test "HTTP request validation confines origin, credentials, body and response", context do
    assert {:error, :failed, _} =
             HTTP.bind_connection(context.state, %Target.Connection{
               endpoint: context.endpoint <> "/api/status"
             })

    for path <- [
          "http://other.example/api/status",
          "//other.example/api/status",
          "/api/../status",
          "/api/%2fsecret"
        ] do
      assert {:error, :failed, _} =
               HTTP.observe(context.state, read_request(context, "GET", path), %{})
    end

    assert {:error, :failed, _} =
             HTTP.observe(context.state, read_request(context, "POST", "/api/status"), %{})

    assert {:error, :failed, _} =
             HTTP.effect(context.state, write_request(context, "GET", "/api/action", ""), %{})

    too_large = write_request(context, "POST", "/api/action", String.duplicate("x", 70_000))
    assert {:error, :failed, _} = HTTP.effect(context.state, too_large, %{})

    smuggled = %{
      write_request(context, "POST", "/api/action", "{}")
      | parameters: %{
          "method" => "POST",
          "path" => "/api/action",
          "body" => "{}",
          "headers" => %{"authorization" => "Bearer attacker"}
        }
    }

    assert {:error, :failed, _} = HTTP.effect(context.state, smuggled, %{})

    assert {:ok, large} =
             HTTP.observe(context.state, read_request(context, "GET", "/api/large"), %{})

    assert large.facts["body_truncated"] == true
    assert byte_size(large.facts["body"]) == 8_192
    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "a write cannot enter the observation path at clearance or direct Provider dispatch",
       context do
    parameters = %{"method" => "POST", "path" => "/api/action", "body" => "{}"}

    proposal = %Request{
      kind: :observation,
      authority_mode: :auto,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.observe",
      operation: "request.observe",
      parameters: parameters
    }

    assert {:error, clearance_error} =
             Targets.clear_target_request(proposal, actor: context.operator)

    assert Enum.any?(clearance_error.errors, &match?(%RequestError{category: :denied}, &1))

    dispatch_request = %{read_request(context, "POST", "/api/action") | parameters: parameters}

    assert {:error, dispatch_error} =
             Providers.target_observe(context.provider.id, dispatch_request, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Enum.any?(dispatch_error.errors, &match?(%Target.Error{category: :failed}, &1))
    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "a lost HTTP effect response stays unknown and is not replayed", context do
    assert {:ok, %{status: :unknown}} =
             HTTP.effect(context.state, write_request(context, "POST", "/api/drop", "{}"), %{})

    assert Agent.get(context.agent, & &1.writes) == ["drop"]
  end

  defp read_request(context, method, path) do
    %Target.ObservationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => method, "path" => path}
    }
  end

  defp write_request(context, method, path, body) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: %{"method" => method, "path" => path, "body" => body}
    }
  end
end
