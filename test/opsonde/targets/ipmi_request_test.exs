defmodule Opsonde.Targets.IPMIRequestTest do
  use ExUnit.Case, async: true

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.IPMI

  @endpoint "ipmi://127.0.0.1:623"

  test "classify exact IPMI requests without assuming an arbitrary command is read-only" do
    {:ok, state} =
      IPMI.build(%{}, %{"username" => "fixture", "password" => "fixture"})

    {:ok, state} = IPMI.bind_connection(state, %Target.Connection{endpoint: @endpoint})

    raw = %Target.MethodRequest{
      provider_revision: 1,
      connection: %Target.Connection{endpoint: @endpoint},
      capability: "request.ipmi.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"netfn" => 6, "command" => 1}
    }

    assert {:ok, %Target.RequestClassification{kind: :effect}} =
             Target.classify_request(IPMI, state, raw)

    power = %{raw | capability: "observe.power", operation: "bmc.power.inspect", parameters: %{}}

    assert {:ok, %Target.RequestClassification{kind: :observation}} =
             Target.classify_request(IPMI, state, power)

    for invalid <- [
          %{raw | connection: %Target.Connection{endpoint: "ipmi://other.example:623"}},
          %{raw | parameters: %{"netfn" => 7, "command" => 1}},
          %{raw | parameters: %{"netfn" => 6, "command" => 1, "data_hex" => "F"}},
          %{raw | capability: "request.ipmi.observe"}
        ] do
      assert {:error, :failed, _} = Target.classify_request(IPMI, state, invalid)
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
