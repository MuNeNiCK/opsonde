defmodule Opsonde.Cases.Case.Actions.Lifecycle do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Accounts
  alias Opsonde.Cases
  alias Opsonde.Cases.{Case, CaseEvent, Evidence, ResolutionRun}

  @limit_fields [
    :max_elapsed_seconds,
    :max_resolver_turns,
    :max_target_requests,
    :max_effects,
    :max_related_targets,
    :max_ai_usage_units,
    :max_no_progress_turns
  ]

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :claim -> claim(input.arguments, context.actor)
      :handoff -> handoff(input.arguments, context.actor)
      :request_cancellation -> request_cancellation(input.arguments, context.actor)
      :record_source_recovery -> record_source_recovery(input.arguments, context.actor)
      :require_attention -> require_attention(input.arguments, context.actor)
      :resume -> resume(input.arguments, context.actor)
    end
  end

  defp claim(arguments, actor) do
    key = idempotency_key("claim", [arguments.id, arguments.expected_revision, actor.id])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident),
           attrs <- %{
             current_owner_id: actor.id
           } do
        update_with_event(
          incident,
          arguments.expected_revision,
          nil,
          actor,
          "case_claimed",
          key,
          attrs,
          %{"owner_id" => actor.id}
        )
      end
    end)
  end

  defp handoff(arguments, actor) do
    key =
      idempotency_key("handoff", [
        arguments.id,
        arguments.expected_revision,
        arguments.owner_id
      ])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident),
           :ok <- ensure_operational_owner(arguments.owner_id) do
        update_with_event(
          incident,
          arguments.expected_revision,
          nil,
          actor,
          "case_handed_off",
          key,
          %{current_owner_id: arguments.owner_id},
          %{"from_owner_id" => incident.current_owner_id, "to_owner_id" => arguments.owner_id}
        )
      end
    end)
  end

  defp request_cancellation(arguments, actor) do
    key = idempotency_key("cancel", [arguments.id, arguments.expected_revision])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident) do
        update_with_event(
          incident,
          arguments.expected_revision,
          nil,
          actor,
          "cancellation_requested",
          key,
          %{cancel_requested: true},
          %{}
        )
      end
    end)
  end

  defp record_source_recovery(arguments, actor) do
    key = idempotency_key("source_recovery", [arguments.id, arguments.expected_revision])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident),
           true <- incident.alert_state == :firing || {:error, "Case has no firing source"},
           {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false) do
        record_recovery(incident, run, arguments.expected_revision, actor, key)
      end
    end)
  end

  defp record_recovery(incident, run, expected_revision, actor, key) do
    recovered_at = DateTime.utc_now()

    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent], fn ->
      with {:ok, updated} <-
             Cases.update_case_record(
               incident,
               expected_revision,
               %{alert_state: :recovered, source_recovered_at: recovered_at},
               actor: actor,
               authorize?: false
             ),
           {:ok, evidence} <-
             Cases.create_evidence_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: run.id,
                 idempotency_key: "source-recovery:#{key}",
                 kind: "source_recovery",
                 source: incident.source,
                 source_ref: incident.source_ref,
                 content: %{
                   "alert_state" => "recovered",
                   "source" => incident.source,
                   "source_ref" => incident.source_ref
                 },
                 observed_at: recovered_at
               },
               authorize?: false
             ),
           {:ok, _event} <-
             create_event(updated, run, actor, "source_recovered", key, %{
               "recovered_at" => DateTime.to_iso8601(recovered_at),
               "evidence_id" => evidence.id
             }) do
        updated
      end
    end)
  end

  defp require_attention(arguments, actor) do
    transition_once(arguments.id, arguments.idempotency_key, fn incident ->
      with {:ok, run} <- active_run(incident.id, arguments.resolution_run_id),
           true <-
             run.revision == arguments.expected_run_revision ||
               {:error, "ResolutionRun revision changed"} do
        Ash.transact([Case, ResolutionRun, CaseEvent], fn ->
          with {:ok, updated} <-
                 Cases.update_case_record(
                   incident,
                   arguments.expected_revision,
                   %{
                     status: :needs_attention,
                     stop_reason: arguments.reason,
                     pending_intent: arguments.pending_intent,
                     required_human_input: arguments.required_human_input
                   },
                   actor: actor,
                   authorize?: false
                 ),
               {:ok, _paused} <-
                 Cases.pause_resolution_run(
                   run,
                   arguments.expected_run_revision,
                   authorize?: false
                 ),
               {:ok, _event} <-
                 create_event(
                   updated,
                   run,
                   actor,
                   "case_needs_attention",
                   arguments.idempotency_key,
                   %{
                     "reason" => arguments.reason,
                     "pending_intent" => arguments.pending_intent,
                     "required_human_input" => arguments.required_human_input
                   }
                 ) do
            updated
          end
        end)
      end
    end)
  end

  defp resume(arguments, actor) do
    key =
      idempotency_key("resume", [
        arguments.id,
        arguments.resolution_run_id,
        arguments.expected_run_revision
      ])

    case event(arguments.id, key) do
      {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
      {:ok, nil} -> resume_with_retry(arguments, actor, key)
      {:error, _error} = error -> error
    end
  end

  defp resume_with_retry(arguments, actor, key) do
    case resume_once(arguments, actor, key) do
      {:error, _error} = failed ->
        case event(arguments.id, key) do
          {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
          _other -> failed
        end

      success ->
        success
    end
  end

  defp resume_once(arguments, actor, key) do
    with {:ok, incident} <- Cases.get_case(arguments.id, authorize?: false),
         true <- incident.status == :needs_attention || {:error, "Case does not need attention"},
         true <-
           incident.revision == arguments.expected_case_revision ||
             {:error, "Case revision changed"},
         {:ok, run} <- active_run(incident.id, arguments.resolution_run_id),
         true <-
           run.revision == arguments.expected_run_revision ||
             {:error, "ResolutionRun revision changed"},
         :ok <- validate_extension(run, arguments) do
      resume_transaction(incident, run, arguments, actor, key)
    end
  end

  defp resume_transaction(incident, run, arguments, actor, key) do
    now = DateTime.utc_now()

    Ash.transact([Case, ResolutionRun, CaseEvent], fn ->
      with {:ok, _retired} <-
             Cases.retire_resolution_run(
               run,
               arguments.expected_run_revision,
               %{status: :superseded, ended_at: now},
               authorize?: false
             ),
           {:ok, updated_case} <-
             Cases.update_case_record(
               incident,
               arguments.expected_case_revision,
               %{
                 current_owner_id: actor.id,
                 status: :running,
                 cancel_requested: false,
                 stop_reason: nil,
                 pending_intent: %{},
                 required_human_input: nil
               },
               actor: actor,
               authorize?: false
             ),
           {:ok, next_run} <- create_resumed_run(incident, run, arguments, actor, now),
           {:ok, _event} <-
             create_event(
               updated_case,
               next_run,
               actor,
               "case_resumed",
               key,
               %{
                 "prior_run_id" => run.id,
                 "prior_generation" => run.generation,
                 "new_generation" => next_run.generation,
                 "reason" => arguments.reason,
                 "prior" => settings_map(run),
                 "new" => settings_map(next_run)
               }
             ) do
        next_run
      end
    end)
  end

  defp create_resumed_run(incident, run, arguments, actor, now) do
    attrs =
      arguments
      |> Map.take([:authority_mode | @limit_fields])
      |> Map.merge(%{
        case_id: incident.id,
        generation: run.generation + 1,
        active: true,
        status: :running,
        turn_count: 0,
        target_request_count: 0,
        effect_count: 0,
        related_target_count: 0,
        ai_usage_units: 0,
        no_progress_turns: 0,
        started_at: now,
        deadline_at: DateTime.add(now, arguments.max_elapsed_seconds, :second),
        resume_reason: arguments.reason,
        resumed_by_id: actor.id
      })

    Cases.create_resolution_run_record(attrs, authorize?: false)
  end

  defp validate_extension(run, arguments) do
    if Enum.all?(@limit_fields, &(Map.fetch!(arguments, &1) >= Map.fetch!(run, &1))) do
      :ok
    else
      {:error, "Resume limits cannot reduce the prior run limits"}
    end
  end

  defp transition_once(case_id, key, transition) do
    case event(case_id, key) do
      {:ok, %CaseEvent{}} -> Cases.get_case(case_id, authorize?: false)
      {:ok, nil} -> perform_transition(case_id, key, transition)
      {:error, _error} = error -> error
    end
  end

  defp perform_transition(case_id, key, transition) do
    with {:ok, incident} <- Cases.get_case(case_id, authorize?: false) do
      case transition.(incident) do
        {:error, _error} = failed ->
          case event(case_id, key) do
            {:ok, %CaseEvent{}} -> Cases.get_case(case_id, authorize?: false)
            _other -> failed
          end

        success ->
          success
      end
    end
  end

  defp update_with_event(
         incident,
         expected_revision,
         run,
         actor,
         event_type,
         key,
         attrs,
         data
       ) do
    Ash.transact([Case, CaseEvent], fn ->
      with {:ok, updated} <-
             Cases.update_case_record(incident, expected_revision, attrs,
               actor: actor,
               authorize?: false
             ),
           {:ok, _event} <- create_event(updated, run, actor, event_type, key, data) do
        updated
      end
    end)
  end

  defp create_event(incident, run, actor, event_type, key, data) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run && run.id,
        actor_id: actor && actor.id,
        event_type: event_type,
        idempotency_key: key,
        data: data
      },
      authorize?: false
    )
  end

  defp active_run(case_id, expected_id) do
    case Cases.active_resolution_run(case_id, authorize?: false) do
      {:ok, %{id: ^expected_id} = run} -> {:ok, run}
      {:ok, _run} -> {:error, "Active ResolutionRun changed"}
      {:error, _error} = error -> error
    end
  end

  defp active_run_result(case_id), do: Cases.active_resolution_run(case_id, authorize?: false)

  defp event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp ensure_operational_owner(id) do
    case Accounts.get_user(id, authorize?: false) do
      {:ok, %{role: role}} when role in [:admin, :operator] -> :ok
      {:ok, _user} -> {:error, "Case owner must be an administrator or operator"}
      {:error, _error} -> {:error, "Case owner is unavailable"}
    end
  end

  defp ensure_mutable(%{status: status}) when status in [:running, :needs_attention],
    do: :ok

  defp ensure_mutable(_incident), do: {:error, "Case is already terminal"}

  defp settings_map(record) do
    %{
      "authority_mode" => to_string(record.authority_mode),
      "max_elapsed_seconds" => record.max_elapsed_seconds,
      "max_resolver_turns" => record.max_resolver_turns,
      "max_target_requests" => record.max_target_requests,
      "max_effects" => record.max_effects,
      "max_related_targets" => record.max_related_targets,
      "max_ai_usage_units" => record.max_ai_usage_units,
      "max_no_progress_turns" => record.max_no_progress_turns
    }
  end

  defp idempotency_key(prefix, values) do
    digest =
      values
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{prefix}:#{digest}"
  end
end
