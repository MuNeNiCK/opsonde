defmodule Opsonde.Cases.DecisionRouteWorker do
  @moduledoc false
  require Ash.Query

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    Budget,
    Case,
    CaseAdmissionLock,
    CaseEvent,
    ResolutionRun,
    ResolverProjection,
    Turn
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => turn_id}}) when is_binary(turn_id) do
    case route(turn_id) do
      {:ok, _result} -> :ok
      {:error, error} -> require_attention(turn_id, error)
    end
  end

  def perform(_job), do: {:cancel, "Resolver decision route arguments are invalid"}

  defp route(turn_id) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
           {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
        with {:ok, superseded?} <- superseded_by_split?(turn) do
          if superseded? do
            {:ok, :superseded}
          else
            with {:ok, type} <- decision_type(turn) do
              case current_conditions?(incident, turn) do
                {:ok, true} -> dispatch(type, turn.id)
                {:ok, false} -> supersede_stale_route(turn)
                {:error, _error} = error -> error
              end
            end
          end
        end
      end
    end)
    |> case do
      {:ok, {:ok, _result} = result} -> result
      {:ok, {:error, _error} = error} -> error
      other -> other
    end
  end

  defp superseded_by_split?(turn) do
    CaseEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(case_id == ^turn.case_id and event_type == "case_conditions_split_out")
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:ok, false}

      {:ok, event} ->
        {:ok,
         event.resolution_run_id == turn.resolution_run_id and
           is_integer(event.data["turn_ordinal_boundary"]) and
           turn.ordinal <= event.data["turn_ordinal_boundary"]}

      {:error, _error} = error ->
        error
    end
  end

  defp current_conditions?(%{trigger_kind: :signal} = incident, turn) do
    with {:ok, current} <- ResolverProjection.current_condition_revisions(incident) do
      {:ok, current == turn.result["condition_revisions"]}
    end
  end

  defp current_conditions?(_incident, _turn), do: {:ok, true}

  defp supersede_stale_route(turn) do
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    with {:ok, started} <-
           Cases.start_turn(
             turn.case_id,
             turn.resolution_run_id,
             "resolver:route-context-changed:#{turn.id}",
             %{
               "objective" => "Reassess the Case with current Conditions",
               "source_turn_id" => turn.id
             },
             intent,
             "Review Resolver limits",
             authorize?: false
           ),
         {:ok, _pending} <- set_retry_pending(started, turn.id) do
      {:ok, started}
    end
  end

  defp set_retry_pending(%{status: :exhausted} = result, _source_turn_id),
    do: {:ok, result}

  defp set_retry_pending(%{status: status, case: incident, value: next_turn} = result, source_id)
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => next_turn.id,
      "source_turn_id" => source_id
    }

    if incident.pending_intent == pending do
      {:ok, result}
    else
      with :ok <- available_pending_turn(incident.pending_intent, source_id) do
        Cases.update_case_record(
          incident,
          incident.revision,
          %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
          authorize?: false
        )
      end
    end
  end

  defp available_pending_turn(%{"action" => action, "turn_id" => source_id}, source_id)
       when action in ["resolve_turn", "route_resolver_decision"],
       do: :ok

  defp available_pending_turn(current, _source_id) when map_size(current) == 0, do: :ok

  defp available_pending_turn(_current, _source_id),
    do: {:error, "Case already has another pending decision"}

  defp dispatch(type, turn_id) when type in ["target_search", "target_selection"],
    do: Cases.route_target_discovery(turn_id, authorize?: false)

  defp dispatch("target_traversal", turn_id),
    do: Cases.route_related_target(turn_id, authorize?: false)

  defp dispatch(type, turn_id)
       when type in ["proposal", "recovery_conclusion", "handoff"],
       do: Cases.route_downstream_decision(turn_id, authorize?: false)

  defp decision_type(%{
         status: :completed,
         result: %{"outcome" => "decision", "intent" => %{"type" => type}}
       })
       when type in [
              "target_search",
              "target_selection",
              "target_traversal",
              "proposal",
              "recovery_conclusion",
              "handoff"
            ],
       do: {:ok, type}

  defp decision_type(_turn), do: {:error, :malformed_decision}

  defp require_attention(turn_id, route_error) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      if incident.status == :running and run.active and run.status == :running do
        pending = pending_intent(incident.pending_intent, turn.id)

        case Cases.require_case_attention(
               incident.id,
               incident.revision,
               run.id,
               run.revision,
               Budget.key("resolver-route:failure", turn.id),
               "Resolver decision routing failed",
               pending,
               "Review the persisted Resolver decision and resume the Case",
               authorize?: false
             ) do
          {:ok, _updated} -> :ok
          {:error, attention_error} -> {:error, attention_error}
        end
      else
        route_failure(route_error, incident)
      end
    end
  end

  defp pending_intent(current, turn_id) when map_size(current) == 0,
    do: %{"action" => "review_resolver_route", "source_turn_id" => turn_id}

  defp pending_intent(current, _turn_id), do: current

  defp route_failure(_error, %{status: :needs_attention}), do: :ok
  defp route_failure(_error, %{status: :cancelled}), do: {:cancel, "Case was cancelled"}
  defp route_failure(error, _incident), do: {:error, error}
end
