defmodule Opsonde.Targets.BMC.CurrentAccessMethod do
  @moduledoc false

  alias Opsonde.{Providers, Targets}
  alias Opsonde.Targets.TypeCatalog

  def get(id) do
    with {:ok, %{active: true} = method} <- Targets.get_access_method(id, authorize?: false),
         {:ok, %{active: true} = target} <-
           Targets.get_target(method.target_id, authorize?: false),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             method.provider_id,
             method.provider_revision,
             :target,
             authorize?: false
           ),
         true <- TypeCatalog.allows_method?(target.type_id, provider.adapter_type),
         true <- protocol_matches?(provider.adapter_type, method.method) do
      {:ok, method}
    else
      _ -> {:error, :invalid_bmc_method}
    end
  end

  defp protocol_matches?("bmc-redfish", "redfish"), do: true
  defp protocol_matches?("bmc-ipmi", "ipmi"), do: true
  defp protocol_matches?(_, _), do: false
end
