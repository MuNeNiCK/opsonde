defmodule Opsonde.Targets.LinuxSSHTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.PolicyRequest

  @password "correct horse battery staple"
  @definition String.duplicate("a", 64)
  @capabilities [
    "observe.identity",
    "observe.processes",
    "observe.service",
    "observe.journal",
    "effect.service"
  ]

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "opsonde-linux-ssh-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    private_key = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    host_key_path = Path.join(directory, "ssh_host_rsa_key")
    File.write!(host_key_path, :public_key.pem_encode([private_key]))
    File.chmod!(host_key_path, 0o600)
    {:ok, commands} = Agent.start_link(fn -> [] end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        exec: {:direct, executor(commands)}
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    endpoint = "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"

    fingerprint =
      host_key
      |> :ssh_file.extract_public_key()
      |> then(&:ssh.hostkey_fingerprint(:sha256, &1))
      |> to_string()

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(directory)
    end)

    %{endpoint: endpoint, fingerprint: fingerprint, commands: commands}
  end

  setup context do
    Agent.update(context.commands, fn _commands -> [] end)

    admin = Accounts.bootstrap!("linux-ssh-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("linux-ssh-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "linux-ssh",
        :target,
        "linux-ssh",
        configuration(context),
        credentials(),
        actor: admin
      )
      |> then(
        &Providers.check_provider!(&1.id, &1.revision, %{"endpoint" => context.endpoint},
          actor: admin
        )
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "linux-ssh",
        "linux",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )

    Map.merge(context, %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method
    })
  end

  test "public capabilities and observations accept bounded unknown Linux workloads", context do
    assert %Target.Capabilities{observations: observations, effects: [effect]} =
             Providers.target_capabilities!(
               context.provider.id,
               context.provider.revision,
               %{},
               actor: context.operator
             )

    assert Enum.map(observations, & &1.operation) == [
             "linux.identity.inspect",
             "linux.process.list",
             "linux.service.inspect",
             "linux.journal.read"
           ]

    tools = Map.new(observations, &{&1.operation, &1})
    service_tool = tools["linux.service.inspect"]

    assert Map.has_key?(service_tool.output_schema["properties"], "active_state")
    assert Map.has_key?(service_tool.output_schema["properties"], "sub_state")

    assert MapSet.new(Map.keys(service_tool.verification_schema["properties"])) ==
             MapSet.new(
               ~w(load_state active_state sub_state unit_file_state need_daemon_reload definition_sha256)
             )

    assert effect.operation == "linux.service.restart"

    assert effect.evidence_requirements == [
             %Target.EvidenceRequirement{
               parameter: "expected_definition_sha256",
               fact: "definition_sha256",
               observation: "linux.service.inspect"
             }
           ]

    assert get_in(effect.input_schema, [
             "properties",
             "parameters",
             "properties",
             "expected_definition_sha256",
             "description"
           ]) =~ "never infer or invent"

    identity = observe!(context, "observe.identity", "linux.identity.inspect", %{}, %{})
    assert_schema_accepts!(tools["linux.identity.inspect"].output_schema, identity.facts)
    assert identity.facts["kernel"] == "Linux 6.8.0 x86_64"
    assert identity.facts["machine_id"] == "machine-01"

    processes = observe!(context, "observe.processes", "linux.process.list", %{}, %{"limit" => 2})
    assert_schema_accepts!(tools["linux.process.list"].output_schema, processes.facts)
    assert Enum.map(processes.facts["processes"], & &1["command"]) == ["beam.smp", "sshd"]

    unit = "discovered@42.service"

    service =
      observe!(context, "observe.service", "linux.service.inspect", %{"unit" => unit}, %{})

    assert_schema_accepts!(service_tool.output_schema, service.facts)
    assert service.facts["unit"] == unit
    assert service.facts["active_state"] == "active"
    assert service.facts["definition_sha256"] == @definition

    journal =
      observe!(context, "observe.journal", "linux.journal.read", %{"unit" => unit}, %{
        "lines" => 2
      })

    assert_schema_accepts!(tools["linux.journal.read"].output_schema, journal.facts)
    assert journal.facts == %{"unit" => unit, "entries" => ["entry one", "entry two"]}
  end

  test "restart binds the observed definition and fresh verification reads current state",
       context do
    unit = "discovered@42.service"

    effect =
      policy_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => unit},
        %{
          "expected_definition_sha256" => @definition
        }
      )

    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    [command] = commands(context)
    assert command =~ "actual="
    assert command =~ @definition
    assert command =~ "systemctl restart -- 'discovered@42.service'"

    verification =
      policy_request(
        context,
        :verification,
        "observe.service",
        "linux.service.inspect",
        %{"unit" => unit},
        %{},
        %{"active_state" => "active", "sub_state" => "running"}
      )

    verification_clearance =
      Targets.clear_target_request!(verification, actor: context.operator)

    assert %Target.Verification{status: :verified, facts: facts} =
             Targets.dispatch_target_verification!(verification_clearance, %{},
               actor: context.operator
             )

    assert facts["definition_sha256"] == @definition

    not_verified = %{verification | expected: %{"active_state" => "inactive"}}
    not_verified_clearance = Targets.clear_target_request!(not_verified, actor: context.operator)

    assert %Target.Verification{status: :not_verified} =
             Targets.dispatch_target_verification!(not_verified_clearance, %{},
               actor: context.operator
             )
  end

  test "invalid unit stops locally and post-dispatch timeout stays unknown", context do
    invalid =
      policy_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => "../../etc/shadow"},
        %{"expected_definition_sha256" => @definition}
      )

    invalid_clearance = Targets.clear_target_request!(invalid, actor: context.operator)

    assert {:error, _error} =
             Targets.dispatch_target_effect(invalid_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert commands(context) == []

    slow =
      policy_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => "slow.service"},
        %{"expected_definition_sha256" => @definition}
      )

    slow_clearance = Targets.clear_target_request!(slow, actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(slow_clearance, %{},
               actor: context.operator,
               authorize?: false
             )
  end

  defp observe!(context, capability, operation, selectors, parameters) do
    request = policy_request(context, :observation, capability, operation, selectors, parameters)
    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
  end

  defp policy_request(
         context,
         kind,
         capability,
         operation,
         selectors,
         parameters,
         expected \\ %{}
       ) do
    struct!(PolicyRequest,
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: capability,
      operation: operation,
      selectors: selectors,
      parameters: parameters,
      operation_id:
        if(kind in [:effect, :verification], do: "operation-#{System.unique_integer()}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{System.unique_integer()}"),
      expected: expected
    )
  end

  defp configuration(context) do
    %{
      "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
      "connect_timeout_ms" => 2_000,
      "operation_timeout_ms" => 500,
      "max_output_bytes" => 32_768,
      "privilege" => "none"
    }
  end

  defp credentials do
    %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
  end

  defp commands(context), do: Agent.get(context.commands, &Enum.reverse/1)

  defp assert_schema_accepts!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(facts, root, cast: false)
  end

  defp executor(commands) do
    fn command ->
      command = to_string(command)
      Agent.update(commands, &[command | &1])

      cond do
        command == "printf 'Kernel='; uname -srm; printf 'MachineId='; cat /etc/machine-id" ->
          {:ok, "Kernel=Linux 6.8.0 x86_64\nMachineId=machine-01\n"}

        String.starts_with?(command, "ps -eo") ->
          {:ok, "101 1 S beam.smp\n202 1 S sshd\n"}

        String.contains?(command, "journalctl") ->
          {:ok, "entry one\nentry two\n"}

        String.contains?(command, "systemctl restart") and
            String.contains?(command, "slow.service") ->
          Process.sleep(1_000)
          {:ok, ""}

        String.contains?(command, "systemctl restart") ->
          {:ok, ""}

        String.contains?(command, "systemctl show") ->
          unit =
            if String.contains?(command, "discovered@42.service"),
              do: "discovered@42.service",
              else: "unknown.service"

          {:ok,
           "Id=#{unit}\nLoadState=loaded\nActiveState=active\nSubState=running\nUnitFileState=enabled\nFragmentPath=/etc/systemd/system/#{unit}\nDropInPaths=\nNeedDaemonReload=no\nExecMainPID=101\nDefinitionSHA256=#{@definition}\n"}

        true ->
          {:error, "unsupported command"}
      end
    end
  end
end
