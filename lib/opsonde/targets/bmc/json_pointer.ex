defmodule Opsonde.Targets.BMC.JSONPointer do
  @moduledoc false

  def append(prefix, segment) when is_binary(prefix) and is_binary(segment) do
    prefix <> "/" <> (segment |> String.replace("~", "~0") |> String.replace("/", "~1"))
  end

  def segments(pointer) when is_binary(pointer) and byte_size(pointer) in 2..160 do
    case String.split(pointer, "/", trim: false) do
      ["" | encoded] when length(encoded) in 1..8 ->
        if Enum.all?(encoded, &valid_segment?/1) do
          {:ok,
           Enum.map(encoded, fn segment ->
             segment |> String.replace("~1", "/") |> String.replace("~0", "~")
           end)}
        else
          :error
        end

      _ ->
        :error
    end
  end

  def segments(_pointer), do: :error

  defp valid_segment?(segment) do
    segment != "" and
      segment
      |> String.replace("~0", "")
      |> String.replace("~1", "")
      |> then(&(not String.contains?(&1, "~")))
  end
end
