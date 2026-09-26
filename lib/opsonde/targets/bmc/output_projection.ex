defmodule Opsonde.Targets.BMC.OutputProjection do
  @moduledoc false

  @max_depth 16

  def project(_value, %{"type" => "object", "additionalProperties" => false} = schema, true) do
    if Map.get(schema, "properties", %{}) == %{},
      do: {:ok, %{}},
      else: {:error, :invalid_output}
  end

  def project(value, %{"type" => "object"} = schema, false) do
    with {:ok, projected} <- project_value(value, schema, 0),
         {:ok, root} <- JSV.build(schema, warnings: :silent),
         {:ok, _validated} <- JSV.validate(projected, root, cast: false) do
      {:ok, projected}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def project(_value, _schema, _secret_bound?), do: {:error, :invalid_output}

  defp project_value(value, %{"type" => "object"} = schema, depth)
       when is_map(value) and depth < @max_depth do
    schema
    |> Map.get("properties", %{})
    |> Enum.reduce_while({:ok, %{}}, fn {key, child}, {:ok, fields} ->
      case Map.fetch(value, key) do
        :error ->
          {:cont, {:ok, fields}}

        {:ok, item} ->
          case project_value(item, child, depth + 1) do
            {:ok, selected} -> {:cont, {:ok, Map.put(fields, key, selected)}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp project_value(values, %{"type" => "array", "items" => schema}, depth)
       when is_list(values) and depth < @max_depth do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, selected} ->
      case project_value(value, schema, depth + 1) do
        {:ok, item} -> {:cont, {:ok, [item | selected]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp project_value(value, %{"type" => type}, _depth)
       when type in ["string", "integer", "number", "boolean", "null"],
       do: {:ok, value}

  defp project_value(_value, _schema, _depth), do: {:error, :invalid_output}
end
