defmodule Opsonde.Targets.IPMIRequestTest do
  use ExUnit.Case, async: true

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.IPMI

  @endpoint "ipmi://127.0.0.1:623"

  @tag ipmi_deadline: true
  test "IPMI checks do not send delayed requests after their deadline" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    credentials = %{"username" => "fixture", "password" => "fixture"}
    {:ok, slow} = IPMI.build(%{"timeout_ms" => 1000}, credentials)
    {:ok, short} = IPMI.build(%{"timeout_ms" => 100}, credentials)
    endpoint = %{"endpoint" => "ipmi://127.0.0.1:#{port}"}
    waiting = Task.async(fn -> IPMI.check(slow, endpoint) end)
    assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 500)
    started = System.monotonic_time(:millisecond)

    assert {:error, :unreachable, _} = IPMI.check(short, endpoint)
    assert System.monotonic_time(:millisecond) - started < 500
    # A transport with independent sessions may have sent a timely handshake.
    _ = :gen_udp.recv(socket, 0, 0)
    assert {:error, :unreachable, _} = Task.await(waiting, 2000)
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
  end

  @tag ipmi_deadline: true
  test "IPMI connection checks finish within the configured deadline when the peer stays silent" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)

    {:ok, state} =
      IPMI.build(%{"timeout_ms" => 100}, %{"username" => "fixture", "password" => "fixture"})

    started = System.monotonic_time(:millisecond)

    assert {:error, :unreachable, _} =
             IPMI.check(state, %{"endpoint" => "ipmi://127.0.0.1:#{port}"})

    assert System.monotonic_time(:millisecond) - started < 500
    assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 100)
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
  end

  @tag ipmi_addressing: true
  test "IPMI Methods accept exact LUN and bridge addressing without changing effect authority" do
    for adapter <- [
          IPMI,
          Opsonde.Targets.Profiles.HPEILO.IPMI,
          Opsonde.Targets.Profiles.DellIDRAC.IPMI
        ] do
      {:ok, state} = adapter.build(%{}, %{"username" => "fixture", "password" => "fixture"})
      {:ok, state} = adapter.bind_connection(state, %Target.Connection{endpoint: @endpoint})

      parameters = %{
        "netfn" => 6,
        "command" => 1,
        "lun" => 1,
        "target_address" => 0x30,
        "target_channel" => 0,
        "transit_address" => 0x20,
        "transit_channel" => 1
      }

      effect = request(parameters)

      exact =
        struct!(
          Target.MethodRequest,
          Map.take(
            Map.from_struct(effect),
            [:provider_revision, :connection, :capability, :operation, :selectors, :parameters]
          )
        )

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(adapter, state, exact)

      assert {:error, :cancelled, _} =
               adapter.effect(state, effect, %{cancelled?: fn -> true end})

      for invalid <- [
            Map.put(parameters, "lun", 4),
            Map.put(parameters, "target_address", 256),
            Map.put(parameters, "target_channel", 16),
            Map.put(parameters, "transit_address", -1),
            Map.put(parameters, "transit_channel", "1")
          ] do
        assert {:error, :failed, _} =
                 Target.classify_request(adapter, state, %{exact | parameters: invalid})
      end
    end
  end

  test "classify exact IPMI requests without assuming an arbitrary command is read-only" do
    raw = %Target.MethodRequest{
      provider_revision: 1,
      connection: %Target.Connection{endpoint: @endpoint},
      capability: "request.ipmi.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"netfn" => 6, "command" => 1}
    }

    power = %{raw | capability: "observe.power", operation: "bmc.power.inspect", parameters: %{}}

    for adapter <- [
          IPMI,
          Opsonde.Targets.Profiles.HPEILO.IPMI,
          Opsonde.Targets.Profiles.DellIDRAC.IPMI
        ] do
      {:ok, state} = adapter.build(%{}, %{"username" => "fixture", "password" => "fixture"})
      {:ok, state} = adapter.bind_connection(state, %Target.Connection{endpoint: @endpoint})

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(adapter, state, raw)

      assert {:ok, %Target.RequestClassification{kind: :observation}} =
               Target.classify_request(adapter, state, power)

      for invalid <- [
            %{raw | connection: %Target.Connection{endpoint: "ipmi://other.example:623"}},
            %{raw | parameters: %{"netfn" => 7, "command" => 1}},
            %{raw | parameters: %{"netfn" => 6, "command" => 1, "data_hex" => "F"}},
            %{raw | capability: "request.ipmi.observe"}
          ] do
        assert {:error, :failed, _} = Target.classify_request(adapter, state, invalid)
      end
    end
  end

  test "IPMI advertises one arbitrary command as an effect and validates it before dispatch" do
    {:ok, state} =
      IPMI.build(%{}, %{"username" => "fixture", "password" => "fixture"})

    {:ok, state} = IPMI.bind_connection(state, %Target.Connection{endpoint: @endpoint})

    assert {:ok, %Target.Capabilities{observations: observations, effects: effects}} =
             IPMI.capabilities(state, %{})

    assert Enum.any?(effects, fn operation ->
             operation.capability == "request.ipmi.effect" and
               operation.operation == "command.execute"
           end)

    refute Enum.any?(observations, &(&1.capability == "request.ipmi.observe"))
    assert "request.ipmi.effect" in IPMI.access_method_profile().capabilities

    request = request(%{"netfn" => 6, "command" => 1, "data_hex" => ""})
    cancelled = %{cancelled?: fn -> true end}

    assert {:error, :cancelled, _} = IPMI.effect(state, request, cancelled)

    for parameters <- [
          %{"netfn" => 7, "command" => 1},
          %{"netfn" => 6, "command" => 256},
          %{"netfn" => 6, "command" => 1, "data_hex" => "F"},
          %{"netfn" => 6, "command" => 1, "data_hex" => String.duplicate("AA", 2049)},
          %{"netfn" => 6, "command" => 1, "unexpected" => true}
        ] do
      assert {:error, :failed, _} = IPMI.effect(state, request(parameters), cancelled)
    end

    assert {:error, :failed, _} =
             IPMI.observe(
               state,
               %Target.ObservationRequest{
                 provider_revision: 1,
                 target_id: "fixture",
                 target_revision: 1,
                 access_method_id: "fixture",
                 access_method_revision: 1,
                 connection: %Target.Connection{endpoint: @endpoint},
                 capability: "request.ipmi.observe",
                 operation: "command.observe",
                 authorization_digest: "fixture",
                 parameters: %{"netfn" => 6, "command" => 1}
               },
               cancelled
             )
  end

  defp request(parameters) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: "fixture",
      target_revision: 1,
      access_method_id: "fixture",
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: @endpoint},
      capability: "request.ipmi.effect",
      operation: "command.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: parameters
    }
  end
end
