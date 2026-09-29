defmodule OpsondeWeb.API.V1.ProviderJSON do
  @moduledoc false

  alias Opsonde.Providers
  alias Opsonde.Providers.Registry
  alias Opsonde.Providers.Target.AccessMethodProfile

  def data(provider) do
    record = %{
      id: provider.id,
      name: provider.name,
      kind: provider.kind,
      adapter_type: provider.adapter_type,
      configuration: provider.configuration,
      revision: provider.revision,
      enabled: provider.enabled,
      check: %{
        status: provider.check_status,
        category: provider.check_category,
        message: provider.check_message,
        checked_revision: provider.checked_revision,
        checked_at: provider.checked_at
      },
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }

    case access_method_profile(provider) do
      nil -> record
      profile -> Map.put(record, :access_method_profile, profile)
    end
  end

  defp access_method_profile(%{kind: :target, adapter_type: type}) do
    with {:ok, adapter} <- Registry.fetch(type, Providers.Target),
         %AccessMethodProfile{} = profile <- adapter.access_method_profile() do
      %{
        platform: profile.platform,
        method: profile.method,
        target_type_id: profile.target_type_id,
        target_kind: profile.target_kind
      }
    else
      _unrestricted -> nil
    end
  end

  defp access_method_profile(_provider), do: nil

  def capabilities(capabilities) do
    %{
      observations: Enum.map(capabilities.observations, &operation/1),
      effects: Enum.map(capabilities.effects, &operation/1)
    }
  end

  defp operation(operation) do
    %{
      capability: operation.capability,
      operation: operation.operation,
      description: operation.description,
      input_schema: operation.input_schema
    }
  end
end
