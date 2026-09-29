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

  test "CLI registers both BMC Methods through the authenticated API", context do
    catalog = capture_io(fn -> assert CLI.run(["target-type", "list"], context.runtime) == 0 end)
    assert catalog =~ "bmc-redfish"

    target =
      capture_io(
        ~s({"name":"rack-bmc","kind":"management_plane","type_id":"bmc","facts":{}}),
        fn ->
          assert CLI.run(["target", "create", "--input", "-"], context.runtime) == 0
        end
      )
      |> Jason.decode!()
      |> get_in(["data"])

    for {adapter_type, method_name, endpoint} <- [
          {"bmc-redfish", "redfish", "https://bmc.example.test:8443"},
          {"bmc-ipmi", "ipmi", "ipmi://bmc.example.test:623"}
        ] do
      provider =
        Providers.create_provider!(
          "CLI #{method_name}",
          :target,
          adapter_type,
          %{"endpoint" => endpoint},
          %{"username" => "admin", "password" => "test-only"},
          actor: context.admin
        )
        |> then(
          &Providers.record_provider_check!(&1, &1.revision, :passed, nil, nil, authorize?: false)
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
