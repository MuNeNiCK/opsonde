defmodule Opsonde.Cases.Case.Actions.DownstreamDecisionRoute do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.Cases
  alias Opsonde.Cases.{Budget, Case, CaseEvent, Evidence, Proposal, ResolutionRun, Turn}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source_turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Turn, Evidence, Proposal, CaseEvent], fn ->
        with {:ok, incident} <- lock_case(source_turn.case_id),
             {:ok, run} <- lock_run(source_turn.resolution_run_id, incident.id),
             {:ok, turn} <- lock_turn(source_turn.id, incident.id, run.id),
             {:ok, intent} <- downstream_intent(turn),
             :ok <- validate_intent(intent, incident, run) do
          route(turn, intent, incident, run)
        end
      end)
    end
  end

  defp route(turn, %{"type" => "handoff"} = intent, incident, run) do
    pending = pending_intent("provide_human_input", turn)
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay_handoff(incident, event, turn, intent, pending)
      else
        with :ok <- ensure_running(incident, run),
             :ok <- available_pending_intent(incident.pending_intent, pending) do
          Cases.require_case_attention(
            incident.id,
            incident.revision,
            run.id,
            run.revision,
            key,
            intent["reason"],
            pending,
            intent["required_input"],
            authorize?: false
          )
          |> action_value()
        end
      end
    end
  end

  defp route(turn, %{"type" => "proposal"} = intent, incident, run) do
    with {:ok, proposal} <- Cases.materialize_proposal(turn.id, authorize?: false) do
      pending = %{
        "action" => "route_proposal",
        "proposal_id" => proposal.id,
        "source_turn_id" => turn.id
      }

      persist_or_replay(turn, intent, incident, run, pending)
    end
  end

  defp route(turn, intent, incident, run) do
    pending = pending_intent("evaluate_recovery", turn)
    persist_or_replay(turn, intent, incident, run, pending)
  end

  defp persist_or_replay(turn, intent, incident, run, pending) do
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay(incident, event, turn, intent, pending)
      else
        persist(incident, run, turn, intent, pending, key)
      end
    end
  end

  defp persist(incident, run, turn, intent, pending, key) do
    with :ok <- ensure_running(incident, run),
         :ok <- available_pending_intent(incident.pending_intent, pending),
         {:ok, updated} <-
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
               event_type: "resolver_decision_routed",
               idempotency_key: key,
               data: event_data(turn, intent, pending)
             },
             authorize?: false
           ) do
      updated
    end
  end

  defp replay(incident, event, turn, intent, pending) do
    if event.event_type == "resolver_decision_routed" and
         event.resolution_run_id == turn.resolution_run_id and
         event.data == event_data(turn, intent, pending) do
      incident
    else
      {:error, "Resolver decision route was already used with different input"}
    end
  end

  defp replay_handoff(incident, event, turn, intent, pending) do
    expected = %{
      "reason" => intent["reason"],
      "pending_intent" => pending,
      "required_human_input" => intent["required_input"]
    }

    if event.event_type == "case_needs_attention" and
         event.resolution_run_id == turn.resolution_run_id and event.data == expected do
      incident
    else
      {:error, "Resolver decision route was already used with different input"}
    end
  end

  defp downstream_intent(%{
         status: :completed,
         result_digest: digest,
         result: %{"outcome" => "decision", "intent" => %{"type" => type} = intent}
       })
       when is_binary(digest) and type in ["proposal", "recovery_conclusion", "handoff"],
       do: {:ok, intent}

  defp downstream_intent(_turn),
    do: {:error, "Completed Turn does not contain a downstream Resolver decision"}

  defp validate_intent(%{"type" => "proposal"}, _incident, _run), do: :ok

  defp validate_intent(
         %{
           "type" => "recovery_conclusion",
           "reason" => reason,
           "evidence_ids" => evidence_ids
         },
         %{alert_state: :recovered} = incident,
         run
       )
       when is_binary(reason) and byte_size(reason) > 0 and byte_size(reason) <= 500 and
              is_list(evidence_ids) do
    valid_evidence(evidence_ids, incident.id, run.id)
  end

  defp validate_intent(
         %{
           "type" => "handoff",
           "reason" => reason,
           "required_input" => required_input
         },
         _incident,
         _run
       )
       when is_binary(reason) and byte_size(reason) > 0 and byte_size(reason) <= 500 and
              is_binary(required_input) and byte_size(required_input) > 0 and
              byte_size(required_input) <= 1_000,
       do: :ok

  defp validate_intent(_intent, _incident, _run),
    do: {:error, "Downstream Resolver decision is malformed"}

  defp valid_evidence(ids, case_id, run_id) do
    with :ok <- unique_ids(ids) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Cases.get_evidence(id, authorize?: false) do
          {:ok, %{case_id: ^case_id, resolution_run_id: ^run_id}} -> {:cont, :ok}
          _unavailable -> {:halt, {:error, "Resolver decision cites unavailable Evidence"}}
        end
      end)
    end
  end

  defp unique_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) and
         length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      {:error, "Resolver decision Evidence identities are invalid"}
    end
  end

  defp unique_ids(_ids), do: {:error, "Resolver decision Evidence identities are invalid"}

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

  defp lock_turn(id, case_id, run_id) do
    Turn
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Resolver Turn is unavailable")
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp ensure_running(%{status: :running, cancel_requested: false}, %{status: :running}), do: :ok

  defp ensure_running(%{cancel_requested: true}, _run),
    do: {:error, "Case cancellation was requested"}

  defp ensure_running(_incident, _run), do: {:error, "Case resolution is not running"}

  defp available_pending_intent(current, _pending) when map_size(current) == 0, do: :ok
  defp available_pending_intent(pending, pending), do: :ok

  defp available_pending_intent(_current, _pending),
    do: {:error, "Case already has another pending decision"}

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp event_data(turn, intent, pending) do
    %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "intent_type" => intent["type"],
      "pending_intent" => pending
    }
  end

  defp pending_intent(action, turn),
    do: %{"action" => action, "source_turn_id" => turn.id}

  defp route_key(turn), do: Budget.key("resolver-route:downstream", turn.id)

  defp action_value({:ok, value}), do: value
  defp action_value({:error, _error} = error), do: error
end
