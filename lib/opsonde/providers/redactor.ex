defmodule Opsonde.Providers.Redactor do
  @moduledoc false

  @redacted "[REDACTED]"

  def message(message, credentials) when is_binary(message) and is_map(credentials) do
    credentials
    |> secret_strings()
    |> Enum.reduce(message, &String.replace(&2, &1, @redacted))
  end

  def value(%module{} = value, credentials) do
    redacted = value |> Map.from_struct() |> value(credentials)
    struct(module, redacted)
  end

  def value(value, credentials) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, value(item, credentials)} end)
  end

  def value(value, credentials) when is_list(value),
    do: Enum.map(value, &value(&1, credentials))

  def value(value, credentials) when is_tuple(value) do
    value |> Tuple.to_list() |> value(credentials) |> List.to_tuple()
  end

  def value(value, credentials) when is_binary(value), do: message(value, credentials)
  def value(value, _credentials), do: value

  defp secret_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&secret_strings/1)

  defp secret_strings(value) when is_list(value), do: Enum.flat_map(value, &secret_strings/1)
  defp secret_strings(value) when is_binary(value) and value != "", do: [value]
  defp secret_strings(value) when is_integer(value) or is_float(value), do: [to_string(value)]
  defp secret_strings(_value), do: []
end
