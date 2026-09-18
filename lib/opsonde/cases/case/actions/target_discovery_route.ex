defmodule Opsonde.Cases.Case.Actions.TargetDiscoveryRoute do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Cases
  alias Opsonde.Cases.{Case, CaseEvent, Evidence, ResolutionRun, Turn}

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, ResolutionRun, Turn, Evidence, CaseEvent], fn ->
      with {:ok, turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false),
           :ok <- completed_decision(turn),
           {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
           {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
        route(turn, incident, run, turn.result["intent"])
      end
    end)
  end

  defp route(
         turn,
         incident,
         run,
         %{"type" => "target_search", "query" => query, "reason" => reason}
       )
       when is_binary(query) and is_binary(reason) do
    pending = %{"action" => "route_target_search", "source_turn_id" => turn.id}

    with {:ok, searched} <-
           Cases.search_case_targets(
             incident.id,
             run.id,
             route_key(turn, "target-search"),
             query,
             20,
             pending,
             "Review Target discovery or increase its limit",
             authorize?: false
           ) do
      continue_after_search(turn, reason, searched) |> action_value()
    end
  end

  defp route(
         turn,
         incident,
         run,
         %{
           "type" => "target_selection",
           "target_id" => target_id,
           "target_revision" => target_revision,
           "evidence_ids" => evidence_ids,
           "reason" => reason
         }
       )
       when is_binary(target_id) and is_integer(target_revision) and is_list(evidence_ids) and
              is_binary(reason) do
    with {:ok, selected} <-
           Cases.select_case_target(
             incident.id,
             incident.revision,
             run.id,
             evidence_ids,
             target_id,
             target_revision,
             reason,
             route_key(turn, "target-selection"),
             authorize?: false
           ) do
      start_next_turn(turn, selected, run, %{
        "source" => "target_selection",
        "selected_target_id" => target_id,
        "reason" => reason
      })
      |> action_value()
    end
  end

  defp route(_turn, _incident, _run, _intent),
    do: {:error, "Completed Turn does not contain a Target discovery decision"}

  defp continue_after_search(_turn, _reason, %{status: :exhausted} = result), do: {:ok, result}

  defp continue_after_search(turn, reason, searched) do
    start_next_turn(turn, searched.case, searched.run, %{
      "source" => "target_search",
      "evidence_id" => searched.value.id,
      "reason" => reason
    })
  end

  defp start_next_turn(turn, incident, run, context) do
    Cases.start_turn(
      incident.id,
      run.id,
      route_key(turn, "next-turn"),
      Map.put(context, "objective", "Continue resolution with the accepted Target discovery"),
      %{"action" => "continue_resolution", "source_turn_id" => turn.id},
      "Review Resolver limits or continue the Case manually",
      authorize?: false
    )
  end

  defp action_value({:ok, value}), do: value
  defp action_value({:error, _error} = error), do: error

  defp completed_decision(%{
         status: :completed,
         result: %{"outcome" => "decision", "intent" => intent}
       })
       when is_map(intent),
       do: :ok

  defp completed_decision(_turn),
    do: {:error, "Target discovery requires a completed Resolver decision"}

  defp route_key(turn, kind), do: "resolver-route:#{turn.id}:#{kind}"
end
