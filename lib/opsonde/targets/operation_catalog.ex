defmodule Opsonde.Targets.OperationCatalog do
  @moduledoc false

  alias Opsonde.{Providers, Targets}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.BMC.OperationKey

  def for_methods(methods, invocation) do
    with {:ok, provider_capabilities} <- provider_capabilities(methods, invocation) do
      Enum.reduce_while(methods, {:ok, %{}}, fn method, {:ok, loaded} ->
        vocabulary =
          Map.fetch!(provider_capabilities, {method.provider_id, method.provider_revision})

        case effective_capabilities(method, vocabulary) do
          {:ok, capabilities} -> {:cont, {:ok, Map.put(loaded, method.id, capabilities)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp provider_capabilities(methods, invocation) do
    methods
    |> Enum.uniq_by(&{&1.provider_id, &1.provider_revision})
    |> Enum.reduce_while({:ok, %{}}, fn method, {:ok, loaded} ->
      key = {method.provider_id, method.provider_revision}

      case Providers.target_capabilities(
             method.provider_id,
             method.provider_revision,
             invocation,
             authorize?: false
           ) do
        {:ok, value} -> {:cont, {:ok, Map.put(loaded, key, value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp effective_capabilities(%{method: method} = access_method, vocabulary)
       when method in ["redfish", "ipmi"] do
    with {:ok, definitions} <-
           Targets.available_bmc_operations_for_method(access_method.id, authorize?: false) do
      advertised =
        vocabulary.observations
        |> Kernel.++(vocabulary.effects)
        |> Enum.map(& &1.capability)
        |> MapSet.new()

      operations =
        definitions
        |> Enum.filter(&MapSet.member?(advertised, OperationKey.capability(&1.request_kind)))
        |> Enum.map(&bmc_operation/1)

      {:ok,
       %ProviderTarget.Capabilities{
         observations:
           Enum.reject(vocabulary.observations, &(&1.operation == "bmc.api.available")) ++
             Enum.filter(operations, &(&1.capability == "observe.bmc_api")),
         effects:
           Enum.reject(vocabulary.effects, &(&1.operation == "bmc.api.available")) ++
             Enum.filter(operations, &(&1.capability == "effect.bmc_api"))
       }}
    end
  end

  defp effective_capabilities(_access_method, vocabulary), do: {:ok, vocabulary}

  defp bmc_operation(definition) do
    %ProviderTarget.Operation{
      capability: OperationKey.capability(definition.request_kind),
      operation: OperationKey.format(definition),
      description: definition.description,
      input_schema: definition.input_schema,
      output_schema: definition.output_schema,
      verification_schema: definition.verification_schema
    }
  end
end
