defmodule OpsondeCLI.TargetAPITest do
  use OpsondeWeb.ConnCase, async: false

  import ExUnit.CaptureIO

  alias Opsonde.{Accounts, Providers, Targets}
  alias OpsondeCLI.{CLI, Config}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("target-cli-admin@example.com", @password, @password, authorize?: true)

    token =
      build_json_conn(%{})
      |> post("/api/v1/sessions", %{
        "session" => %{"email" => to_string(admin.email), "password" => @password}
      })
      |> json_response(201)
      |> get_in(["data", "token"])

    root =
      Path.join(System.tmp_dir!(), "opsonde-target-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")
    :ok = Config.save(%{"server" => "https://opsonde.example", "token" => token}, config_path)
    on_exit(fn -> File.rm_rf(root) end)

    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &OpsondeWeb.Endpoint.call(&1, OpsondeWeb.Endpoint.init([])))

    %{
      admin: admin,
      stub: stub,
      runtime: [config_path: config_path, request_options: [plug: {Req.Test, stub}]]
    }
  end

  test "CLI checks a registered Method through the authenticated remote API contract", context do
    provider =
      Providers.create_provider!(
        "check fixture",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-cli-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("check-host", "host", "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "check-method",
        "ssh",
        "ssh://192.0.2.1:22",
        provider.revision,
        100,
        [],
        actor: context.admin
      )

    output =
      capture_io(Jason.encode!(%{expected_revision: method.revision}), fn ->
        assert CLI.run(["access-method", "check", method.id, "--input", "-"], context.runtime) ==
                 0
      end)

    %{"data" => checked} = Jason.decode!(output)
    assert checked["check"]["current"]
    assert checked["check"]["status"] == "passed"
    assert "observe.command" in checked["check"]["observed_capabilities"]
    assert "effect.command" in checked["check"]["observed_capabilities"]
    assert checked["capabilities"] == []
    refute output =~ "private-cli-token"

    granted =
      cli_data!(context, ["access-method", "update", checked["id"]], %{
        expected_revision: checked["revision"],
        capabilities: ["observe.command"]
      })

    assert granted["check"] == checked["check"]
    assert granted["capabilities"] == ["observe.command"]

    changed =
      cli_data!(context, ["access-method", "update", granted["id"]], %{
        expected_revision: granted["revision"],
        endpoint: "ssh://192.0.2.2:22"
      })

    assert changed["endpoint"] == "ssh://192.0.2.2:22"
    assert changed["capabilities"] == ["observe.command"]
    assert changed["check"]["current"] == false
    assert changed["check"]["observed_capabilities"] == []

    listed = cli_data!(context, ["access-method", "list"])
    assert Enum.find(listed, &(&1["id"] == changed["id"])) == changed
  end

  test "CLI registers every published Method and reads failed checks through the authenticated API",
       context do
    catalog =
      capture_io(fn -> assert CLI.run(["target-type", "list"], context.runtime) == 0 end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert Enum.any?(
             catalog["methods"],
             &(&1["adapter_type"] == "hpe-ilo-ipmi" and &1["protocol"] == "ipmi")
           )

    assert Enum.any?(
             catalog["types"],
             &(&1["id"] == "custom-bmc" and &1["access_method_types"] == ["redfish", "ipmi"])
           )

    # Real adapters contact refused local TCP/UDP ports. This proves the CLI
    # registration/error contract, not successful vendor/OEM connectivity.
    {:ok, listener} = :gen_tcp.listen(0, active: false)
    {:ok, tcp_port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    {:ok, socket} = :gen_udp.open(0, active: false)
    {:ok, udp_port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)

    for descriptor <- catalog["methods"] do
      adapter_type = descriptor["adapter_type"]
      method_name = descriptor["protocol"]

      endpoint =
        case method_name do
          protocol when protocol in ["ssh", "netconf"] -> "ssh://127.0.0.1:#{tcp_port}"
          "ipmi" -> "ipmi://127.0.0.1:#{udp_port}"
          _ -> "https://127.0.0.1:#{tcp_port}"
        end

      {configuration, credentials} = Opsonde.TargetConnectionFixture.input(adapter_type, endpoint)

      configuration =
        case method_name do
          protocol when protocol in ["ssh", "netconf"] ->
            Map.merge(configuration, %{"connect_timeout_ms" => 100, "operation_timeout_ms" => 100})

          "restconf" ->
            Map.merge(configuration, %{"connect_timeout_ms" => 100, "request_timeout_ms" => 100})

          "kubernetes" ->
            configuration

          _ ->
            Map.put(configuration, "timeout_ms", 100)
        end

      type = Enum.find(catalog["types"], &(adapter_type in &1["access_method_types"]))

      target =
        cli_data!(context, ["target", "create"], %{
          name: "CLI #{adapter_type}",
          kind: type["kind"],
          type_id: type["id"],
          facts: %{}
        })

      provider =
        cli_data!(context, ["provider", "create"], %{
          name: "CLI #{adapter_type}",
          kind: "target",
          adapter_type: adapter_type,
          configuration: configuration,
          credentials: credentials
        })

      provider =
        cli_data!(context, ["provider", "enable", provider["id"]], %{
          expected_revision: provider["revision"]
        })

      binding_method = provider["access_method_profile"]["method"]

      method_input =
        Jason.encode!(%{
          "target_id" => target["id"],
          "provider_id" => provider["id"],
          "name" => method_name,
          "method" => binding_method,
          "endpoint" => endpoint,
          "provider_revision" => provider["revision"],
          "priority" => 100,
          "capabilities" => []
        })

      method =
        capture_io(method_input, fn ->
          assert CLI.run(["access-method", "create", "--input", "-"], context.runtime) == 0
        end)
        |> Jason.decode!()
        |> get_in(["data"])

      assert method["target_id"] == target["id"]
      assert method["provider_id"] == provider["id"]
      assert method["endpoint"] == endpoint
      assert method["method"] == binding_method

      output =
        capture_io(Jason.encode!(%{expected_revision: method["revision"]}), fn ->
          assert CLI.run(
                   ["access-method", "check", method["id"], "--input", "-"],
                   context.runtime
                 ) == 13
        end)

      assert %{"outcome" => "failed", "data" => checked} = Jason.decode!(output)
      assert checked["endpoint"] == endpoint
      assert checked["check"]["status"] == "failed"
      assert checked["check"]["current"] == false
      assert checked["check"]["observed_capabilities"] == []
      assert checked["capabilities"] == []

      reread = cli_data!(context, ["access-method", "list"])
      assert Enum.find(reread, &(&1["id"] == checked["id"])) == checked
    end
  end

  test "CLI reports a persisted failed Method check as a failure", context do
    provider =
      Providers.create_provider!(
        "rejected credentials",
        :target,
        "fixture-target",
        %{"endpoint" => "authentication"},
        %{"token" => "private-cli-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("unknown-host", "host", "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "rejected",
        "ssh",
        "ssh://192.0.2.1:22",
        provider.revision,
        100,
        ["observe.command"],
        actor: context.admin
      )

    output =
      capture_io(Jason.encode!(%{expected_revision: method.revision}), fn ->
        assert CLI.run(["access-method", "check", method.id, "--input", "-"], context.runtime) ==
                 13
      end)

    assert %{
             "outcome" => "failed",
             "data" => %{
               "check" => %{
                 "current" => false,
                 "status" => "failed",
                 "observed_capabilities" => []
               }
             }
           } = Jason.decode!(output)

    refute output =~ "private-cli-token"
  end

  test "a lost check acknowledgement is not retried and a new CLI invocation reads the durable result",
       context do
    provider =
      cli_data!(context, ["provider", "create"], %{
        name: "lost response fixture",
        kind: "target",
        adapter_type: "fixture-target",
        configuration: %{endpoint: "reachable"},
        credentials: %{token: "private-cli-token"}
      })

    provider =
      cli_data!(context, ["provider", "enable", provider["id"]], %{
        expected_revision: provider["revision"]
      })

    target =
      cli_data!(context, ["target", "create"], %{
        name: "unknown-host",
        kind: "host",
        type_id: "custom-os",
        facts: %{}
      })

    method =
      cli_data!(context, ["access-method", "create"], %{
        target_id: target["id"],
        provider_id: provider["id"],
        provider_revision: provider["revision"],
        name: "lost response",
        method: "ssh",
        endpoint: "ssh://192.0.2.1:22",
        capabilities: []
      })

    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(context.stub, fn conn ->
      response = OpsondeWeb.Endpoint.call(conn, OpsondeWeb.Endpoint.init([]))

      if conn.request_path == "/api/v1/access-methods/#{method["id"]}/check" do
        assert response.status == 200
        Agent.update(attempts, &(&1 + 1))
        Req.Test.transport_error(response, :timeout)
      else
        response
      end
    end)

    error =
      capture_io(:stderr, fn ->
        capture_io(Jason.encode!(%{expected_revision: method["revision"]}), fn ->
          assert CLI.run(
                   ["access-method", "check", method["id"], "--input", "-"],
                   context.runtime
                 ) == 5
        end)
      end)

    assert %{"outcome" => "unknown", "error" => %{"code" => "transport_error"}} =
             Jason.decode!(error)

    assert Agent.get(attempts, & &1) == 1

    reread =
      cli_data!(context, ["access-method", "list"]) |> Enum.find(&(&1["id"] == method["id"]))

    assert reread["check"]["current"]
    assert reread["check"]["status"] == "passed"
    assert reread["capabilities"] == []
    refute error =~ "private-cli-token"
  end

  defp cli_data!(context, args, input \\ nil) do
    output =
      if input do
        capture_io(Jason.encode!(input), fn ->
          assert CLI.run(args ++ ["--input", "-"], context.runtime) == 0
        end)
      else
        capture_io(fn -> assert CLI.run(args, context.runtime) == 0 end)
      end

    output |> Jason.decode!() |> Map.fetch!("data")
  end
end
