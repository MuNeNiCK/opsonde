defmodule Opsonde.Cases.DecisionRouteWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Opsonde.Cases
  alias Opsonde.Cases.Budget
  alias Opsonde.Reports.GenerationWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => turn_id}}) when is_binary(turn_id) do
    case route(turn_id) do
      {:ok, %{status: :resolved} = incident} -> enqueue_report(incident)
      {:ok, _result} -> :ok
      {:error, error} -> require_attention(turn_id, error)
    end
  end

  def perform(_job), do: {:cancel, "Resolver decision route arguments are invalid"}

  defp route(turn_id) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, type} <- decision_type(turn) do
      dispatch(type, turn.id)
    end
  end

  defp dispatch(type, turn_id) when type in ["target_search", "target_selection"],
    do: Cases.route_target_discovery(turn_id, authorize?: false)

  defp dispatch("target_traversal", turn_id),
    do: Cases.route_related_target(turn_id, authorize?: false)

  defp dispatch(type, turn_id)
       when type in ["proposal", "recovery_conclusion", "handoff"],
       do: Cases.route_downstream_decision(turn_id, authorize?: false)

  defp enqueue_report(incident) do
    %{"case_id" => incident.id, "case_revision" => incident.revision}
    |> GenerationWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, error} -> {:error, error}
    end
  end

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
