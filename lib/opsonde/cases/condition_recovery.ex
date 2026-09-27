defmodule Opsonde.Cases.ConditionRecovery do
  @moduledoc false

  alias Opsonde.{Cases, Signals, Targets}

  @max_evidence 256

  # Evidence availability does not decide whether the fault recovered.
  def assess_current(incident) do
    with {:ok, baseline} <- baseline_for_case(incident), do: assess(incident, baseline)
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

        [%{status: :applied, accepted_at: %DateTime{} = at} | _] ->
          {:ok, if(DateTime.compare(at, inherited) == :gt, do: at, else: inherited)}

        _other ->
          {:error, "Latest Target effect is not applied"}
      end
    end
  end

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

  def ready_for_review?(assessments) when is_list(assessments) and assessments != [] do
    Enum.all?(assessments, &(&1.status == :ready_for_review))
  end

  def ready_for_review?(_assessments), do: false

  def current_evidence?(evidence, condition, baseline, target_revision)
      when is_struct(baseline, DateTime) do
    DateTime.compare(evidence.observed_at, baseline) != :lt and
      DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt and
      evidence.content["target_id"] == condition.target_id and
      valid_operation_evidence?(evidence, condition, target_revision)
  end

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
          {:ok, %{active: true, revision: revision}} ->
            case Enum.find(evidence, &current_evidence?(&1, condition, after_at, revision)) do
              nil -> result(condition, :needs_observation)
              item -> result(condition, :ready_for_review, item.id)
            end

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

  defp valid_operation_evidence?(
         %{kind: "observation", content: content} = evidence,
         condition,
         revision
       ) do
    with true <- content["status"] == "applied" and content["category"] == "target_observed",
         true <- content["target_id"] == condition.target_id,
         {:ok, operation} <- Cases.get_operation(evidence.source_ref, authorize?: false),
         true <- operation.request_kind == :observation and operation.status == :applied,
         true <- operation.case_id == evidence.case_id and operation.id == evidence.source_ref,
         true <-
           operation.target_id == condition.target_id and operation.target_revision == revision,
         true <- operation.capability == content["capability"],
         true <- operation.operation == content["operation"],
         true <- operation.selectors == content["selectors"] do
      true
    else
      _other -> false
    end
  end

  defp valid_operation_evidence?(
         %{kind: "target_verification", content: content} = evidence,
         condition,
         revision
       ) do
    with true <- content["status"] == "verified" and content["target_id"] == condition.target_id,
         {:ok, operation} <- Cases.get_operation(content["operation_id"], authorize?: false),
         true <- operation.request_kind == :effect and operation.status == :applied,
         true <-
           operation.case_id == evidence.case_id and operation.target_id == condition.target_id,
         true <- operation.target_revision == revision,
         {:ok, attempt} <-
           Cases.verification_attempt_by_operation(operation.id, authorize?: false),
         true <- attempt.status == :verified and attempt.target_id == condition.target_id,
         true <-
           attempt.target_revision == revision and attempt.observed_at == evidence.observed_at do
      true
    else
      _other -> false
    end
  end

  defp valid_operation_evidence?(_evidence, _condition, _revision), do: false
end
