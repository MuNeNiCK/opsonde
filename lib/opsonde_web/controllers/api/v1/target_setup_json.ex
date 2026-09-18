defmodule OpsondeWeb.API.V1.TargetSetupJSON do
  @moduledoc false

  def boundary(boundary) do
    %{
      id: boundary.id,
      name: boundary.name,
      kind: boundary.kind,
      facts: boundary.facts,
      active: boundary.active,
      revision: boundary.revision,
      inserted_at: boundary.inserted_at,
      updated_at: boundary.updated_at
    }
  end

  def target(target) do
    %{
      id: target.id,
      name: target.name,
      kind: target.kind,
      platform: target.platform,
      facts: target.facts,
      management_boundary_id: target.management_boundary_id,
      active: target.active,
      revision: target.revision,
      inserted_at: target.inserted_at,
      updated_at: target.updated_at
    }
  end

  def identity(identity) do
    %{
      id: identity.id,
      target_id: identity.target_id,
      source: identity.source,
      kind: identity.kind,
      value: identity.value,
      active: identity.active,
      revision: identity.revision,
      inserted_at: identity.inserted_at,
      updated_at: identity.updated_at
    }
  end

  def access_method(method) do
    %{
      id: method.id,
      target_id: method.target_id,
      provider_id: method.provider_id,
      name: method.name,
      platform: method.platform,
      method: method.method,
      endpoint: method.endpoint,
      provider_revision: method.provider_revision,
      priority: method.priority,
      capabilities: method.capabilities,
      active: method.active,
      revision: method.revision,
      inserted_at: method.inserted_at,
      updated_at: method.updated_at
    }
  end

  def relationship(relationship) do
    %{
      id: relationship.id,
      source_target_id: relationship.source_target_id,
      destination_target_id: relationship.destination_target_id,
      kind: relationship.kind,
      facts: relationship.facts,
      valid_until: relationship.valid_until,
      active: relationship.active,
      revision: relationship.revision,
      inserted_at: relationship.inserted_at,
      updated_at: relationship.updated_at
    }
  end

  def policy(policy) do
    %{
      id: policy.id,
      target_id: policy.target_id,
      name: policy.name,
      request_kinds: policy.request_kinds,
      capabilities: policy.capabilities,
      operations: policy.operations,
      selector_match: policy.selector_match,
      parameter_match: policy.parameter_match,
      reason: policy.reason,
      enabled: policy.enabled,
      revision: policy.revision,
      inserted_at: policy.inserted_at,
      updated_at: policy.updated_at
    }
  end
end
