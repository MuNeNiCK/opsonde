defmodule OpsondeWeb.API.V1.ProviderSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias OpsondeWeb.API.Schemas

  def components do
    %{
      "Provider" => provider(),
      "ProviderResponse" => Schemas.data(ref("Provider")),
      "ProviderPage" => Schemas.page(ref("Provider")),
      "CreateProviderRequest" => create_provider_request(),
      "UpdateProviderRequest" => update_provider_request(),
      "ProviderRevisionRequest" => provider_revision_request(),
      "CheckProviderRequest" => check_provider_request(),
      "ConfigureAIUsageRequest" => configure_ai_usage_request(),
      "TargetCapabilitiesResponse" => Schemas.data(target_capabilities()),
      "AIUsageRoleAssignment" => assignment(),
      "AIUsageRoleAssignmentResponse" => Schemas.data(ref("AIUsageRoleAssignment")),
      "AIUsageRoleAssignmentPage" => Schemas.page(ref("AIUsageRoleAssignment")),
      "CreateAIUsageRoleAssignmentRequest" => create_assignment_request(),
      "UpdateAIUsageRoleAssignmentRequest" => update_assignment_request()
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp provider do
    object(
      %{
        id: Schemas.uuid(),
        name: %Schema{type: :string, minLength: 1, maxLength: 120},
        kind: provider_kind(),
        adapter_type: %Schema{type: :string, minLength: 1, maxLength: 120},
        configuration: map(),
        revision: positive_integer(),
        enabled: %Schema{type: :boolean},
        check: provider_check(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [
        :id,
        :name,
        :kind,
        :adapter_type,
        :configuration,
        :revision,
        :enabled,
        :check,
        :inserted_at,
        :updated_at
      ],
      false
    )
  end

  defp provider_check do
    object(
      %{
        status: nullable_enum(~w(passed failed)),
        category:
          nullable_enum(
            ~w(invalid_configuration authentication unreachable capability provider_failure)
          ),
        message: %Schema{type: :string, nullable: true},
        checked_revision: %Schema{type: :integer, minimum: 1, nullable: true},
        checked_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      [:status, :category, :message, :checked_revision, :checked_at],
      false
    )
  end

  defp create_provider_request do
    object(
      %{
        provider:
          object(
            %{
              name: %Schema{type: :string, minLength: 1, maxLength: 120},
              kind: provider_kind(),
              adapter_type: %Schema{type: :string, minLength: 1, maxLength: 120},
              configuration: map(),
              credentials: %Schema{type: :object, additionalProperties: true, writeOnly: true},
              usage_scope: %Schema{type: :string, enum: ~w(all resolver reviewer)},
              usage_priority: priority()
            },
            [:name, :kind, :adapter_type, :configuration, :credentials]
          )
      },
      [:provider]
    )
  end

  defp update_provider_request do
    object(
      %{
        provider:
          object(
            %{
              expected_revision: positive_integer(),
              name: %Schema{type: :string, minLength: 1, maxLength: 120},
              configuration: map(),
              credentials: %Schema{type: :object, additionalProperties: true, writeOnly: true}
            },
            [:expected_revision]
          )
      },
      [:provider]
    )
  end

  defp configure_ai_usage_request do
    object(
      %{
        usage:
          object(
            %{
              scope: %Schema{type: :string, enum: ~w(all resolver reviewer)},
              priority: priority(),
              expected_resolver_revision: %Schema{type: :integer, minimum: 1, nullable: true},
              expected_reviewer_revision: %Schema{type: :integer, minimum: 1, nullable: true}
            },
            [
              :scope,
              :priority,
              :expected_resolver_revision,
              :expected_reviewer_revision
            ]
          )
      },
      [:usage]
    )
  end

  defp provider_revision_request do
    object(
      %{
        provider: object(%{expected_revision: positive_integer()}, [:expected_revision])
      },
      [:provider]
    )
  end

  defp check_provider_request do
    object(
      %{
        provider:
          object(
            %{expected_revision: positive_integer(), check_input: map()},
            [:expected_revision]
          )
      },
      [:provider]
    )
  end

  defp target_capabilities do
    object(
      %{
        observations: %Schema{type: :array, items: capability()},
        effects: %Schema{type: :array, items: capability()}
      },
      [:observations, :effects],
      false
    )
  end

  defp capability do
    object(
      %{
        capability: %Schema{type: :string},
        operation: %Schema{type: :string},
        description: %Schema{type: :string},
        input_schema: map()
      },
      [:capability, :operation, :description, :input_schema],
      false
    )
  end

  defp assignment do
    object(
      %{
        id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        role: %Schema{type: :string, enum: ~w(resolver reviewer)},
        priority: priority(),
        enabled: %Schema{type: :boolean},
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [:id, :provider_id, :role, :priority, :enabled, :revision, :inserted_at, :updated_at],
      false
    )
  end

  defp create_assignment_request do
    object(
      %{
        assignment:
          object(
            %{
              provider_id: Schemas.uuid(),
              role: %Schema{type: :string, enum: ~w(resolver reviewer)},
              priority: priority()
            },
            [:provider_id, :role, :priority]
          )
      },
      [:assignment]
    )
  end

  defp update_assignment_request do
    object(
      %{
        assignment:
          object(
            %{
              expected_revision: positive_integer(),
              priority: priority(),
              enabled: %Schema{type: :boolean}
            },
            [:expected_revision]
          )
      },
      [:assignment]
    )
  end

  defp provider_kind,
    do: %Schema{type: :string, enum: ~w(ai signal target inventory notification)}

  defp priority, do: %Schema{type: :integer, minimum: 0, maximum: 10_000}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp nullable_enum(values), do: %Schema{type: :string, enum: values, nullable: true}
  defp map, do: %Schema{type: :object, additionalProperties: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
