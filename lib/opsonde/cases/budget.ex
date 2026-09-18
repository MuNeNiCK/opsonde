defmodule Opsonde.Cases.Budget do
  require Ash.Query

  alias Opsonde.Cases
  alias Opsonde.Cases.{BudgetResult, Case, CaseEvent, ResolutionRun}

  @counter_fields [
    :turn_count,
    :target_request_count,
    :effect_count,
    :related_target_count,
    :ai_usage_units,
    :no_progress_turns
  ]

  @spec consume(keyword()) :: {:ok, BudgetResult.t()} | {:error, term()}
  def consume(opts) do
    Ash.transact([Case, ResolutionRun, CaseEvent], fn -> consume_locked(opts) end)
  end

  def key(namespace, raw_key) do
    digest = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
    "#{namespace}:#{digest}"
  end

  defp consume_locked(opts) do
    with {:ok, incident} <- lock_case(opts[:case_id]),
         {:ok, run} <- lock_run(opts[:resolution_run_id], incident.id),
         {:ok, event} <- existing_event(incident.id, opts[:ledger_key]) do
      if event do
        replay_result(incident, run, event, opts)
      else
        consume_new(incident, run, opts)
      end
    end
  end

  defp replay_result(incident, run, event, opts) do
    with :ok <- validate_replay(event, opts) do
      if event.event_type == "limit_exhausted" do
        %BudgetResult{
          status: :exhausted,
          case: incident,
          run: run,
          reason: incident.stop_reason
        }
      else
        duplicate_result(incident, run, opts)
      end
    end
  end

  defp validate_replay(event, opts) do
    expected_kind = to_string(opts[:kind])

    if event.data["attempted_kind"] in [nil, expected_kind] and
         event.data["kind"] in [nil, expected_kind] and
         event.data["attempted_amount"] in [nil, opts[:amount]] and
         event.data["amount"] in [nil, opts[:amount]] and replay_data_matches?(event, opts) do
      :ok
    else
      {:error, "Idempotency key was already used with different budget input"}
    end
  end

  defp replay_data_matches?(event, opts) do
    opts
    |> Keyword.get(:event_data, %{})
    |> Enum.all?(fn {key, value} -> event.data[key] == value end)
  end

  defp consume_new(incident, run, opts) do
    with :ok <- ensure_running(incident, run) do
      case exhausted_limit(run, opts[:kind], opts[:amount], DateTime.utc_now()) do
        nil -> charge(incident, run, opts)
        limit -> exhaust(incident, run, limit, opts)
      end
    end
  end

  defp charge(incident, run, opts) do
    counters = next_counters(run, opts[:kind], opts[:amount])

    with {:ok, updated_run} <-
           Cases.update_resolution_run_counters(
             run,
             run.revision,
             counters,
             authorize?: false
           ),
         {:ok, value} <- opts[:operation].(incident, updated_run),
         {:ok, _event} <-
           create_event(
             incident,
             updated_run,
             opts[:actor],
             opts[:event_type],
             opts[:ledger_key],
             event_data(opts, updated_run, value)
           ) do
      %BudgetResult{status: :charged, case: incident, run: updated_run, value: value}
    end
  end

  defp exhaust(incident, run, limit, opts) do
    reason = limit_reason(limit)

    with {:ok, updated_case} <-
           Cases.update_case_record(
             incident,
             incident.revision,
             %{
               status: :needs_attention,
               stop_reason: reason,
               pending_intent: opts[:pending_intent],
               required_human_input: opts[:required_human_input]
             },
             authorize?: false
           ),
         {:ok, paused_run} <-
           Cases.pause_resolution_run(run, run.revision, authorize?: false),
         {:ok, _event} <-
           create_event(
             updated_case,
             paused_run,
             opts[:actor],
             "limit_exhausted",
             opts[:ledger_key],
             Map.merge(Keyword.get(opts, :event_data, %{}), %{
               "limit" => to_string(limit),
               "reason" => reason,
               "attempted_kind" => to_string(opts[:kind]),
               "attempted_amount" => opts[:amount],
               "pending_intent" => opts[:pending_intent],
               "required_human_input" => opts[:required_human_input]
             })
           ) do
      %BudgetResult{
        status: :exhausted,
        case: updated_case,
        run: paused_run,
        reason: reason
      }
    end
  end

  defp duplicate_result(incident, run, opts) do
    with {:ok, value} <- opts[:duplicate].(incident, run) do
      %BudgetResult{status: :duplicate, case: incident, run: run, value: value}
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp ensure_running(%{cancel_requested: true}, _run),
    do: {:error, "Case cancellation was requested"}

  defp ensure_running(%{status: :running}, %{status: :running}), do: :ok
  defp ensure_running(_incident, _run), do: {:error, "Case resolution is not running"}

  defp exhausted_limit(run, kind, amount, now) do
    cond do
      DateTime.compare(now, run.deadline_at) in [:eq, :gt] ->
        :elapsed

      run.no_progress_turns >= run.max_no_progress_turns ->
        :no_progress

      true ->
        case limit(kind) do
          nil ->
            nil

          {counter, maximum} ->
            if Map.fetch!(run, counter) + amount > Map.fetch!(run, maximum), do: kind
        end
    end
  end

  defp limit(:turn), do: {:turn_count, :max_resolver_turns}
  defp limit(:target_request), do: {:target_request_count, :max_target_requests}
  defp limit(:effect), do: {:effect_count, :max_effects}
  defp limit(:related_target), do: {:related_target_count, :max_related_targets}
  defp limit(:ai_usage), do: {:ai_usage_units, :max_ai_usage_units}
  defp limit(:no_progress), do: nil
  defp limit(:progress), do: nil

  defp next_counters(run, :progress, _amount) do
    run |> current_counters() |> Map.put(:no_progress_turns, 0)
  end

  defp next_counters(run, :no_progress, amount) do
    Map.update!(current_counters(run), :no_progress_turns, &(&1 + amount))
  end

  defp next_counters(run, kind, amount) do
    {counter, _maximum} = limit(kind)
    Map.update!(current_counters(run), counter, &(&1 + amount))
  end

  defp current_counters(run), do: Map.take(run, @counter_fields)

  defp event_data(opts, run, value) do
    base =
      opts
      |> Keyword.get(:event_data, %{})
      |> Map.merge(%{
        "kind" => to_string(opts[:kind]),
        "amount" => opts[:amount],
        "run_revision" => run.revision
      })

    case value do
      %{id: id} -> Map.put(base, "record_id", id)
      _other -> base
    end
  end

  defp create_event(incident, run, actor, event_type, key, data) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor && actor.id,
        event_type: event_type,
        idempotency_key: key,
        data: data
      },
      authorize?: false
    )
  end

  defp limit_reason(:elapsed), do: "Resolution elapsed-time limit exhausted"
  defp limit_reason(:turn), do: "Resolver turn limit exhausted"
  defp limit_reason(:target_request), do: "Target request limit exhausted"
  defp limit_reason(:effect), do: "Remote effect limit exhausted"
  defp limit_reason(:related_target), do: "Related Target limit exhausted"
  defp limit_reason(:ai_usage), do: "AI usage limit exhausted"
  defp limit_reason(:no_progress), do: "No-progress turn limit exhausted"
end
