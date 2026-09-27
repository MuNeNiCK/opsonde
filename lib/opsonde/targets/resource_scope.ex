defmodule Opsonde.Targets.ResourceScope do
  @moduledoc false

  @service_capabilities ["effect.service", "observe.service"]

  def key(%{platform: "linux"}, capability, selectors)
      when capability in @service_capabilities and is_map(selectors) do
    case selectors do
      %{"unit" => unit} when map_size(selectors) == 1 and is_binary(unit) -> service(unit)
      %{"service" => unit} when map_size(selectors) == 1 and is_binary(unit) -> service(unit)
      _other -> "target"
    end
  end

  def key(_method, _capability, _selectors), do: "target"

  defp service(unit) do
    if unit != "" and String.trim(unit) == unit do
      name = if String.contains?(unit, "."), do: unit, else: unit <> ".service"
      "service:" <> name
    else
      "target"
    end
  end
end
