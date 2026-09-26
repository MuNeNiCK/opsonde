defmodule Opsonde.Targets.BMC.SecretBindings do
  @moduledoc false

  alias Opsonde.Targets
  alias Opsonde.Targets.BMC.JSONPointer

  def check(definition, parameters, method_id) when is_map(parameters) do
    Enum.reduce_while(definition.secret_bindings, :ok, fn {pointer, reference}, :ok ->
      with {:ok, path} <- JSONPointer.segments(pointer),
           false <- present?(parameters, path),
           {:ok, %{active: true, access_method_id: ^method_id, revision: revision}} <-
             Targets.get_bmc_secret(reference["id"], authorize?: false),
           true <- revision == reference["revision"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :invalid_secret_binding}}
      end
    end)
  end

  def resolve(definition, parameters, method_id) when is_map(parameters) do
    Enum.reduce_while(definition.secret_bindings, {:ok, parameters, %{}}, fn
      {pointer, reference}, {:ok, current, values} ->
        with {:ok, path} <- JSONPointer.segments(pointer),
             false <- present?(current, path),
             {:ok, %{value: value}} <-
               Targets.load_bmc_secret_for_use(
                 reference["id"],
                 reference["revision"],
                 method_id,
                 authorize?: false
               ),
             true <- is_binary(value),
             {:ok, merged} <- insert(current, path, value) do
          {:cont, {:ok, merged, Map.put(values, pointer, value)}}
        else
          _ -> {:halt, {:error, :invalid_secret_binding}}
        end
    end)
  end

  defp present?(map, [key]) when is_map(map), do: Map.has_key?(map, key)

  defp present?(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, child} -> present?(child, rest)
      :error -> false
    end
  end

  defp present?(_value, _path), do: false

  defp insert(map, [key], value) when is_map(map) do
    if Map.has_key?(map, key), do: {:error, :present}, else: {:ok, Map.put(map, key, value)}
  end

  defp insert(map, [key | rest], value) when is_map(map) do
    case Map.get(map, key, %{}) do
      %{} = child ->
        with {:ok, updated} <- insert(child, rest, value) do
          {:ok, Map.put(map, key, updated)}
        end

      _other ->
        {:error, :invalid_path}
    end
  end

  defp insert(_value, _path, _secret), do: {:error, :invalid_path}
end
