defmodule Opsonde.Targets.PolicyMatcher do
  @moduledoc false

  @operators ~w(eq prefix contains in)
  @max_depth 6
  @max_entries 100

  def validate(pattern) when is_map(pattern) do
    with {:ok, count} <- validate_node(pattern, 0, 0),
         true <- count <= @max_entries do
      :ok
    else
      false -> {:error, "has too many matcher entries"}
      {:error, _reason} = error -> error
    end
  end

  def validate(_pattern), do: {:error, "must be a matcher map"}

  def match(pattern, value) when is_map(pattern) and is_map(value),
    do: match_map(pattern, value)

  def match(_pattern, _value), do: {:error, :invalid_matcher_input}

  defp validate_node(_node, depth, _count) when depth > @max_depth,
    do: {:error, "matcher nesting is too deep"}

  defp validate_node(node, depth, count) when is_map(node) do
    operator_keys = Enum.filter(Map.keys(node), &(&1 in @operators))

    cond do
      operator_keys != [] ->
        validate_leaf(node, operator_keys, count)

      Enum.any?(Map.keys(node), &(not is_binary(&1) or &1 == "")) ->
        {:error, "matcher keys must be non-empty strings"}

      true ->
        Enum.reduce_while(node, {:ok, count}, fn {_key, child}, {:ok, current_count} ->
          case validate_node(child, depth + 1, current_count + 1) do
            {:ok, next_count} -> {:cont, {:ok, next_count}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp validate_node(_node, _depth, _count),
    do: {:error, "matcher fields must contain an operator map"}

  defp validate_leaf(node, [operator], count) when map_size(node) == 1 do
    case {operator, Map.fetch!(node, operator)} do
      {"prefix", value} when is_binary(value) ->
        {:ok, count + 1}

      {"contains", value} when is_binary(value) ->
        {:ok, count + 1}

      {"in", values} when is_list(values) and length(values) <= @max_entries ->
        if Enum.all?(values, &json_scalar?/1),
          do: {:ok, count + 1},
          else: {:error, "in values must be JSON scalars"}

      {"eq", value} ->
        if json_value?(value),
          do: {:ok, count + 1},
          else: {:error, "eq value must be JSON-compatible"}

      _other ->
        {:error, "matcher operator has an invalid value"}
    end
  end

  defp validate_leaf(_node, _operators, _count),
    do: {:error, "matcher leaves must contain exactly one operator"}

  defp match_map(pattern, value) do
    Enum.reduce_while(pattern, :match, fn {key, child}, :match ->
      case Map.fetch(value, key) do
        {:ok, candidate} ->
          case match_node(child, candidate) do
            :match -> {:cont, :match}
            :no_match -> {:halt, :no_match}
            {:error, _reason} = error -> {:halt, error}
          end

        :error ->
          {:halt, :no_match}
      end
    end)
  end

  defp match_node(%{"eq" => expected} = leaf, candidate) when map_size(leaf) == 1,
    do: if(candidate == expected, do: :match, else: :no_match)

  defp match_node(%{"prefix" => prefix} = leaf, candidate)
       when map_size(leaf) == 1 and is_binary(prefix) do
    if is_binary(candidate),
      do: if(String.starts_with?(candidate, prefix), do: :match, else: :no_match),
      else: {:error, :matcher_type_mismatch}
  end

  defp match_node(%{"contains" => part} = leaf, candidate)
       when map_size(leaf) == 1 and is_binary(part) do
    if is_binary(candidate),
      do: if(String.contains?(candidate, part), do: :match, else: :no_match),
      else: {:error, :matcher_type_mismatch}
  end

  defp match_node(%{"in" => allowed} = leaf, candidate)
       when map_size(leaf) == 1 and is_list(allowed) do
    if json_scalar?(candidate),
      do: if(candidate in allowed, do: :match, else: :no_match),
      else: {:error, :matcher_type_mismatch}
  end

  defp match_node(nested, candidate) when is_map(nested) do
    if is_map(candidate), do: match_map(nested, candidate), else: {:error, :matcher_type_mismatch}
  end

  defp match_node(_matcher, _candidate), do: {:error, :invalid_matcher}

  defp json_value?(value) do
    case Jason.encode(value) do
      {:ok, _encoded} -> true
      {:error, _error} -> false
    end
  end

  defp json_scalar?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)
end
