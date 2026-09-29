defmodule Opsonde.Targets.GenericHTTPNativeTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.HTTP

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      if get_req_header(conn, "authorization") == ["Bearer fixture-token"] do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(conn, agent) do
      case {conn.method, conn.request_path} do
        {"GET", "/api/status"} ->
          conn |> put_resp_header("etag", ~s("rev-1")) |> send_resp(200, "ready")

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
        "generic-http-native-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!(
        "generic-http-native-operator@example.invalid",
        "test-only-password",
        :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "generic-http-native",
        :target,
        "generic-http",
        %{"endpoint" => endpoint},
        %{"bearer_token" => "fixture-token"},
        actor: admin
      )
      |> then(
        &Providers.check_provider!(&1.id, &1.revision, %{"endpoint" => endpoint}, actor: admin)
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!("unknown-router", "network_device", "junos", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "HTTP API",
        "generic",
        "http",
        endpoint,
        provider.revision,
        100,
        ["native.http.observe", "native.http.effect"],
        actor: admin
      )

    {:ok, state} = HTTP.build(%{"endpoint" => endpoint}, %{"bearer_token" => "fixture-token"})

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

  test "an unlisted device uses the same HTTP Method for reads and effects", context do
    assert %Target.Capabilities{observations: observations, effects: effects} =
             Providers.target_capabilities!(context.provider.id, context.provider.revision, %{},
               actor: context.operator
             )

    assert Enum.any?(observations, &(&1.capability == "native.http.observe" and &1.native?))
    assert Enum.any?(effects, &(&1.capability == "native.http.effect" and &1.native?))

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
      capability: "native.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      parameters: %{"method" => "GET", "path" => "/api/status"},
      expected: %{"status" => 200}
    }

    assert {:ok, %{status: :verified}} = HTTP.verify(context.state, verify, %{})
  end

  test "HTTP request validation confines origin, credentials, body and response", context do
    assert {:error, :invalid_configuration} =
             HTTP.build(%{"endpoint" => context.endpoint <> "/api/status"}, %{})

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
      capability: "native.http.observe",
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
      capability: "native.http.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: %{"method" => method, "path" => path, "body" => body}
    }
  end
end
