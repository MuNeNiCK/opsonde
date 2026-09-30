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
  end

  test "CLI registers both BMC Methods through the authenticated API", context do
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

    target =
      capture_io(
        ~s({"name":"rack-bmc","kind":"management_plane","type_id":"custom-bmc","facts":{}}),
        fn ->
          assert CLI.run(["target", "create", "--input", "-"], context.runtime) == 0
        end
      )
      |> Jason.decode!()
      |> get_in(["data"])

    for {adapter_type, method_name, endpoint} <- [
          {"redfish", "redfish", "https://bmc.example.test:8443"},
          {"ipmi", "ipmi", "ipmi://bmc.example.test:623"}
        ] do
      {configuration, credentials} = Opsonde.TargetConnectionFixture.input(adapter_type, endpoint)

      provider =
        Providers.create_provider!(
          "CLI #{method_name}",
          :target,
          adapter_type,
          configuration,
          credentials,
          actor: context.admin
        )
        |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

      method_input =
        Jason.encode!(%{
          "target_id" => target["id"],
          "provider_id" => provider.id,
          "name" => method_name,
          "method" => method_name,
          "endpoint" => endpoint,
          "provider_revision" => provider.revision,
          "priority" => 100,
          "capabilities" => ["observe.power"]
        })

      method =
        capture_io(method_input, fn ->
          assert CLI.run(["access-method", "create", "--input", "-"], context.runtime) == 0
        end)
        |> Jason.decode!()
        |> get_in(["data"])

      assert method["target_id"] == target["id"]
      assert method["provider_id"] == provider.id
      assert Targets.get_access_method!(method["id"], authorize?: false).method == method_name
    end
  end
end
