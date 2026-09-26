defmodule Opsonde.Cases.Case.Actions.VerifiedEffectRecovery do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.{Cases, Signals}

  alias Opsonde.Cases.{
    Case,
    CaseEvent,
    Evidence,
    ResolutionRun,
    Turn
  }

  alias Opsonde.Cases.SignalRecoveryCheckWorker
  alias Opsonde.Cases.Case.Actions.RecoveryCompletion

  @monitor_wait_seconds 30

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent, Turn], fn ->
      with {:ok, incident} <- lock_case(input.arguments.id),
           {:ok, attempt} <-
             Cases.get_verification_attempt(input.arguments.verification_attempt_id,
               authorize?: false
             ),
           {:ok, operation} <- Cases.get_operation(attempt.operation_id, authorize?: false),
           {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           {:ok, evidence} <- verification_evidence(attempt),
           :ok <- valid_verification(incident, run, attempt, operation, evidence) do
        reconcile(incident, run, attempt, evidence)
      end
    end)
  end

  # Called only from the Case source-recovery action, within its transaction.
  def after_source_recovery(incident, run) do
    case incident.pending_intent do
      %{"action" => action, "verification_attempt_id" => attempt_id}
      when action in ["await_source_recovery", "resolve_turn"] ->
        with {:ok, attempt} <- Cases.get_verification_attempt(attempt_id, authorize?: false),
             {:ok, operation} <- Cases.get_operation(attempt.operation_id, authorize?: false),
             {:ok, evidence} <- verification_evidence(attempt) do
          case valid_verification(incident, run, attempt, operation, evidence) do
            :ok ->
              settle_after_source_recovery(incident, run, attempt, operation, evidence)

            {:error, "Verified Target effect is not current for this Signal Case"} ->
              {:ok, :continue}
          end
        end

      _other ->
        {:ok, :continue}
    end
  end

  defp settle_after_source_recovery(incident, run, attempt, operation, evidence) do
    case all_sources_recovered(incident, operation) do
      :ok ->
        case resolve(incident, run, attempt, evidence) do
          {:ok, resolved} -> {:ok, {:resolved, resolved}}
          {:error, _error} = error -> error
        end

      {:error, reason} when reason in [:source_firing, :source_stale] ->
        {:ok, :continue}

      {:error, _error} = error ->
        error
    end
  end

  defp reconcile(%{status: :resolved} = incident, _run, _attempt, _evidence),
    do: {:ok, incident}

  defp reconcile(incident, run, attempt, evidence) do
    case incident.pending_intent do
      %{"action" => "await_source_recovery", "verification_attempt_id" => id}
      when id == attempt.id ->
        settle_or_wait(incident, run, attempt, evidence)

      %{"action" => "evaluate_verification", "verification_attempt_id" => id}
      when id == attempt.id ->
        settle_or_wait(incident, run, attempt, evidence)

      %{"action" => "resolve_turn", "verification_attempt_id" => id}
      when id == attempt.id ->
        {:ok, incident}

      _other ->
        {:error, "Case is not awaiting this Target verification"}
    end
  end

  defp settle_or_wait(incident, run, attempt, evidence) do
    with {:ok, operation} <- Cases.get_operation(attempt.operation_id, authorize?: false) do
      case all_sources_recovered(incident, operation) do
        :ok ->
          resolve(incident, run, attempt, evidence)

        {:error, :source_firing} ->
          wait_or_investigate(incident, run, attempt, evidence)

        {:error, :source_stale} ->
          investigate(incident, run, attempt, evidence)

        {:error, _error} = error ->
          error
      end
    end
  end

  defp wait_or_investigate(incident, run, attempt, evidence) do
    deadline =
      attempt.completed_at
      |> DateTime.add(@monitor_wait_seconds, :second)
      |> min_datetime(run.deadline_at)

    if DateTime.compare(DateTime.utc_now(), deadline) in [:eq, :gt] do
      investigate(incident, run, attempt, evidence)
    else
      case incident.pending_intent do
        %{"action" => "await_source_recovery", "verification_attempt_id" => id}
        when id == attempt.id ->
          {:ok, incident}

        _other ->
          pending = %{
            "action" => "await_source_recovery",
            "verification_attempt_id" => attempt.id,
            "verification_evidence_id" => evidence.id,
            "operation_id" => attempt.operation_id,
            "wait_until" => DateTime.to_iso8601(deadline)
          }

          with {:ok, waiting} <-
                 Cases.update_case_record(
                   incident,
                   incident.revision,
                   %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
                   authorize?: false
                 ),
               {:ok, _event} <-
                 Cases.create_case_event_record(
                   %{
                     case_id: incident.id,
                     resolution_run_id: run.id,
                     event_type: "case_awaiting_source_recovery",
                     idempotency_key: "await-source-recovery:#{attempt.id}",
                     data: %{
                       "verification_attempt_id" => attempt.id,
                       "verification_evidence_id" => evidence.id,
                       "wait_until" => DateTime.to_iso8601(deadline)
                     }
                   },
                   authorize?: false
                 ),
               {:ok, _job} <-
                 %{"case_id" => incident.id, "verification_attempt_id" => attempt.id}
                 |> SignalRecoveryCheckWorker.new(scheduled_at: deadline)
                 |> Oban.insert() do
            {:ok, waiting}
          end
      end
    end
  end

  defp investigate(incident, run, attempt, evidence) do
    with {:ok, result} <-
           Cases.start_turn(
             incident.id,
             run.id,
             "signal-still-firing:#{attempt.id}",
             %{
               "objective" =>
                 "Investigate why monitoring still reports a fault after Target verification",
               "verification_attempt_id" => attempt.id,
               "verification_evidence_id" => evidence.id,
               "alert_state" => to_string(incident.alert_state)
             },
             %{
               "action" => "review_post_verification_limit",
               "verification_attempt_id" => attempt.id
             },
             "Review the Case if investigation cannot continue",
             authorize?: false
           ) do
      case result do
        %{status: status, value: turn} when status in [:charged, :duplicate] ->
          with {:ok, current} <- Cases.get_case(incident.id, authorize?: false) do
            Cases.update_case_record(
              current,
              current.revision,
              %{
                pending_intent: %{
                  "action" => "resolve_turn",
                  "turn_id" => turn.id,
                  "verification_attempt_id" => attempt.id,
                  "verification_evidence_id" => evidence.id,
                  "operation_id" => attempt.operation_id
                }
              },
              authorize?: false
            )
          end

        %{status: :exhausted, case: stopped} ->
          {:ok, stopped}
      end
    end
  end

  defp resolve(incident, run, attempt, evidence) do
    RecoveryCompletion.complete(
      incident,
      run,
      "verified-signal-recovery:#{attempt.id}",
      %{
        "reason" => "Target effect verified and all monitoring sources recovered",
        "verification_evidence_id" => evidence.id,
        "operation_id" => attempt.operation_id
      }
    )
  end

  defp valid_verification(incident, run, attempt, operation, evidence) do
    expected = attempt.expected
    facts = attempt.facts

    if incident.trigger_kind == :signal and incident.status == :running and
         not incident.cancel_requested and run.active and run.status == :running and
         run.case_id == incident.id and run.id == attempt.resolution_run_id and
         run.generation == attempt.case_generation and attempt.case_id == incident.id and
         attempt.status == :verified and operation.status == :applied and
         operation.request_kind == :effect and operation.id == attempt.operation_id and
         operation.case_id == incident.id and operation.resolution_run_id == run.id and
         attempt.target_id == incident.selected_target_id and
         attempt.target_revision == incident.selected_target_revision and
         operation.target_id == attempt.target_id and
         operation.target_revision == attempt.target_revision and
         is_map(expected) and map_size(expected) > 0 and is_map(facts) and
         Enum.all?(expected, fn {key, value} -> Map.get(facts, key) == value end) and
         match?(%DateTime{}, attempt.observed_at) and
         match?(%DateTime{}, operation.completed_at) and
         DateTime.compare(attempt.observed_at, operation.completed_at) in [:eq, :gt] and
         evidence.case_id == incident.id and evidence.resolution_run_id == run.id and
         evidence.kind == "target_verification" and evidence.source == "verification" and
         evidence.content["status"] == "verified" and
         evidence.content["operation_id"] == operation.id do
      :ok
    else
      {:error, "Verified Target effect is not current for this Signal Case"}
    end
  end

  defp all_sources_recovered(
         %{alert_state: :recovered, source_recovered_at: %DateTime{}} = incident,
         operation
       ) do
    case Signals.signal_correlations_for_case(incident.id, authorize?: false) do
      {:ok, [_first | _rest] = correlations} ->
        cond do
          not Enum.all?(correlations, &(&1.current_state == :recovered)) ->
            {:error, :source_firing}

          Enum.any?(correlations, fn correlation ->
            not match?(%DateTime{}, correlation.current_occurred_at) or
                DateTime.compare(correlation.current_occurred_at, operation.accepted_at) == :lt
          end) ->
            {:error, :source_stale}

          true ->
            :ok
        end

      {:ok, []} ->
        {:error, :source_firing}

      {:error, _error} = error ->
        error
    end
  end

  defp all_sources_recovered(_incident, _operation), do: {:error, :source_firing}

  defp verification_evidence(attempt) do
    Cases.evidence_by_idempotency(
      attempt.case_id,
      "verification:outcome:#{attempt.id}",
      authorize?: false
    )
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Case{} = incident} -> {:ok, incident}
      {:ok, nil} -> {:error, "Case is unavailable"}
      {:error, _error} = error -> error
    end
  end

  defp min_datetime(left, right) do
    if DateTime.compare(left, right) == :gt, do: right, else: left
  end
end
