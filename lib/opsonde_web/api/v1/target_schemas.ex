defmodule OpsondeWeb.API.V1.TargetSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias OpsondeWeb.API.Schemas

  def components do
    %{
      "ManagementBoundary" => management_boundary(),
      "ManagementBoundaryResponse" => Schemas.data(ref("ManagementBoundary")),
      "ManagementBoundaryPage" => Schemas.page(ref("ManagementBoundary")),
      "CreateManagementBoundaryRequest" => create_management_boundary_request(),
      "UpdateManagementBoundaryRequest" => update_management_boundary_request(),
      "DeactivateManagementBoundaryRequest" => deactivate_request(:management_boundary),
      "Target" => target(),
      "TargetResponse" => Schemas.data(ref("Target")),
      "TargetPage" => Schemas.page(ref("Target")),
      "CreateTargetRequest" => create_target_request(),
      "UpdateTargetRequest" => update_target_request(),
      "DeactivateTargetRequest" => deactivate_request(:target),
      "ExternalIdentity" => external_identity(),
      "ExternalIdentityResponse" => Schemas.data(ref("ExternalIdentity")),
      "ExternalIdentityPage" => Schemas.page(ref("ExternalIdentity")),
      "CreateExternalIdentityRequest" => create_external_identity_request(),
      "UpdateExternalIdentityRequest" => update_external_identity_request(),
      "DeactivateExternalIdentityRequest" => deactivate_request(:external_identity),
      "AccessMethod" => access_method(),
      "AccessMethodResponse" => Schemas.data(ref("AccessMethod")),
      "AccessMethodPage" => Schemas.page(ref("AccessMethod")),
      "CreateAccessMethodRequest" => create_access_method_request(),
      "UpdateAccessMethodRequest" => update_access_method_request(),
      "DeactivateAccessMethodRequest" => deactivate_request(:access_method),
      "TargetRelationship" => relationship(),
      "TargetRelationshipResponse" => Schemas.data(ref("TargetRelationship")),
      "TargetRelationshipPage" => Schemas.page(ref("TargetRelationship")),
      "CreateTargetRelationshipRequest" => create_relationship_request(),
      "UpdateTargetRelationshipRequest" => update_relationship_request(),
      "DeactivateTargetRelationshipRequest" => deactivate_request(:relationship),
      "TargetPolicy" => policy(),
      "TargetPolicyResponse" => Schemas.data(ref("TargetPolicy")),
      "TargetPolicyPage" => Schemas.page(ref("TargetPolicy")),
      "CreateTargetPolicyRequest" => create_policy_request(),
      "UpdateTargetPolicyRequest" => update_policy_request(),
      "DeactivateTargetPolicyRequest" => deactivate_request(:target_policy)
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp management_boundary do
    resource(
      %{
        name: string(1, 120),
        kind: string(1, 80),
        facts: map(),
        active: %Schema{type: :boolean}
      },
      [:name, :kind, :facts, :active]
    )
  end

  defp create_management_boundary_request do
    wrapped(:management_boundary, %{name: string(1, 120), kind: string(1, 80), facts: map()}, [
      :name,
      :kind
    ])
  end

  defp update_management_boundary_request do
    update_request(:management_boundary, %{
      name: string(1, 120),
      kind: string(1, 80),
      facts: map()
    })
  end

  defp target do
    resource(
      %{
        name: string(1, 120),
        kind: string(1, 80),
        platform: string(1, 120),
        facts: map(),
        management_boundary_id: nullable_uuid(),
        active: %Schema{type: :boolean}
      },
      [:name, :kind, :platform, :facts, :management_boundary_id, :active]
    )
  end

  defp create_target_request do
    wrapped(
      :target,
      %{
        name: string(1, 120),
        kind: string(1, 80),
        platform: string(1, 120),
        facts: map(),
        management_boundary_id: nullable_uuid()
      },
      [:name, :kind, :platform]
    )
  end

  defp update_target_request do
    update_request(:target, %{
      name: string(1, 120),
      kind: string(1, 80),
      platform: string(1, 120),
      facts: map(),
      management_boundary_id: nullable_uuid()
    })
  end

  defp external_identity do
    resource(
      %{
        target_id: Schemas.uuid(),
        source: string(1, 120),
        kind: string(1, 80),
        value: string(1, 500),
        active: %Schema{type: :boolean}
      },
      [:target_id, :source, :kind, :value, :active]
    )
  end

  defp create_external_identity_request do
    wrapped(
      :external_identity,
      %{
        target_id: Schemas.uuid(),
        source: string(1, 120),
        kind: string(1, 80),
        value: string(1, 500)
      },
      [:target_id, :source, :kind, :value]
    )
  end

  defp update_external_identity_request do
    update_request(:external_identity, %{
      target_id: Schemas.uuid(),
      source: string(1, 120),
      kind: string(1, 80),
      value: string(1, 500)
    })
  end

  defp access_method do
    resource(
      %{
        target_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        name: string(1, 120),
        platform: string(1, 120),
        method: string(1, 120),
        endpoint: string(1, 1_024),
        provider_revision: positive_integer(),
        priority: priority(),
        capabilities: string_array(100, 120),
        active: %Schema{type: :boolean}
      },
      [
        :target_id,
        :provider_id,
        :name,
        :platform,
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities,
        :active
      ]
    )
  end

  defp create_access_method_request do
    wrapped(
      :access_method,
      %{
        target_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        name: string(1, 120),
        platform: string(1, 120),
        method: string(1, 120),
        endpoint: string(1, 1_024),
        provider_revision: positive_integer(),
        priority: priority(),
        capabilities: string_array(100, 120)
      },
      [:target_id, :provider_id, :name, :platform, :method, :endpoint, :provider_revision]
    )
  end

  defp update_access_method_request do
    update_request(:access_method, %{
      target_id: Schemas.uuid(),
      provider_id: Schemas.uuid(),
      name: string(1, 120),
      platform: string(1, 120),
      method: string(1, 120),
      endpoint: string(1, 1_024),
      provider_revision: positive_integer(),
      priority: priority(),
      capabilities: string_array(100, 120)
    })
  end

  defp relationship do
    resource(
      %{
        source_target_id: Schemas.uuid(),
        destination_target_id: Schemas.uuid(),
        kind: string(1, 120),
        facts: map(),
        valid_until: nullable_timestamp(),
        active: %Schema{type: :boolean}
      },
      [:source_target_id, :destination_target_id, :kind, :facts, :valid_until, :active]
    )
  end

  defp create_relationship_request do
    wrapped(
      :relationship,
      %{
        source_target_id: Schemas.uuid(),
        destination_target_id: Schemas.uuid(),
        kind: string(1, 120),
        facts: map(),
        valid_until: nullable_timestamp()
      },
      [:source_target_id, :destination_target_id, :kind]
    )
  end

  defp update_relationship_request do
    update_request(:relationship, %{
      source_target_id: Schemas.uuid(),
      destination_target_id: Schemas.uuid(),
      kind: string(1, 120),
      facts: map(),
      valid_until: nullable_timestamp()
    })
  end

  defp policy do
    resource(
      %{
        target_id: Schemas.uuid(),
        name: string(1, 120),
        request_kinds: request_kinds(),
        capabilities: string_array(100, 120),
        operations: string_array(100, 120),
        selector_match: map(),
        parameter_match: map(),
        reason: string(1, 500),
        enabled: %Schema{type: :boolean}
      },
      [
        :target_id,
        :name,
        :request_kinds,
        :capabilities,
        :operations,
        :selector_match,
        :parameter_match,
        :reason,
        :enabled
      ]
    )
  end

  defp create_policy_request do
    wrapped(
      :target_policy,
      %{
        target_id: Schemas.uuid(),
        name: string(1, 120),
        request_kinds: request_kinds(),
        capabilities: string_array(100, 120),
        operations: string_array(100, 120),
        selector_match: map(),
        parameter_match: map(),
        reason: string(1, 500)
      },
      [:target_id, :name, :request_kinds, :reason]
    )
  end

  defp update_policy_request do
    update_request(:target_policy, %{
      name: string(1, 120),
      request_kinds: request_kinds(),
      capabilities: string_array(100, 120),
      operations: string_array(100, 120),
      selector_match: map(),
      parameter_match: map(),
      reason: string(1, 500)
    })
  end

  defp resource(properties, required) do
    object(
      Map.merge(
        %{
          id: Schemas.uuid(),
          revision: positive_integer(),
          inserted_at: Schemas.timestamp(),
          updated_at: Schemas.timestamp()
        },
        properties
      ),
      [:id, :revision, :inserted_at, :updated_at | required],
      false
    )
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp update_request(name, properties) do
    wrapped(
      name,
      Map.put(properties, :expected_revision, positive_integer()),
      [:expected_revision]
    )
    |> put_in([Access.key(:properties), name, Access.key(:minProperties)], 2)
  end

  defp deactivate_request(name) do
    wrapped(name, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp request_kinds do
    %Schema{
      type: :array,
      minItems: 1,
      maxItems: 2,
      items: %Schema{type: :string, enum: ~w(observation effect)}
    }
  end

  defp string_array(max_items, max_length) do
    %Schema{
      type: :array,
      maxItems: max_items,
      items: string(1, max_length)
    }
  end

  defp string(min_length, max_length) do
    %Schema{type: :string, minLength: min_length, maxLength: max_length}
  end

  defp priority, do: %Schema{type: :integer, minimum: 0, maximum: 10_000}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
