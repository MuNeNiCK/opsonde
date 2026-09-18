defmodule Opsonde.Cases.Case.Actions.Open do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Cases
  alias Opsonde.Cases.{AuthoritySetting, Case, CaseEvent, ResolutionRun}
  alias Opsonde.Targets

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    with :ok <- validate_trigger(arguments.trigger_kind, arguments.alert_state),
         {:ok, existing} <- existing_case(arguments) do
      if existing do
        {:ok, existing}
      else
        with {:ok, initial_target} <- load_initial_target(arguments.initial_target_id) do
          create_case(arguments, initial_target, context.actor)
        end
      end
    end
  end

  defp create_case(arguments, initial_target, actor) do
    result =
      Ash.transact([AuthoritySetting, Case, ResolutionRun, CaseEvent], fn ->
        with {:ok, setting} <- locked_current_setting(),
             now <- DateTime.utc_now(),
             {:ok, incident} <- create_case_record(arguments, initial_target, setting, actor),
             {:ok, run} <- create_run(incident, setting, now),
             {:ok, _event} <- create_opened_event(incident, run, actor, arguments) do
          incident
        end
      end)

    case result do
      {:error, _error} = failed ->
        case existing_case(arguments) do
          {:ok, %Case{} = existing} -> {:ok, existing}
          _other -> failed
        end

      success ->
        success
    end
  end

  defp existing_case(arguments) do
    Cases.case_by_trigger(
      arguments.trigger_kind,
      arguments.source,
      arguments.source_ref,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp locked_current_setting(attempts \\ 2) do
    result =
      AuthoritySetting
      |> Ash.Query.for_read(:current)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)

    case result do
      {:ok, %AuthoritySetting{} = setting} -> {:ok, setting}
      {:ok, nil} when attempts > 1 -> locked_current_setting(attempts - 1)
      {:ok, nil} -> {:error, "Standing authority setting is unavailable"}
      {:error, _error} = error -> error
    end
  end

  defp create_case_record(arguments, initial_target, setting, actor) do
    {status, pending_intent, stop_reason, required_human_input} =
      initial_state(arguments, setting)

    attrs = %{
      trigger_kind: arguments.trigger_kind,
      source: arguments.source,
      source_ref: arguments.source_ref,
      title: arguments.title,
      severity: arguments.severity,
      alert_state: arguments.alert_state,
      status: status,
      initial_context: arguments.initial_context,
      authority_setting_id: setting.id,
      authority_setting_revision: setting.setting_revision,
      authority_mode: setting.authority_mode,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      cancel_requested: false,
      pending_intent: pending_intent,
      stop_reason: stop_reason,
      required_human_input: required_human_input,
      initial_target_id: arguments.initial_target_id,
      selected_target_id: initial_target && initial_target.id,
      selected_target_revision: initial_target && initial_target.revision,
      current_owner_id: actor_id(actor)
    }

    Cases.create_case_record(attrs, actor: actor, authorize?: false)
  end

  defp create_run(incident, setting, now) do
    attrs = %{
      case_id: incident.id,
      generation: 1,
      active: true,
      status: run_status(incident.status),
      authority_mode: setting.authority_mode,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      turn_count: 0,
      target_request_count: 0,
      effect_count: 0,
      related_target_count: 0,
      ai_usage_units: 0,
      no_progress_turns: 0,
      started_at: now,
      deadline_at: DateTime.add(now, setting.max_elapsed_seconds, :second)
    }

    Cases.create_resolution_run_record(attrs, authorize?: false)
  end

  defp create_opened_event(incident, run, actor, arguments) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor_id(actor),
        event_type: "case_opened",
        idempotency_key:
          idempotency_key("open", [
            arguments.trigger_kind,
            arguments.source,
            arguments.source_ref
          ]),
        data: %{
          "trigger_kind" => to_string(arguments.trigger_kind),
          "source" => arguments.source,
          "source_ref" => arguments.source_ref,
          "authority_setting_revision" => incident.authority_setting_revision,
          "run_generation" => run.generation,
          "selected_target_id" => incident.selected_target_id,
          "selected_target_revision" => incident.selected_target_revision
        }
      },
      authorize?: false
    )
  end

  defp validate_trigger(:signal, :firing), do: :ok
  defp validate_trigger(kind, :not_applicable) when kind in [:manual, :audit], do: :ok
  defp validate_trigger(_kind, _state), do: {:error, "Trigger kind and alert state do not match"}

  defp load_initial_target(nil), do: {:ok, nil}

  defp load_initial_target(id) do
    case Targets.get_target(id, authorize?: false) do
      {:ok, %{active: true} = target} -> {:ok, target}
      {:ok, _target} -> {:error, "Initial Target is inactive"}
      {:error, _error} -> {:error, "Initial Target is unavailable"}
    end
  end

  defp initial_state(%{trigger_kind: :signal}, %{signal_automation_enabled: false}),
    do:
      {:needs_attention, %{"action" => "start_resolution"}, "Signal automation is disabled",
       "Enable automation or claim the Case"}

  defp initial_state(_arguments, _setting), do: {:running, %{}, nil, nil}

  defp run_status(:needs_attention), do: :needs_attention
  defp run_status(_status), do: :running

  defp idempotency_key(prefix, values) do
    digest =
      values
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{prefix}:#{digest}"
  end

  defp actor_id(nil), do: nil
  defp actor_id(actor), do: actor.id
end
