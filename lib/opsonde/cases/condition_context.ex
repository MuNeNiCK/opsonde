defmodule Opsonde.Cases.ConditionContext do
  @moduledoc false

  alias Opsonde.{Cases, Targets}
  alias Opsonde.Cases.ConditionRecovery
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
         current_effect_scope?(incident, request_kind, claims, conditions, evidence_ids, action)}
    end
  end

  defp current_effect_scope?(incident, :effect, claims, conditions, evidence_ids, action) do
    current = Map.new(conditions, &{&1.id, &1})
    target_id = action_value(action, :target_id)

    Enum.all?(claims, fn claim ->
      condition = Map.fetch!(current, claim["condition_id"])

      if condition.target_id == target_id do
        map_size(claim) == 2 and
          (condition.state != :recovered or
             Enum.any?(evidence_ids, fn id ->
               id in condition.recovery_evidence_ids and
                 same_resource_scope?(id, action, incident.id)
             end))
      else
        related_effect_scope?(incident, condition, claim, evidence_ids, action)
      end
    end)
  end

  defp current_effect_scope?(
         _incident,
         _request_kind,
         _claims,
         _conditions,
         _evidence_ids,
         _action
       ),
       do: true

  defp related_effect_scope?(incident, condition, claim, evidence_ids, action) do
    target_id = action_value(action, :target_id)

    with true <- map_size(claim) == 4 and is_binary(condition.target_id),
         {:ok, relation} <-
           Targets.load_relationship_for_traversal(
             claim["relationship_id"],
             claim["relationship_revision"],
             authorize?: false
           ),
         true <-
           Enum.sort([relation.source_target_id, relation.destination_target_id]) ==
             Enum.sort([condition.target_id, target_id]),
         {:ok, %{active: true, revision: condition_revision}} <-
           Targets.get_target(condition.target_id, authorize?: false),
         true <-
           Enum.any?(evidence_ids, fn id ->
             symptom_observation?(
               id,
               incident,
               condition,
               condition_revision
             )
           end),
         true <-
           Enum.any?(evidence_ids, fn id ->
             effect_target_observation?(id, incident, condition, action)
           end) do
      true
    else
      _unavailable -> false
    end
  end

  defp effect_target_observation?(evidence_id, incident, condition, action) do
    with true <- same_resource_scope?(evidence_id, action, incident.id),
         {:ok, evidence} <- Cases.get_evidence(evidence_id, authorize?: false) do
      DateTime.to_unix(evidence.observed_at, :microsecond) >=
        condition.current_occurred_at_us and
        DateTime.compare(evidence.observed_at, ConditionRecovery.inherited_baseline(incident)) !=
          :lt
    else
      _unavailable -> false
    end
  end

  defp symptom_observation?(evidence_id, incident, condition, target_revision) do
    with {:ok, evidence} <- Cases.get_evidence(evidence_id, authorize?: false),
         true <-
           evidence.case_id == incident.id and evidence.kind == "observation" and
             evidence.source == "operation",
         true <- evidence.content["target_id"] == condition.target_id,
         true <-
           DateTime.to_unix(evidence.observed_at, :microsecond) >=
             condition.current_occurred_at_us,
         true <-
           DateTime.compare(evidence.observed_at, ConditionRecovery.inherited_baseline(incident)) !=
             :lt,
         {:ok, observation} <- Cases.get_operation(evidence.source_ref, authorize?: false),
         true <-
           observation.case_id == incident.id and
             observation.request_kind == :observation and
             observation.target_id == condition.target_id and
             observation.target_revision == target_revision and
             observation.status in [:applied, :failed] and
             evidence.content["status"] == to_string(observation.status),
         true <-
           evidence.content["category"] ==
             if(observation.status == :applied, do: "target_observed", else: "observation_failed"),
         true <-
           condition.state != :recovered or
             (observation.status == :applied and
                evidence_id in condition.recovery_evidence_ids) or
             (observation.status == :failed and
                evidence_id in condition.failed_observation_ids) do
      true
    else
      _unavailable -> false
    end
  end

  defp same_resource_scope?(evidence_id, action, case_id) do
    with {:ok, evidence} <- Cases.get_evidence(evidence_id, authorize?: false),
         true <-
           evidence.case_id == case_id and evidence.kind == "observation" and
             evidence.source == "operation",
         {:ok, observation} <- Cases.get_operation(evidence.source_ref, authorize?: false),
         true <- observation.request_kind == :observation and observation.status == :applied,
         true <- observation.case_id == case_id,
         true <- observation.target_id == action_value(action, :target_id),
         true <- observation.target_revision == action_value(action, :target_revision),
         true <-
           evidence.content["status"] == "applied" and
             evidence.content["category"] == "target_observed",
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
