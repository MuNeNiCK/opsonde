defmodule Opsonde.Targets.IPMIRequestTest do
  use ExUnit.Case, async: true

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.IPMI

  @endpoint "ipmi://127.0.0.1:623"

  test "IPMI advertises one arbitrary command as an effect and validates it before dispatch" do
    {:ok, state} =
      IPMI.build(%{"endpoint" => @endpoint}, %{"username" => "fixture", "password" => "fixture"})

    assert {:ok, %Target.Capabilities{observations: observations, effects: effects}} =
             IPMI.capabilities(state, %{})

    assert Enum.any?(effects, fn operation ->
             operation.capability == "native.ipmi.effect" and
               operation.operation == "command.execute" and operation.native?
           end)

    refute Enum.any?(observations, &(&1.capability == "native.ipmi.observe"))
    assert "native.ipmi.effect" in IPMI.access_method_profile().capabilities

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
                 capability: "native.ipmi.observe",
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
      capability: "native.ipmi.effect",
      operation: "command.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: parameters
    }
  end
end
