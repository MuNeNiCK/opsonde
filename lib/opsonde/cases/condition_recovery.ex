defmodule Opsonde.Cases.ConditionRecovery do
  @moduledoc false

  alias Opsonde.{Cases, Signals, Targets}

  @max_evidence 256
  @max_lineage_depth 32
  @max_citations_per_condition 3

  # Evidence availability does not decide whether the fault recovered.
  def assess_current(incident) do
    with {:ok, memberships} <- Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- memberships != [] || {:error, "Signal Case has no active Conditions"},
         {:ok, effects} <- lineage_effects(incident, MapSet.new(), 0),
         {:ok, evidence} <-
           Cases.condition_assessment_evidence(
             incident.id,
             inherited_baseline(incident),
             authorize?: false
           ),
         true <-
           length(evidence) <= @max_evidence || {:error, "Condition evidence window is full"} do
      Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, collected} ->
        with {:ok, condition} <- Signals.get_condition(membership.condition_id, authorize?: false),
             {:ok, baseline} <- condition_baseline(incident, condition.id, effects) do
          {:cont, {:ok, [assess_condition(condition, evidence, baseline) | collected]}}
        else
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, assessments} -> {:ok, Enum.reverse(assessments)}
        error -> error
      end
    end
  end

  def inherited_baseline(incident), do: incident.recovery_baseline_at || incident.inserted_at

  def baseline_for_case(incident) do
    inherited = inherited_baseline(incident)

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

      is_nil(condition.target_id) ->
        result(condition, :unmapped_target)

      true ->
        case Targets.get_target(condition.target_id, authorize?: false) do
          {:ok, %{active: true, revision: revision}} ->
            citations =
              evidence
              |> Enum.filter(&current_evidence?(&1, condition, after_at, revision))
              |> Enum.uniq_by(&citation_scope/1)
              |> Enum.take(@max_citations_per_condition)
              |> Enum.map(& &1.id)

            case citations do
              [] ->
                if DateTime.compare(condition.current_occurred_at, after_at) == :lt,
                  do: result(condition, :stale_source),
                  else: result(condition, :needs_observation)

              ids ->
                result(condition, :ready_for_review, ids)
            end

          _other ->
            result(condition, :target_changed)
        end
    end
  end

  defp condition_baseline(incident, condition_id, effects) do
    relevant = Enum.filter(effects, fn {_operation, ids} -> condition_id in ids end)

    case Enum.sort_by(
           relevant,
           fn {operation, _ids} ->
             {DateTime.to_unix(operation.accepted_at, :microsecond), operation.id}
           end,
           :desc
         ) do
      [] ->
        {:ok, inherited_baseline(incident)}

      [{%{status: status, completed_at: %DateTime{} = completed_at}, _ids} | _]
      when status in [:applied, :failed, :partial, :unknown] ->
        inherited = inherited_baseline(incident)

        {:ok,
         if(DateTime.compare(completed_at, inherited) == :gt, do: completed_at, else: inherited)}

      _other ->
        {:error, "Relevant Target effect is not complete"}
    end
  end

  defp lineage_effects(_incident, _seen, depth) when depth >= @max_lineage_depth,
    do: {:error, "Case split lineage exceeds recovery bound"}

  defp lineage_effects(incident, seen, depth) do
    if MapSet.member?(seen, incident.id) do
      {:error, "Case split lineage contains a cycle"}
    else
      with {:ok, operations} <- Cases.operations_for_case(incident.id, authorize?: false),
           true <-
             length(operations) < 100 || {:error, "Operation history exceeds recovery bound"},
           {:ok, effects} <- scoped_effects(operations),
           {:ok, parent_effects} <-
             parent_effects(incident, MapSet.put(seen, incident.id), depth + 1) do
        {:ok, effects ++ parent_effects}
      end
    end
  end

  defp parent_effects(%{split_parent_id: nil}, _seen, _depth), do: {:ok, []}

  defp parent_effects(%{split_parent_id: parent_id}, seen, depth) do
    with {:ok, parent} <- Cases.get_case(parent_id, authorize?: false) do
      lineage_effects(parent, seen, depth)
    end
  end

  defp scoped_effects(operations) do
    operations
    |> Enum.filter(fn operation ->
      operation.request_kind == :effect and
        not (operation.status == :failed and is_nil(operation.dispatch_started_at))
    end)
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, effects} ->
      case Cases.get_proposal(operation.proposal_id, authorize?: false) do
        {:ok, proposal} when is_list(proposal.affected_conditions) ->
          ids = Enum.map(proposal.affected_conditions, & &1["condition_id"])
          {:cont, {:ok, [{operation, ids} | effects]}}

        {:error, _error} = error ->
          {:halt, error}

        _invalid ->
          {:halt, {:error, "Effect Condition scope is unavailable"}}
      end
    end)
  end

  defp citation_scope(evidence) do
    content = evidence.content

    {evidence.kind, content["capability"], content["operation"], content["selectors"]}
  end

  defp result(condition, status, evidence_ids \\ []) do
    %{
      condition_id: condition.id,
      revision: condition.revision,
      status: status,
      evidence_ids: evidence_ids
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
