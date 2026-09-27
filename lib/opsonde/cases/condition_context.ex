defmodule Opsonde.Cases.ConditionContext do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Cases.ResolverProjection
  alias Opsonde.Providers.AI
  alias Opsonde.Targets.ResourceScope

  # The completed Resolver Turn owns the Conditions considered when it made a
  # decision. An authorization based on that Turn must still see exactly those
  # Conditions. Callers taking a decision hold the Case admission lock.
  def current?(%{trigger_kind: :signal} = incident, source_turn_id) do
    with {:ok, turn} <- Cases.get_turn(source_turn_id, authorize?: false),
         {:ok, revisions} <- ResolverProjection.current_condition_revisions(incident) do
      {:ok,
       turn.case_id == incident.id and is_list(turn.result["condition_revisions"]) and
         revisions == turn.result["condition_revisions"]}
    end
  end

  def current?(_incident, _source_turn_id), do: {:ok, true}

  def affected_current?(
        incident,
        request_kind,
        claims,
        evidence_ids,
        action,
        exclude_operation_id \\ nil
      ) do
    with {:ok, {conditions, _recovery_ids}} <-
           ResolverProjection.current_condition_context(incident, exclude_operation_id) do
      {:ok,
       AI.valid_affected_conditions?(request_kind, claims, conditions, evidence_ids) and
         current_effect_scope?(request_kind, claims, conditions, evidence_ids, action)}
    end
  end

  defp current_effect_scope?(:effect, claims, conditions, evidence_ids, action) do
    current = Map.new(conditions, &{&1.id, &1})

    Enum.all?(claims, fn claim ->
      condition = Map.fetch!(current, claim["condition_id"])

      condition.state != :recovered or
        Enum.any?(evidence_ids, fn id ->
          id in condition.recovery_evidence_ids and same_resource_scope?(id, action)
        end)
    end)
  end

  defp current_effect_scope?(_request_kind, _claims, _conditions, _evidence_ids, _action),
    do: true

  defp same_resource_scope?(evidence_id, action) do
    with {:ok, evidence} <- Cases.get_evidence(evidence_id, authorize?: false),
         true <- evidence.kind == "observation",
         {:ok, observation} <- Cases.get_operation(evidence.source_ref, authorize?: false),
         true <- observation.request_kind == :observation and observation.status == :applied,
         true <- observation.target_id == action_value(action, :target_id),
         {:ok, action_method} <-
           Opsonde.Targets.get_access_method(action_value(action, :access_method_id),
             authorize?: false
           ),
         {:ok, observation_method} <-
           Opsonde.Targets.get_access_method(observation.access_method_id, authorize?: false) do
      ResourceScope.key(
        action_method,
        action_value(action, :capability),
        action_value(action, :operation),
        action_value(action, :selectors)
      ) ==
        ResourceScope.key(
          observation_method,
          observation.capability,
          observation.operation,
          observation.selectors
        )
    else
      _other -> false
    end
  end

  defp action_value(action, key), do: Map.get(action, key) || Map.get(action, Atom.to_string(key))
end
