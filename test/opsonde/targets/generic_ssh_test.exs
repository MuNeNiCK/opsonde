defmodule Opsonde.Targets.GenericSSHTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.{PolicyError, PolicyRequest}
  alias Opsonde.Transports.SSH, as: Transport

  @password "correct horse battery staple"

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "opsonde-generic-ssh-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    write_private_key!(Path.join(directory, "ssh_host_rsa_key"), host_key)

    client_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    client_pem = encode_private_key(client_key)
    client_public = :ssh_file.extract_public_key(client_key)

    File.write!(
      Path.join(directory, "authorized_keys"),
      :ssh_file.encode([{client_public, []}], :auth_keys)
    )

    {:ok, commands} = Agent.start_link(fn -> [] end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"publickey,password",
        exec: {:direct, command_executor(commands)}
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

    %{
      endpoint: endpoint,
      fingerprint: fingerprint,
      client_pem: client_pem,
      commands: commands
    }
  end

  setup context do
    Agent.update(context.commands, fn _commands -> [] end)
    :ok
  end

  test "transport supports pinned password and in-memory public-key authentication", context do
    assert {:ok, password} = Transport.build(configuration(context), password_credentials())
    assert :ok = Transport.check(password, context.endpoint)

    assert {:ok, %Transport.Result{} = result} =
             Transport.exec(password, context.endpoint, "success")

    assert result.stdout == "ran:success"
    assert result.stderr == ""
    assert result.exit_status == 0

    assert {:ok, public_key} =
             Transport.build(configuration(context), public_key_credentials(context.client_pem))

    assert {:ok, %Transport.Result{stdout: "ran:key", exit_status: 0}} =
             Transport.exec(public_key, context.endpoint, "key")

    assert {:ok, %Transport.Result{stderr: stderr, exit_status: status}} =
             Transport.exec(password, context.endpoint, "stderr")

    assert stderr =~ "failed"
    assert status != 0
  end

  test "transport keeps host, auth, limit, timeout and cancellation failures typed", context do
    wrong_host =
      configuration(context, %{
        "host_key_fingerprints" => %{
          context.endpoint => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        }
      })

    assert {:ok, wrong_host} = Transport.build(wrong_host, password_credentials())
    assert {:error, :host_key, _message} = Transport.check(wrong_host, context.endpoint)

    assert {:ok, wrong_password} =
             Transport.build(configuration(context), password_credentials("wrong"))

    assert {:error, :authentication, _message} =
             Transport.check(wrong_password, context.endpoint)

    assert {:ok, limited} =
             Transport.build(
               configuration(context, %{"max_output_bytes" => 8}),
               password_credentials()
             )

    assert {:error, :output_limit_after_dispatch, _message} =
             Transport.exec(limited, context.endpoint, "large")

    assert {:ok, timed} =
             Transport.build(
               configuration(context, %{"operation_timeout_ms" => 500}),
               password_credentials()
             )

    assert {:error, :timeout_after_dispatch, _message} =
             Transport.exec(timed, context.endpoint, "slow")

    assert {:error, :cancelled, _message} =
             Transport.exec(password_config(context), context.endpoint, "success", fn -> true end)

    cancel_at = System.monotonic_time(:millisecond) + 500

    assert {:error, :cancelled_after_dispatch, _message} =
             Transport.exec(password_config(context), context.endpoint, "slow", fn ->
               System.monotonic_time(:millisecond) >= cancel_at
             end)
  end

  test "generic adapter exposes effects only and uses the registered method through policy",
       context do
    admin = Accounts.bootstrap!("generic-ssh-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("generic-ssh-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "generic-ssh",
        :target,
        "generic-ssh",
        configuration(context),
        password_credentials(),
        actor: admin
      )
      |> then(
        &Providers.check_provider!(&1.id, &1.revision, %{"endpoint" => context.endpoint},
          actor: admin
        )
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    assert %Target.Capabilities{observations: [], effects: [tool]} =
             Providers.target_capabilities!(provider.id, provider.revision, %{}, actor: operator)

    assert tool.capability == "effect.command"
    assert tool.operation == "command.execute"

    target =
      Targets.create_target!("future-router", "network_device", "junos", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "registered-generic-ssh",
        "generic",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        ["effect.command"],
        actor: admin
      )

    readonly_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :readonly, "never-readonly"),
        actor: operator
      )

    assert {:error, readonly_error} =
             Targets.dispatch_target_effect(readonly_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert policy_error(readonly_error).category == :forbidden
    assert commands(context) == []

    stale_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :full_access, "never-stale"),
        actor: operator
      )

    method = Targets.update_access_method!(method, method.revision, %{priority: 90}, actor: admin)

    assert {:error, stale_error} =
             Targets.dispatch_target_effect(stale_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert policy_error(stale_error).category == :stale_context
    assert commands(context) == []

    Targets.create_target_policy!(
      target.id,
      "blocked-command",
      [:effect],
      ["effect.command"],
      ["command.execute"],
      %{},
      %{"command" => %{"eq" => "never-policy"}},
      "command is forbidden",
      actor: admin
    )

    assert {:error, denied_error} =
             Targets.clear_target_request(
               request(target, method, :effect, :full_access, "never-policy"),
               actor: operator
             )

    assert policy_error(denied_error).category == :denied
    assert commands(context) == []

    effect_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :full_access, "apply"),
        actor: operator
      )

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(effect_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert details["stdout"] == %{"encoding" => "utf-8", "value" => "ran:apply"}
    assert commands(context) == ["apply"]

    verification_clearance =
      Targets.clear_target_request!(
        request(target, method, :verification, :full_access, "verify"),
        actor: operator
      )

    assert %Target.Verification{status: :unknown, facts: facts} =
             Targets.dispatch_target_verification!(verification_clearance, %{}, actor: operator)

    assert facts["stdout"] == %{"encoding" => "utf-8", "value" => "ran:verify"}
    assert commands(context) == ["apply", "verify"]
  end

  defp configuration(context, overrides \\ %{}) do
    Map.merge(
      %{
        "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
        "connect_timeout_ms" => 2_000,
        "operation_timeout_ms" => 2_000,
        "max_output_bytes" => 32_768
      },
      overrides
    )
  end

  defp password_config(context) do
    {:ok, config} = Transport.build(configuration(context), password_credentials())
    config
  end

  defp password_credentials(password \\ "secret") do
    %{"username" => "tester", "auth_method" => "password", "password" => password}
  end

  defp public_key_credentials(key) do
    %{"username" => "tester", "auth_method" => "public_key", "private_key" => key}
  end

  defp request(target, method, kind, mode, command) do
    struct!(PolicyRequest,
      kind: kind,
      authority_mode: mode,
      target_id: target.id,
      target_revision: target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: "effect.command",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"command" => command},
      operation_id: if(kind in [:effect, :verification], do: "operation-#{command}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{command}")
    )
  end

  defp commands(context), do: Agent.get(context.commands, &Enum.reverse/1)

  defp command_executor(commands) do
    fn command ->
      command = to_string(command)
      Agent.update(commands, &[command | &1])

      case command do
        "stderr" ->
          {:error, "failed"}

        "large" ->
          {:ok, String.duplicate("x", 100)}

        "slow" ->
          Process.sleep(1_000)
          {:ok, "done"}

        value ->
          {:ok, "ran:#{value}"}
      end
    end
  end

  defp write_private_key!(path, key) do
    File.write!(path, encode_private_key(key))
    File.chmod!(path, 0o600)
  end

  defp encode_private_key(key) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp policy_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %PolicyError{} = error -> error
      nested when is_map(nested) -> policy_error(nested)
      _other -> nil
    end)
  end

  defp policy_error(_error), do: nil
end
