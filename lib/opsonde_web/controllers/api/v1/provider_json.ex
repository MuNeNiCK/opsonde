defmodule OpsondeWeb.API.V1.ProviderJSON do
  @moduledoc false

  def data(provider) do
    %{
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
  end

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
