defmodule Opsonde.Targets.RESTCONFTest do
  use Opsonde.DataCase, async: false
  alias Opsonde.{Accounts, Providers}
  alias Opsonde.Providers.Target

  defmodule Stub do
    import Plug.Conn
    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn)

      Agent.update(
        agent,
        &Map.update!(&1, :requests, fn requests ->
          [
            %{
              method: conn.method,
              path: conn.request_path,
              query: conn.query_string,
              body: body,
              accept: get_req_header(conn, "accept"),
              content_type: get_req_header(conn, "content-type")
            }
            | requests
          ]
        end)
      )

      authenticated? =
        match?(%{ssl_cert: certificate} when is_binary(certificate), get_peer_data(conn)) or
          get_req_header(conn, "authorization") in [
            ["Basic " <> Base.encode64("tester:secret")],
            ["Bearer static-test-token"]
          ]

      if authenticated?,
        do: route(conn, agent, body),
        else: send_resp(conn, 401, "")
    end

    defp route(%{request_path: "/.well-known/host-meta"} = conn, agent, _body) do
      Process.sleep(Agent.get(agent, & &1.discovery_delay))

      conn
      |> put_resp_content_type("application/xrd+xml")
      |> send_resp(200, Agent.get(agent, & &1.discovery))
    end

    defp route(%{request_path: "/custom/api"} = conn, _agent, _body),
      do: json(conn, %{"ietf-restconf:restconf" => %{}})

    defp route(
           %{method: method, request_path: "/custom/api/data/example:settings"} = conn,
           agent,
           _body
         )
         when method in ["GET", "HEAD"] do
      settings = Agent.get(agent, & &1.settings)

      conn
      |> put_resp_content_type(settings.content_type)
      |> send_resp(200, settings.body)
    end

    defp route(
           %{method: method, request_path: "/custom/api/data/example:settings"} = conn,
           agent,
           body
         )
         when method in ["POST", "PUT", "PATCH", "DELETE"] do
      content_type = hd(get_req_header(conn, "content-type"))
      Agent.update(agent, &%{&1 | settings: %{content_type: content_type, body: body}})
      Process.sleep(Agent.get(agent, & &1.effect_delay))
      send_resp(conn, 204, "")
    end

    defp route(conn, _agent, _body), do: send_resp(conn, 404, "")

    defp json(conn, value),
      do:
        conn
        |> put_resp_content_type("application/yang-data+json")
        |> send_resp(200, Jason.encode!(value))
  end

  setup do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             discovery_delay: 0,
             effect_delay: 0,
             discovery:
               ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0"><Link rel="restconf" href="/custom/api"/></XRD>),
             settings: %{
               content_type: "application/yang-data+json",
               body: Jason.encode!(%{"example:settings" => %{"name" => "original"}})
             }
           }
         end}
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

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "restconf-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    provider =
      Providers.create_provider!(
        "RESTCONF",
        :target,
        "restconf",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 500
        },
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    %{admin: admin, provider: provider, agent: agent, endpoint: endpoint}
  end

  test "checked generic RESTCONF follows the discovered service root", context do
    read = %Target.ObservationRequest{
      provider_revision: context.provider.revision,
      target_id: Ecto.UUID.generate(),
      target_revision: 1,
      access_method_id: Ecto.UUID.generate(),
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.restconf.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => "GET", "path" => "/data/example:settings"}
    }

    observation =
      Providers.target_observe!(context.provider.id, read, %{},
        actor: context.admin,
        authorize?: false
      )

    assert observation.facts["http_status"] == 200

    assert Jason.decode!(observation.facts["body"]) == %{
             "example:settings" => %{"name" => "original"}
           }

    assert Enum.any?(
             Agent.get(context.agent, & &1.requests),
             &(&1.path == "/custom/api/data/example:settings")
           )
  end

  test "Bearer credentials reach the checked RESTCONF endpoint", context do
    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{credentials: %{"bearer_token" => "static-test-token"}},
        actor: context.admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    provider =
      Providers.update_provider!(
        provider,
        provider.revision,
        %{credentials: %{"bearer_token" => "wrong-token"}},
        actor: context.admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:error, _} = checked

    assert Enum.any?(
             elem(checked, 1).errors,
             &match?(%Target.Error{category: :authentication}, &1)
           )
  end

  test "an XML effect is sent once and verified with an independent exact read", context do
    xml = ~s(<settings xmlns="urn:example"><name>changed</name></settings>)

    parameters = %{
      "method" => "PATCH",
      "path" => "/data/example:settings",
      "body" => xml,
      "content_type" => "application/yang-data+xml",
      "accept" => "application/yang-data+xml"
    }

    effect =
      request(
        context,
        Target.EffectRequest,
        "request.restconf.effect",
        "request.execute",
        parameters
      )

    assert %Target.EffectResult{status: :applied} =
             Providers.target_effect!(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    read =
      request(
        context,
        Target.VerificationRequest,
        "request.restconf.observe",
        "request.observe",
        %{
          "method" => "GET",
          "path" => "/data/example:settings",
          "query" => %{"content" => "config"},
          "accept" => "application/yang-data+xml"
        }
      )

    read = %{read | expected: %{"http_status" => 200, "body" => xml}}

    assert %Target.Verification{status: :verified, facts: %{"body" => ^xml}} =
             Providers.target_verify!(context.provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )

    requests = Agent.get(context.agent, & &1.requests)

    assert [%{body: ^xml, content_type: ["application/yang-data+xml"]}] =
             Enum.filter(requests, &(&1.method == "PATCH"))

    assert Enum.any?(
             requests,
             &(&1.method == "GET" and &1.query == "content=config" and
                 &1.accept == ["application/yang-data+xml"])
           )
  end

  test "client certificate credentials perform a verified mutual TLS handshake", context do
    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, context.agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         thousand_island_options: [
           transport_options: [
             cacertfile: Path.expand("test/support/certs/restconf_client_ca.pem"),
             verify: :verify_peer,
             fail_if_no_peer_cert: true
           ]
         ],
         startup_log: false},
        id: :mutual_tls
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    provider =
      Providers.create_provider!(
        "RESTCONF mutual TLS",
        :target,
        "restconf",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 1000
        },
        %{
          "client_certificate" => File.read!("test/support/certs/restconf_client.pem"),
          "client_private_key" => File.read!("test/support/certs/restconf_client_key.pem")
        },
        actor: context.admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, endpoint, context.admin)

    assert {:ok, _catalog} = checked

    baseline =
      Opsonde.TargetConnectionFixture.check_connection(context.provider, endpoint, context.admin)

    assert {:error, _} = baseline
  end

  test "classification rejects malformed or escaping paths and disguised effects without I/O",
       context do
    before = Agent.get(context.agent, &length(&1.requests))

    for parameters <- [
          %{"method" => "GET", "path" => "/data/%zz"},
          %{"method" => "GET", "path" => "/data/%2e%2e/other"},
          %{"method" => "GET", "path" => "/data/%252e%252e/other"},
          %{"method" => "GET", "path" => "https://other.invalid/data"},
          %{"method" => "GET", "path" => "//other.invalid/data"},
          %{"method" => "GET", "path" => "/data?a=1"},
          %{"method" => "POST", "path" => "/data/example:settings"},
          %{"method" => "GET", "path" => "/data/example:settings", "body" => "hidden"},
          %{
            "method" => "GET",
            "path" => "/data/example:settings",
            "headers" => %{"authorization" => "hidden"}
          }
        ] do
      input = %Target.MethodRequest{
        provider_revision: context.provider.revision,
        connection: %Target.Connection{endpoint: context.endpoint},
        capability: "request.restconf.observe",
        operation: "request.observe",
        selectors: %{},
        parameters: parameters
      }

      assert {:error, _} =
               Providers.target_classify(context.provider.id, input, %{},
                 actor: context.admin,
                 authorize?: false
               )
    end

    assert Agent.get(context.agent, &length(&1.requests)) == before
  end

  test "a lost effect response remains unknown, is not replayed, and can be observed afresh",
       context do
    Agent.update(context.agent, &%{&1 | effect_delay: 1_000})
    body = ~s({"example:settings":{"name":"changed-before-reply"}})

    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => body
      })

    assert %Target.EffectResult{status: :unknown} =
             Providers.target_effect!(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    assert length(
             Agent.get(context.agent, &Enum.filter(&1.requests, fn r -> r.method == "PATCH" end))
           ) == 1

    read =
      request(
        context,
        Target.VerificationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "GET", "path" => "/data/example:settings"}
      )

    assert %Target.Verification{status: :verified} =
             Providers.target_verify!(
               context.provider.id,
               %{read | expected: %{"body" => body}},
               %{},
               actor: context.admin,
               authorize?: false
             )
  end

  test "cancellation before dispatch sends nothing and cancellation after acceptance is unknown",
       context do
    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => "changed"
      })

    before = Agent.get(context.agent, &length(&1.requests))

    assert {:error, _} =
             Providers.target_effect(context.provider.id, effect, %{cancelled?: fn -> true end},
               actor: context.admin,
               authorize?: false
             )

    assert Agent.get(context.agent, &length(&1.requests)) == before
    Agent.update(context.agent, &%{&1 | effect_delay: 1_000})

    cancelled? = fn ->
      Agent.get(context.agent, &Enum.any?(&1.requests, fn r -> r.method == "PATCH" end))
    end

    assert %Target.EffectResult{status: :unknown} =
             Providers.target_effect!(context.provider.id, effect, %{cancelled?: cancelled?},
               actor: context.admin,
               authorize?: false
             )

    assert length(
             Agent.get(context.agent, &Enum.filter(&1.requests, fn r -> r.method == "PATCH" end))
           ) == 1
  end

  test "root discovery rejection or expiry stops before sending an effect", context do
    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => "changed"
      })

    for links <- [
          ~s(<Link rel="restconf" href="https://other.invalid/api"/>),
          ~s(<Link rel="restconf" href="/custom/api"/><Link rel="restconf" href="/second/api"/>)
        ] do
      Agent.update(
        context.agent,
        &%{
          &1
          | discovery: ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">#{links}</XRD>)
        }
      )

      assert {:error, _} =
               Providers.target_effect(context.provider.id, effect, %{},
                 actor: context.admin,
                 authorize?: false
               )
    end

    Agent.update(context.agent, &%{&1 | discovery_delay: 1_000})

    assert {:error, _} =
             Providers.target_effect(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    refute Agent.get(context.agent, &Enum.any?(&1.requests, fn r -> r.method == "PATCH" end))
  end

  test "a configured root skips discovery and a HEAD read has an empty raw body", context do
    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{configuration: Map.put(context.provider.configuration, "api_root", "/custom/api")},
        actor: context.admin
      )

    Agent.update(context.agent, &%{&1 | discovery: "not XML", requests: []})

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    context = %{context | provider: provider}

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "HEAD", "path" => "/data/example:settings"}
      )

    assert %Target.Observation{facts: %{"http_status" => 200, "body" => ""}} =
             Providers.target_observe!(provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )

    refute Agent.get(
             context.agent,
             &Enum.any?(&1.requests, fn r -> r.path == "/.well-known/host-meta" end)
           )
  end

  test "an oversized response fails without returning a truncated successful observation",
       context do
    Agent.update(
      context.agent,
      &%{
        &1
        | settings: %{
            content_type: "application/yang-data+xml",
            body: String.duplicate("x", 65_537)
          }
      }
    )

    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{configuration: Map.put(context.provider.configuration, "max_body_bytes", 1_024)},
        actor: context.admin
      )

    checked =
      Opsonde.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    context = %{context | provider: provider}

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "GET", "path" => "/data/example:settings"}
      )

    assert {:error, _} =
             Providers.target_observe(provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )
  end

  defp request(context, module, capability, operation, parameters) do
    attributes = %{
      provider_revision: context.provider.revision,
      target_id: Ecto.UUID.generate(),
      target_revision: 1,
      access_method_id: Ecto.UUID.generate(),
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: capability,
      operation: operation,
      authorization_digest: "fixture",
      parameters: parameters
    }

    attributes =
      if module in [Target.EffectRequest, Target.VerificationRequest],
        do: Map.put(attributes, :operation_id, Ecto.UUID.generate()),
        else: attributes

    attributes =
      if module == Target.EffectRequest,
        do: Map.put(attributes, :idempotency_key, Ecto.UUID.generate()),
        else: attributes

    struct!(module, attributes)
  end
end
