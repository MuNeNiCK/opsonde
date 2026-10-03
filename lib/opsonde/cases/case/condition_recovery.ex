defmodule Opsonde.Cases.Case.ConditionRecovery do
  @moduledoc false

  alias Opsonde.{Cases, Targets}

  defmodule EffectIncomplete do
    @moduledoc false
    use Splode.Error, class: :invalid, fields: []

    @impl true
    def message(_error), do: "Relevant Target effect is not complete"
  end

  @max_evidence 256
  @max_lineage_depth 32
  @max_citations_per_condition 3

  # Evidence availability does not decide whether the fault recovered.
  def assess_current(incident, exclude_operation_id \\ nil) do
    with {:ok, memberships} <-
           Cases.active_conditions_for_case(incident.id, authorize?: false, load: [:condition]),
         true <- memberships != [] || invalid("Signal Case has no active Conditions"),
         {:ok, effects} <- lineage_effects(incident, MapSet.new(), 0, exclude_operation_id),
         {:ok, evidence} <-
           Cases.condition_assessment_evidence(
             incident.id,
             inherited_baseline(incident),
             authorize?: false
           ),
         true <-
           length(evidence) <= @max_evidence || invalid("Condition evidence window is full") do
      Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, collected} ->
        with condition <- membership.condition,
             {:ok, baseline} <- condition_baseline(incident, condition.id, effects),
             {:ok, assessment} <- assess_condition(condition, evidence, baseline) do
          {:cont, {:ok, [assessment | collected]}}
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

  def applied_effect_refresh_at(incident, run_id, condition_ids) do
    selected = MapSet.new(condition_ids)

    if MapSet.size(selected) == 0 do
      {:ok, nil}
    else
      with {:ok, effects} <- lineage_effects(incident, MapSet.new(), 0, nil) do
        effects
        |> Enum.filter(fn {operation, ids} ->
          operation.resolution_run_id == run_id and operation.status == :applied and
            is_struct(operation.completed_at, DateTime) and
            Enum.any?(ids, &MapSet.member?(selected, &1))
        end)
        |> Enum.map(fn {operation, _ids} -> operation.completed_at end)
        |> then(&{:ok, Enum.max(&1, DateTime, fn -> nil end)})
      end
    end
  end

  def baseline_for_case(incident) do
    inherited = inherited_baseline(incident)

    with {:ok, operations} <- Cases.operations_for_case(incident.id, authorize?: false),
         true <- length(operations) < 100 || invalid("Operation history exceeds recovery bound") do
      operations
      |> Enum.filter(&affects_recovery?/1)
      |> Enum.sort_by(& &1.accepted_at, {:desc, DateTime})
      |> case do
        [] ->
          {:ok, inherited}

        [%{status: status, completed_at: %DateTime{} = at} | _]
        when status in [:applied, :failed, :partial, :unknown] ->
          {:ok, if(DateTime.compare(at, inherited) == :gt, do: at, else: inherited)}

        _other ->
          invalid("Latest Target effect is not complete")
      end
    end
  end

  # This marks evidence available for AI review; it never decides recovery.
  def manual_evidence_ids(incident, run, target, evidence)
      when incident.trigger_kind in [:manual, :audit] and not is_nil(target) do
    case baseline_for_case(incident) do
      {:ok, baseline} ->
        with {:ok, candidates} <-
               select_evidence(evidence, &manual_candidate(&1, incident, run, target, baseline)) do
          {:ok, Enum.map(candidates, & &1.id)}
        end

      {:error, %Ash.Error.Changes.InvalidChanges{}} ->
        {:ok, []}

      {:error, _error} = error ->
        error
    end
  end

  def manual_evidence_ids(_incident, _run, _target, _evidence), do: {:ok, []}

  defp manual_candidate(
         %{kind: "file_read"} = evidence,
         incident,
         run,
         target,
         baseline
       ) do
    if is_binary(evidence.content["value"]) do
      case Cases.file_read_source(evidence.id, incident.id, authorize?: false) do
        {:ok, source} -> manual_candidate(source, incident, run, target, baseline)
        {:error, error} -> unavailable_source(error)
      end
    else
      {:ok, false}
    end
  end

  defp manual_candidate(evidence, incident, run, target, baseline) do
    if DateTime.compare(evidence.observed_at, baseline) != :lt and
         evidence.content["target_id"] == target.id do
      case evidence do
        %{
          kind: "observation",
          source: "operation",
          source_ref: operation_id,
          content: %{"status" => "applied", "facts" => facts}
        }
        when is_map(facts) and map_size(facts) > 0 ->
          case Cases.get_operation(operation_id, authorize?: false, not_found_error?: false) do
            {:ok, %{} = operation} ->
              {:ok,
               evidence.resolution_run_id == run.id and operation.case_id == incident.id and
                 operation.resolution_run_id == run.id and
                 operation.target_id == target.id and operation.target_revision == target.revision and
                 operation.purpose == :investigation and operation.status == :applied and
                 is_struct(operation.dispatch_started_at, DateTime) and
                 DateTime.compare(operation.dispatch_started_at, baseline) != :lt}

            {:error, _error} = error ->
              error

            _other ->
              {:ok, false}
          end

        %{
          kind: "target_verification",
          source: "verification",
          content: %{"status" => "verified", "operation_id" => operation_id}
        } ->
          with {:ok, %{} = operation} <-
                 Cases.get_operation(operation_id, authorize?: false, not_found_error?: false),
               {:ok, %{} = attempt} <-
                 Cases.verification_attempt_by_operation(operation_id,
                   authorize?: false,
                   not_found_error?: false
                 ) do
            {:ok,
             operation.case_id == incident.id and operation.target_id == target.id and
               operation.target_revision == target.revision and
               operation.purpose == :remediation and operation.status == :applied and
               attempt.status == :verified and attempt.case_id == incident.id and
               attempt.observed_at == evidence.observed_at}
          else
            {:error, _error} = error -> error
            _other -> {:ok, false}
          end

        _other ->
          {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  def ready_for_review?(assessments) when is_list(assessments) and assessments != [] do
    Enum.all?(assessments, &(&1.status == :ready_for_review))
  end

  def ready_for_review?(_assessments), do: false

  defp current_evidence(%{kind: "file_read"} = evidence, condition, baseline, target_revision) do
    case Cases.file_read_source(evidence.id, evidence.case_id, authorize?: false) do
      {:ok, source} -> current_evidence(source, condition, baseline, target_revision)
      {:error, error} -> unavailable_source(error)
    end
  end

  defp current_evidence(evidence, condition, baseline, target_revision)
       when is_struct(baseline, DateTime) do
    if DateTime.compare(evidence.observed_at, baseline) != :lt and
         DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt and
         evidence.content["target_id"] == condition.target_id do
      valid_operation_evidence(evidence, condition, target_revision)
    else
      {:ok, false}
    end
  end

  defp assess_condition(condition, evidence, after_at) do
    cond do
      condition.state != :recovered ->
        {:ok, result(condition, :firing)}

      is_nil(condition.target_id) ->
        {:ok, result(condition, :unmapped_target)}

      true ->
        case Targets.get_target(condition.target_id, authorize?: false, not_found_error?: false) do
          {:ok, %{active: true, revision: revision}} ->
            with {:ok, failed_evidence} <-
                   select_evidence(
                     evidence,
                     &current_failed_observation(&1, condition, after_at, revision)
                   ),
                 {:ok, current_evidence} <-
                   select_evidence(evidence, &current_evidence(&1, condition, after_at, revision)) do
              failed_ids =
                failed_evidence
                |> Enum.uniq_by(&citation_scope/1)
                |> Enum.take(@max_citations_per_condition)
                |> Enum.map(& &1.id)

              citations =
                current_evidence
                |> Enum.uniq_by(&citation_scope/1)
                |> Enum.take(@max_citations_per_condition)
                |> Enum.map(& &1.id)

              {:ok,
               case citations do
                 [] ->
                   if DateTime.compare(condition.current_occurred_at, after_at) == :lt,
                     do: result(condition, :stale_source, [], failed_ids),
                     else: result(condition, :needs_observation, [], failed_ids)

                 ids ->
                   result(condition, :ready_for_review, ids, failed_ids)
               end}
            end

          {:error, _error} = error ->
            error

          _other ->
            {:ok, result(condition, :target_changed)}
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
        {:error, EffectIncomplete.exception([])}
    end
  end

  defp lineage_effects(_incident, _seen, depth, _exclude_operation_id)
       when depth >= @max_lineage_depth,
       do: invalid("Case split lineage exceeds recovery bound")

  defp lineage_effects(incident, seen, depth, exclude_operation_id) do
    if MapSet.member?(seen, incident.id) do
      invalid("Case split lineage contains a cycle")
    else
      with {:ok, operations} <- Cases.operations_for_case(incident.id, authorize?: false),
           true <-
             length(operations) < 100 || invalid("Operation history exceeds recovery bound"),
           {:ok, effects} <- scoped_effects(operations, exclude_operation_id),
           {:ok, parent_effects} <-
             parent_effects(
               incident,
               MapSet.put(seen, incident.id),
               depth + 1,
               exclude_operation_id
             ) do
        {:ok, effects ++ parent_effects}
      end
    end
  end

  defp parent_effects(%{split_parent_id: nil}, _seen, _depth, _exclude_operation_id),
    do: {:ok, []}

  defp parent_effects(%{split_parent_id: parent_id}, seen, depth, exclude_operation_id) do
    with {:ok, parent} <- Cases.get_case(parent_id, authorize?: false) do
      lineage_effects(parent, seen, depth, exclude_operation_id)
    end
  end

  defp scoped_effects(operations, exclude_operation_id) do
    operations
    |> Enum.filter(fn operation ->
      operation.id != exclude_operation_id and affects_recovery?(operation)
    end)
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, effects} ->
      case Cases.get_proposal(operation.proposal_id, authorize?: false) do
        {:ok, proposal} when is_list(proposal.affected_conditions) ->
          ids = Enum.map(proposal.affected_conditions, & &1["condition_id"])
          {:cont, {:ok, [{operation, ids} | effects]}}

        {:error, _error} = error ->
          {:halt, error}

        _invalid ->
          {:halt, invalid("Effect Condition scope is unavailable")}
      end
    end)
  end

  defp affects_recovery?(operation),
    do:
      operation.purpose == :remediation and
        not (operation.status == :failed and is_nil(operation.dispatch_started_at))

  defp citation_scope(%{kind: "file_read", id: id}), do: {"file_read", id}

  defp citation_scope(evidence) do
    content = evidence.content

    {evidence.kind, content["capability"], content["operation"], content["selectors"]}
  end

  defp result(condition, status, evidence_ids \\ [], failed_observation_ids \\ []) do
    %{
      condition_id: condition.id,
      revision: condition.revision,
      status: status,
      evidence_ids: evidence_ids,
      failed_observation_ids: failed_observation_ids
    }
  end

  defp select_evidence(evidence, candidate) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, selected} ->
      case candidate.(item) do
        {:ok, true} -> {:cont, {:ok, [item | selected]}}
        {:ok, false} -> {:cont, {:ok, selected}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp current_failed_observation(evidence, condition, baseline, target_revision) do
    with true <- DateTime.compare(evidence.observed_at, baseline) != :lt,
         true <- DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt,
         true <-
           evidence.kind == "observation" and
             evidence.source == "operation" and
             evidence.content["target_id"] == condition.target_id and
             evidence.content["status"] == "failed",
         {:ok, %{} = operation} <-
           Cases.get_operation(evidence.source_ref, authorize?: false, not_found_error?: false),
         true <- operation.id == evidence.source_ref and operation.case_id == evidence.case_id,
         true <-
           operation.purpose == :investigation and operation.status == :failed and
             is_struct(operation.dispatch_started_at, DateTime),
         true <-
           operation.target_id == condition.target_id and
             operation.target_revision == target_revision,
         true <-
           operation.capability == evidence.content["capability"] and
             operation.operation == evidence.content["operation"] and
             operation.selectors == evidence.content["selectors"] do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _invalid -> {:ok, false}
    end
  end

  defp valid_operation_evidence(
         %{kind: "observation", source: "operation", content: content} = evidence,
         condition,
         revision
       ) do
    with true <- content["status"] == "applied",
         true <- content["target_id"] == condition.target_id,
         {:ok, %{} = operation} <-
           Cases.get_operation(evidence.source_ref, authorize?: false, not_found_error?: false),
         true <- operation.purpose == :investigation and operation.status == :applied,
         true <- operation.case_id == evidence.case_id and operation.id == evidence.source_ref,
         true <-
           operation.target_id == condition.target_id and operation.target_revision == revision,
         true <- operation.capability == content["capability"],
         true <- operation.operation == content["operation"],
         true <- operation.selectors == content["selectors"] do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _other -> {:ok, false}
    end
  end

  defp valid_operation_evidence(
         %{kind: "target_verification", source: "verification", content: content} = evidence,
         condition,
         revision
       ) do
    with true <- content["status"] == "verified" and content["target_id"] == condition.target_id,
         {:ok, %{} = operation} <-
           Cases.get_operation(content["operation_id"],
             authorize?: false,
             not_found_error?: false
           ),
         true <- operation.purpose == :remediation and operation.status == :applied,
         true <-
           operation.case_id == evidence.case_id and operation.target_id == condition.target_id,
         true <- operation.target_revision == revision,
         {:ok, %{} = attempt} <-
           Cases.verification_attempt_by_operation(operation.id,
             authorize?: false,
             not_found_error?: false
           ),
         true <- attempt.status == :verified and attempt.target_id == condition.target_id,
         true <-
           attempt.target_revision == revision and attempt.observed_at == evidence.observed_at do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _other -> {:ok, false}
    end
  end

  defp valid_operation_evidence(_evidence, _condition, _revision), do: {:ok, false}

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}

  defp unavailable_source(%Ash.Error.Invalid{errors: [%type{}]})
       when type in [
              Ash.Error.Changes.InvalidChanges,
              Ash.Error.Changes.InvalidAttribute,
              Ash.Error.Query.NotFound,
              Ash.Error.Action.InvalidArgument
            ],
       do: {:ok, false}

  defp unavailable_source(%Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]}),
    do: {:ok, false}

  defp unavailable_source(error), do: {:error, error}
end
