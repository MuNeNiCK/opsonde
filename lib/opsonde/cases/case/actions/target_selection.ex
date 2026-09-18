defmodule Opsonde.Cases.Case.Actions.TargetSelection do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.{Cases, Targets}
  alias Opsonde.Cases.{Budget, Case, CaseEvent, Evidence, ResolutionRun}

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    key = Budget.key("case:target_selection", arguments.idempotency_key)

    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent], fn ->
      with {:ok, incident} <- lock_case(arguments.id),
           {:ok, event} <- existing_event(incident.id, key) do
        if event do
          replay(incident, event, arguments)
        else
          select(incident, arguments, context.actor, key)
        end
      end
    end)
  end

  defp select(incident, arguments, actor, key) do
    with :ok <- expected_revision(incident, arguments.expected_revision),
         :ok <- ensure_running(incident),
         {:ok, run} <- lock_run(arguments.resolution_run_id, incident.id),
         :ok <- unique_evidence(arguments.evidence_ids),
         {:ok, evidence} <- load_evidence(arguments.evidence_ids),
         :ok <- valid_evidence(evidence, incident.id, run.id),
         :ok <- offered_candidate(evidence, arguments.target_id, arguments.target_revision),
         {:ok, target} <- Targets.get_target(arguments.target_id, authorize?: false),
         :ok <- current_target(target, arguments.target_revision),
         {:ok, updated} <-
           Cases.update_case_record(
             incident,
             arguments.expected_revision,
             %{
               selected_target_id: target.id,
               selected_target_revision: target.revision
             },
             authorize?: false
           ),
         {:ok, _event} <- create_event(updated, incident, run, actor, key, arguments) do
      updated
    end
  end

  defp replay(incident, event, arguments) do
    expected = event_data(arguments)

    if Map.take(event.data, Map.keys(expected)) == expected do
      incident
    else
      {:error, "Target-selection idempotency key was already used with different input"}
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
    |> Ash.Query.filter(id: id, case_id: case_id, active: true, status: :running)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Running ResolutionRun is unavailable")
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp expected_revision(%{revision: revision}, revision), do: :ok
  defp expected_revision(_incident, _revision), do: {:error, "Case revision changed"}

  defp ensure_running(%{cancel_requested: false, status: :running}), do: :ok
  defp ensure_running(%{cancel_requested: true}), do: {:error, "Case cancellation was requested"}
  defp ensure_running(_incident), do: {:error, "Case resolution is not running"}

  defp unique_evidence(ids) do
    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, "Target selection evidence contains duplicates"}
  end

  defp load_evidence(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | items]}}
        {:error, _error} -> {:halt, {:error, "Target selection evidence is unavailable"}}
      end
    end)
  end

  defp valid_evidence(evidence, case_id, run_id) do
    if Enum.all?(evidence, &(&1.case_id == case_id and &1.resolution_run_id == run_id)),
      do: :ok,
      else: {:error, "Target selection evidence belongs to another Case or ResolutionRun"}
  end

  defp offered_candidate(evidence, target_id, target_revision) do
    offered? =
      Enum.any?(evidence, fn
        %{
          kind: "target_candidates",
          source: "target_catalog",
          content: %{"targets" => candidates}
        }
        when is_list(candidates) ->
          Enum.any?(candidates, fn candidate ->
            candidate["id"] == target_id and candidate["revision"] == target_revision
          end)

        _other ->
          false
      end)

    if offered? do
      :ok
    else
      {:error, "Target was not offered by the cited candidate evidence"}
    end
  end

  defp current_target(%{active: true, revision: revision}, revision), do: :ok
  defp current_target(%{active: false}, _revision), do: {:error, "Selected Target is inactive"}
  defp current_target(_target, _revision), do: {:error, "Selected Target revision changed"}

  defp create_event(incident, prior, run, actor, key, arguments) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor && actor.id,
        event_type: "case_target_selected",
        idempotency_key: key,
        data:
          event_data(arguments)
          |> Map.put("prior_target_id", prior.selected_target_id)
          |> Map.put("prior_target_revision", prior.selected_target_revision)
      },
      authorize?: false
    )
  end

  defp event_data(arguments) do
    %{
      "evidence_ids" => arguments.evidence_ids,
      "target_id" => arguments.target_id,
      "target_revision" => arguments.target_revision,
      "reason" => arguments.reason
    }
  end
end
