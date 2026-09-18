defmodule Opsonde.Providers.Redactor do
  @moduledoc false

  @redacted "[REDACTED]"

  def message(message, credentials) when is_binary(message) and is_map(credentials) do
    credentials
    |> secret_strings()
    |> Enum.reduce(message, &String.replace(&2, &1, @redacted))
  end

  defp secret_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&secret_strings/1)

  defp secret_strings(value) when is_list(value), do: Enum.flat_map(value, &secret_strings/1)
  defp secret_strings(value) when is_binary(value) and value != "", do: [value]
  defp secret_strings(value) when is_integer(value) or is_float(value), do: [to_string(value)]
  defp secret_strings(_value), do: []
end
