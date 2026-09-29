defmodule Opsonde.Targets.OperationCatalog do
  @moduledoc false

  alias Opsonde.Providers

  def for_methods(methods, invocation) do
    with {:ok, provider_capabilities} <- provider_capabilities(methods, invocation) do
      {:ok,
       Map.new(methods, fn method ->
         {method.id,
          Map.fetch!(provider_capabilities, {method.provider_id, method.provider_revision})}
       end)}
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
end
