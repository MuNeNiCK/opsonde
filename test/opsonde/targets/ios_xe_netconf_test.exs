defmodule Opsonde.Targets.IOSXENETCONFTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.PolicyRequest
  alias Opsonde.Targets.IOSXE.NETCONF
  alias Opsonde.Transports.SSH

  @password "correct horse battery staple"
  @capabilities ["observe.system", "observe.interface", "effect.interface"]

  defmodule Peer do
    @behaviour :ssh_server_channel

    @delimiter "]]>]]>"
    @server_hello """
    <hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"><capabilities><capability>urn:ietf:params:netconf:base:1.0</capability><capability>urn:ietf:params:netconf:base:1.1</capability></capabilities><session-id>1</session-id></hello>
    """

    @impl true
    def init([agent]),
      do: {:ok, %{agent: agent, connection: nil, channel: nil, phase: :hello, input: ""}}

    @impl true
    def handle_msg({:ssh_channel_up, channel, connection}, state),
      do: {:ok, %{state | connection: connection, channel: channel}}

    def handle_msg(_message, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg({:ssh_cm, connection, {:data, channel, _stream, data}}, state) do
      consume(%{state | connection: connection, channel: channel, input: state.input <> data})
    end

    def handle_ssh_msg({:ssh_cm, _connection, {:eof, channel}}, state),
      do: {:stop, channel, state}

    def handle_ssh_msg(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp consume(%{phase: :hello} = state) do
      case :binary.match(state.input, @delimiter) do
        {position, length} ->
          rest =
            binary_part(
              state.input,
              position + length,
              byte_size(state.input) - position - length
            )

          :ok = :ssh_connection.send(state.connection, state.channel, @server_hello <> @delimiter)
          consume(%{state | phase: :rpc, input: rest})

        :nomatch ->
          {:ok, state}
      end
    end

    defp consume(%{phase: :rpc} = state) do
      case chunk(state.input) do
        {:ok, rpc, rest} ->
          {reply, delay_ms} = response(state.agent, rpc)
          Process.sleep(delay_ms)
          :ok = :ssh_connection.send(state.connection, state.channel, frame(reply))
          consume(%{state | input: rest})

        :more ->
          {:ok, state}
      end
    end

    defp chunk("\n#" <> framed) do
      case :binary.match(framed, "\n") do
        {position, 1} ->
          length_text = binary_part(framed, 0, position)
          payload = binary_part(framed, position + 1, byte_size(framed) - position - 1)

          case Integer.parse(length_text) do
            {length, ""} when length > 0 and byte_size(payload) >= length + 4 ->
              rpc = binary_part(payload, 0, length)
              "\n##\n" <> rest = binary_part(payload, length, byte_size(payload) - length)
              {:ok, rpc, rest}

            _other ->
              :more
          end

        :nomatch ->
          :more
      end
    end

    defp chunk(_input), do: :more
    defp frame(xml), do: "\n##{byte_size(xml)}\n#{xml}\n##\n"

    defp response(agent, rpc) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | rpcs: [rpc | state.rpcs]}
        {reply, delay_ms, state} = rpc_response(rpc, state)
        {{reply, delay_ms}, state}
      end)
    end

    defp rpc_response(rpc, state) do
      cond do
        String.contains?(rpc, "<edit-config>") -> edit_response(rpc, state)
        state.mode == :malformed -> {"not xml", 0, %{state | mode: :normal}}
        state.mode == :wrong_message_id -> {system_reply("wrong"), 0, %{state | mode: :normal}}
        String.contains?(rpc, "<native") -> {system_reply("opsonde-1"), 0, state}
        String.contains?(rpc, "<interfaces") -> {interface_reply(state), 0, state}
      end
    end

    defp edit_response(_rpc, %{mode: :rpc_error} = state) do
      reply =
        "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"opsonde-1\"><rpc-error><error-type>application</error-type><error-tag>operation-failed</error-tag></rpc-error></rpc-reply>"

      {reply, 0, %{state | mode: :normal, edit_received?: true}}
    end

    defp edit_response(rpc, state) do
      interface =
        cond do
          match = Regex.run(~r/<description>(.*?)<\/description>/s, rpc) ->
            Map.put(state.interface, :description, match |> Enum.at(1) |> unescape())

          String.contains?(rpc, "<enabled>false</enabled>") ->
            Map.put(state.interface, :enabled, false)

          String.contains?(rpc, "<enabled>true</enabled>") ->
            Map.put(state.interface, :enabled, true)
        end

      reply =
        "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"opsonde-1\"><ok/></rpc-reply>"

      {reply, state.delay_edit_ms, %{state | interface: interface, edit_received?: true}}
    end

    defp system_reply(message_id) do
      """
      <rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="#{message_id}"><data><native xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-native"><hostname>router-one</hostname><version>17.15.01</version></native></data></rpc-reply>
      """
    end

    defp interface_reply(%{mode: :missing_interface}) do
      "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"opsonde-1\"><data><interfaces xmlns=\"urn:ietf:params:xml:ns:yang:ietf-interfaces\"></interfaces><interfaces-state xmlns=\"urn:ietf:params:xml:ns:yang:ietf-interfaces\"></interfaces-state></data></rpc-reply>"
    end

    defp interface_reply(%{interface: interface}) do
      admin = if interface.enabled, do: "up", else: "down"

      """
      <rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="opsonde-1"><data><interfaces xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces"><interface><name>Loopback100</name><description>#{escape(interface.description)}</description><enabled>#{interface.enabled}</enabled></interface></interfaces><interfaces-state xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces"><interface><name>Loopback100</name><admin-status>#{admin}</admin-status><oper-status>#{admin}</oper-status><statistics><in-errors>2</in-errors><out-errors>3</out-errors></statistics></interface></interfaces-state></data></rpc-reply>
      """
    end

    defp escape(value), do: String.replace(value, "&", "&amp;")
    defp unescape(value), do: String.replace(value, "&amp;", "&")
  end

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "opsonde-ios-xe-netconf-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    private_key = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    host_key_path = Path.join(directory, "ssh_host_rsa_key")
    File.write!(host_key_path, :public_key.pem_encode([private_key]))
    File.chmod!(host_key_path, 0o600)
    {:ok, agent} = Agent.start_link(fn -> initial_peer_state() end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        ssh_cli: :no_cli,
        subsystems: [{~c"netconf", {Peer, [agent]}}]
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

    %{endpoint: endpoint, fingerprint: fingerprint, agent: agent}
  end

  setup context do
    Agent.update(context.agent, fn _state -> initial_peer_state() end)
    admin = Accounts.bootstrap!("iosxe-netconf-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("iosxe-netconf-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "ios-xe-netconf",
        :target,
        "ios-xe-netconf",
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

    target =
      Targets.create_target!("router-one", "network_device", "cisco_ios_xe", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "NETCONF",
        "cisco_ios_xe",
        "netconf",
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

  test "NETCONF keeps the protocol-sized default and explicit output bounds" do
    assert {:ok, %SSH.Config{max_output_bytes: 60_000}} =
             NETCONF.build(configuration_for("ssh://ios-xe.example:830"), credentials())

    assert {:ok, %SSH.Config{max_output_bytes: 40_000}} =
             NETCONF.build(
               Map.put(configuration_for("ssh://ios-xe.example:830"), "max_output_bytes", 40_000),
               credentials()
             )
  end

  test "public NETCONF route constructs RPCs, observes, applies and freshly verifies", context do
    assert %Target.Capabilities{} =
             Providers.target_capabilities!(context.provider.id, context.provider.revision, %{},
               actor: context.operator
             )

    system = observe!(context, "observe.system", "ios_xe.system.inspect", %{})
    assert system.facts == %{"hostname" => "router-one", "version" => "17.15.01"}

    interface =
      observe!(context, "observe.interface", "ios_xe.interface.inspect", %{
        "interface" => "Loopback100"
      })

    assert interface.facts["description"] == "initial"
    assert interface.facts["input_errors"] == 2

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "ops & core",
               "expected_description" => "initial"
             })

    assert %Target.Verification{status: :verified, facts: %{"description" => "ops & core"}} =
             verify!(context, %{"description" => "ops & core"})

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    assert %Target.Verification{status: :verified, facts: %{"enabled" => false}} =
             verify!(context, %{"enabled" => false})

    rpcs = rpcs(context)
    assert Enum.any?(rpcs, &String.contains?(&1, "<native xmlns="))
    assert Enum.any?(rpcs, &String.contains?(&1, "<description>ops &amp; core</description>"))
    assert Enum.any?(rpcs, &String.contains?(&1, "<enabled>false</enabled>"))

    assert Enum.any?(
             rpcs,
             &String.contains?(&1, "<error-option>rollback-on-error</error-option>")
           )

    assert Enum.all?(rpcs, &String.contains?(&1, "message-id=\"opsonde-1\""))
  end

  test "NETCONF route rejects stale state, rpc-errors and malformed replies", context do
    assert %Target.EffectResult{status: :failed, details: %{"category" => "stale"}} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "changed",
               "expected_description" => "outdated"
             })

    refute Enum.any?(rpcs(context), &String.contains?(&1, "<edit-config>"))
    Agent.update(context.agent, &%{&1 | mode: :rpc_error})

    assert %Target.EffectResult{status: :failed, details: %{"category" => "rejected"}} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    for mode <- [:wrong_message_id, :malformed, :missing_interface] do
      Agent.update(context.agent, &%{&1 | mode: mode})

      {capability, operation, selectors} =
        if mode == :missing_interface do
          {"observe.interface", "ios_xe.interface.inspect", %{"interface" => "Loopback100"}}
        else
          {"observe.system", "ios_xe.system.inspect", %{}}
        end

      clearance =
        request(context, :observation, capability, operation, selectors, %{})
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, _error} =
               Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)
    end
  end

  test "NETCONF route preserves post-dispatch cancellation and connection failures", context do
    Agent.update(context.agent, &%{&1 | delay_edit_ms: 1_000})

    clearance =
      request(
        context,
        :effect,
        "effect.interface",
        "ios_xe.interface.description.set",
        %{"interface" => "Loopback100"},
        %{"description" => "changed", "expected_description" => "initial"}
      )
      |> Targets.clear_target_request!(actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(
               clearance,
               %{cancelled?: fn -> Agent.get(context.agent, & &1.edit_received?) end},
               actor: context.operator,
               authorize?: false
             )

    unreachable =
      Providers.create_provider!(
        "unreachable-ios-xe-netconf",
        :target,
        "ios-xe-netconf",
        configuration_for("ssh://127.0.0.1:1"),
        credentials(),
        actor: context.admin
      )

    failed =
      Providers.check_provider!(
        unreachable.id,
        unreachable.revision,
        %{"endpoint" => "ssh://127.0.0.1:1"},
        actor: context.admin
      )

    assert failed.check_status == :failed
  end

  defp initial_peer_state do
    %{
      rpcs: [],
      mode: :normal,
      delay_edit_ms: 0,
      edit_received?: false,
      interface: %{description: "initial", enabled: true}
    }
  end

  defp observe!(context, capability, operation, selectors) do
    request(context, :observation, capability, operation, selectors, %{})
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_observation!(%{}, actor: context.operator)
  end

  defp effect!(context, operation, parameters) do
    request(
      context,
      :effect,
      "effect.interface",
      operation,
      %{"interface" => "Loopback100"},
      parameters
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
  end

  defp verify!(context, expected) do
    request(
      context,
      :verification,
      "observe.interface",
      "ios_xe.interface.inspect",
      %{"interface" => "Loopback100"},
      %{},
      expected
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_verification!(%{}, actor: context.operator)
  end

  defp request(context, kind, capability, operation, selectors, parameters, expected \\ %{}) do
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
      operation_id: if(kind in [:effect, :verification], do: Ecto.UUID.generate()),
      idempotency_key: if(kind == :effect, do: Ecto.UUID.generate()),
      expected: expected
    )
  end

  defp configuration(context), do: configuration_for(context.endpoint, context.fingerprint)

  defp configuration_for(
         endpoint,
         fingerprint \\ "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
       ) do
    %{
      "host_key_fingerprints" => %{endpoint => fingerprint},
      "connect_timeout_ms" => 2_000,
      "operation_timeout_ms" => 500
    }
  end

  defp credentials do
    %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
  end

  defp rpcs(context), do: Agent.get(context.agent, &Enum.reverse(&1.rpcs))
end
