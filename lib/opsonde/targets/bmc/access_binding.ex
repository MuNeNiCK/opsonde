defmodule Opsonde.Targets.BMC.AccessBinding do
  @moduledoc false

  alias Opsonde.Targets

  @bmc_adapters %{
    "bmc-redfish" => "redfish",
    "bmc-ipmi" => "ipmi"
  }
  @capabilities ~w(observe.power effect.power observe.bmc_api effect.bmc_api)

  def validate(changeset, provider) do
    case Map.fetch(@bmc_adapters, provider.adapter_type) do
      {:ok, method} -> validate_bmc(changeset, provider, method)
      :error -> :ok
    end
  end

  defp validate_bmc(changeset, provider, method) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)
    target_id = Ash.Changeset.get_attribute(changeset, :target_id)
    capabilities = Ash.Changeset.get_attribute(changeset, :capabilities)

    with true <- Ash.Changeset.get_attribute(changeset, :method) == method,
         true <- Ash.Changeset.get_attribute(changeset, :platform) == "bare_metal",
         true <- endpoint == provider.configuration["endpoint"],
         true <-
           is_list(capabilities) and "observe.power" in capabilities and
             Enum.uniq(capabilities) == capabilities and
             Enum.all?(capabilities, &(&1 in @capabilities)),
         {:ok, %{kind: "physical_host", active: true}} <-
           Targets.get_target(target_id, authorize?: false) do
      :ok
    else
      _ ->
        {:error,
         field: :endpoint,
         message: "BMC Access Method must match its checked Provider and a physical host"}
    end
  end
end
