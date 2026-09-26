defmodule Opsonde.Cases.CaseDispatch.Actions.SendInitial do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Cases
  alias Opsonde.Cases.{Case, CaseAdmissionLock, CaseDispatch, ResolutionRun, Turn}

  @impl true
  def run(input, _opts, _context) do
    case_id = input.arguments.case_id

    result =
      Ash.transact([CaseDispatch, Case, ResolutionRun, Turn], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, dispatch} <- lock_dispatch(case_id) do
          send_if_due(dispatch)
        end
      end)

    case result do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp lock_dispatch(case_id) do
    CaseDispatch
    |> Ash.Query.for_read(:for_case, %{case_id: case_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp send_if_due(%{state: :disabled}), do: {:ok, %{status: :disabled}}
  defp send_if_due(%{state: :sent}), do: {:ok, %{status: :sent}}

  defp send_if_due(%{state: :collecting} = dispatch) do
    if DateTime.compare(DateTime.utc_now(), dispatch.due_at) == :lt do
      {:ok, %{status: :early, due_at: dispatch.due_at}}
    else
      with {:ok, incident} <- Cases.get_case(dispatch.case_id, authorize?: false),
           true <- incident.status == :running || {:error, "Case is not running"},
           {:ok, members} <-
             Cases.active_conditions_for_case(incident.id, authorize?: false),
           true <- members != [] || {:error, "Case has no active Conditions"},
           {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           {:ok, started} <-
             Cases.start_turn(
               incident.id,
               run.id,
               "signal-initial:#{incident.id}:#{run.generation}",
               %{"objective" => "Investigate all active Signal conditions"},
               %{"action" => "continue"},
               "Review Resolver limits",
               authorize?: false
             ),
           true <-
             started.status in [:charged, :duplicate, :exhausted] ||
               {:error, "Initial Resolver Turn was not accepted"},
           {:ok, _dispatch} <-
             Cases.record_case_dispatch_state(dispatch, dispatch.revision, %{state: :sent},
               authorize?: false
             ) do
        {:ok, %{status: :sent}}
      end
    end
  end
end
