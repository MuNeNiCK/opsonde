defmodule Opsonde.Cases.ConditionRecovery do
  @moduledoc false

  alias Opsonde.{Cases, Signals, Targets}

  @max_evidence 256

  def assess_current(incident) do
    with {:ok, baseline} <- baseline_for_case(incident) do
      assess(incident, baseline)
    end
  end

  def baseline_for_case(incident) do
    inherited = incident.recovery_baseline_at || incident.inserted_at

    with {:ok, operations} <- Cases.operations_for_case(incident.id, authorize?: false),
         true <- length(operations) < 100 || {:error, "Operation history exceeds recovery bound"} do
      operations
      |> Enum.filter(&(&1.request_kind == :effect))
      |> Enum.sort_by(& &1.accepted_at, {:desc, DateTime})
      |> case do
        [] ->
          {:ok, inherited}

        [%{status: :applied, accepted_at: %DateTime{} = accepted_at} | _] ->
          if DateTime.compare(accepted_at, inherited) == :gt,
            do: {:ok, accepted_at},
            else: {:ok, inherited}

        _other ->
          {:error, "Latest Target effect is not applied"}
      end
    end
  end

  # The caller holds the Case admission lock and a Case row lock before using
  # this result for a terminal transition. Remote observations happen earlier;
  # this module only evaluates persisted facts against current Conditions.
  def assess(incident, after_at) do
    with {:ok, memberships} <- Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- memberships != [] || {:error, "Signal Case has no active Conditions"},
         {:ok, evidence} <-
           Cases.condition_assessment_evidence(incident.id, after_at, authorize?: false),
         true <-
           length(evidence) <= @max_evidence || {:error, "Condition evidence window is full"} do
      Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, collected} ->
        case Signals.get_condition(membership.condition_id, authorize?: false) do
          {:ok, condition} ->
            {:cont, {:ok, [assess_condition(condition, evidence, after_at) | collected]}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, assessments} -> {:ok, Enum.reverse(assessments)}
        error -> error
      end
    end
  end

  def all_healthy?(assessments) when is_list(assessments) and assessments != [] do
    Enum.all?(assessments, &(&1.status == :healthy))
  end

  def all_healthy?(_assessments), do: false

  defp assess_condition(condition, evidence, after_at) do
    cond do
      condition.state != :recovered ->
        result(condition, :firing)

      DateTime.compare(condition.current_occurred_at, after_at) == :lt ->
        result(condition, :stale_source)

      is_nil(condition.target_id) ->
        result(condition, :unmapped_target)

      true ->
        case Targets.get_target(condition.target_id, authorize?: false) do
          {:ok, %{active: true, revision: target_revision}} ->
            matching =
              Enum.find(evidence, fn item ->
                DateTime.compare(item.observed_at, condition.current_occurred_at) != :lt and
                  evidence_proves?(item, condition, target_revision)
              end)

            if matching,
              do: result(condition, :healthy, matching.id),
              else: result(condition, :missing_subject_proof)

          _other ->
            result(condition, :target_changed)
        end
    end
  end

  defp result(condition, status, evidence_id \\ nil) do
    %{
      condition_id: condition.id,
      revision: condition.revision,
      status: status,
      evidence_id: evidence_id
    }
  end

  defp evidence_proves?(
         %{kind: "observation", content: content} = evidence,
         condition,
         target_revision
       ) do
    with true <- content["status"] == "applied" and content["category"] == "target_observed",
         true <- content["target_id"] == condition.target_id,
         {:ok, operation} <- Cases.get_operation(evidence.source_ref, authorize?: false),
         true <- operation.request_kind == :observation and operation.status == :applied,
         true <- operation.target_id == condition.target_id,
         true <- operation.target_revision == target_revision,
         true <- operation.case_id == evidence.case_id,
         true <- operation.id == evidence.source_ref,
         true <- operation.capability == content["capability"],
         true <- operation.operation == content["operation"],
         true <- operation.selectors == content["selectors"] do
      proves?(condition, operation, content["facts"])
    else
      _other -> false
    end
  end

  defp evidence_proves?(
         %{kind: "target_verification", content: content} = evidence,
         condition,
         target_revision
       ) do
    with true <- content["status"] == "verified" and content["target_id"] == condition.target_id,
         {:ok, operation} <- Cases.get_operation(content["operation_id"], authorize?: false),
         true <- operation.request_kind == :effect and operation.status == :applied,
         true <- operation.target_id == condition.target_id,
         true <- operation.target_revision == target_revision,
         true <- operation.case_id == evidence.case_id,
         {:ok, attempt} <-
           Cases.verification_attempt_by_operation(operation.id, authorize?: false),
         true <- attempt.status == :verified and attempt.target_id == condition.target_id,
         true <- attempt.target_revision == target_revision,
         true <- attempt.observed_at == evidence.observed_at do
      proves?(condition, attempt, content["facts"])
    else
      _other -> false
    end
  end

  defp evidence_proves?(_evidence, _condition, _target_revision), do: false

  defp proves?(%{subject_ref: %{"kind" => "service", "name" => name}} = condition, source, facts)
       when is_binary(name) and is_map(facts) do
    condition.predicate in ["ServiceUnavailable", "LinuxServiceUnavailable"] and
      source.capability in ["observe.service", "effect.service"] and
      source.operation in ["linux.service.inspect", "linux.service.restart"] and
      source.selectors == %{"unit" => name} and
      facts["unit"] == name and facts["active_state"] == "active"
  end

  defp proves?(
         %{subject_ref: %{"kind" => "deployment", "name" => name, "namespace" => namespace}} =
           condition,
         source,
         facts
       )
       when is_binary(name) and is_binary(namespace) and is_map(facts) do
    condition.predicate in ["DeploymentUnavailable", "KubeDeploymentReplicasMismatch"] and
      source.capability == "observe.workload" and
      source.operation == "kubernetes.deployment.inspect" and
      source.selectors == %{"name" => name} and
      facts["name"] == name and facts["namespace"] == namespace and
      is_integer(facts["replicas"]) and facts["replicas"] >= 0 and
      is_integer(facts["ready_replicas"]) and
      is_integer(facts["available_replicas"]) and
      facts["ready_replicas"] >= facts["replicas"] and
      facts["available_replicas"] >= facts["replicas"] and
      is_integer(facts["generation"]) and
      is_integer(facts["observed_generation"]) and
      facts["observed_generation"] >= facts["generation"]
  end

  defp proves?(%{subject_ref: subject, predicate: "LinuxGuestUnavailable"}, source, facts)
       when map_size(subject) == 0 and is_map(facts) do
    source.capability == "observe.identity" and
      source.operation == "linux.identity.inspect" and
      source.selectors == %{} and
      is_binary(facts["machine_id"]) and byte_size(facts["machine_id"]) > 0 and
      is_binary(facts["kernel"]) and byte_size(facts["kernel"]) > 0
  end

  defp proves?(_condition, _source, _facts), do: false
end
