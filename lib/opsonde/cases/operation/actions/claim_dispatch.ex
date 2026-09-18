defmodule Opsonde.Cases.Operation.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.Cases
  alias Opsonde.Cases.{Case, Operation, OperationClaim, ResolutionRun}

  @terminal [:applied, :failed, :partial, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source} <- Cases.get_operation(input.arguments.id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Operation], fn ->
        with {:ok, incident} <- lock(Case, source.case_id),
             {:ok, run} <- lock(ResolutionRun, source.resolution_run_id),
             {:ok, operation} <- lock(Operation, source.id) do
          claim(operation, incident, run)
        end
      end)
    end
  end

  defp claim(%{status: :queued} = operation, incident, run) do
    if incident.status == :running and not incident.cancel_requested and run.active and
         run.status == :running and run.generation == operation.case_generation do
      with {:ok, claimed} <-
             Cases.mark_operation_dispatching(
               operation,
               operation.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             ) do
        %OperationClaim{state: :claimed, operation: claimed}
      end
    else
      with {:ok, terminal} <-
             no_send(operation, "cancelled_before_dispatch", %{
               "message" => "Case stopped before the remote effect was dispatched"
             }) do
        %OperationClaim{state: :terminal, operation: terminal}
      end
    end
  end

  defp claim(%{status: :dispatching} = operation, _incident, _run) do
    with {:ok, terminal} <-
           complete(operation, :unknown, "dispatch_interrupted", %{
             "message" => "Dispatch ownership was lost after the durable send marker"
           }) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp claim(%{status: status} = operation, _incident, _run) when status in @terminal,
    do: %OperationClaim{state: :terminal, operation: operation}

  defp complete(operation, status, category, details) do
    Cases.record_operation_outcome(
      operation,
      operation.revision,
      %{
        status: status,
        outcome_category: category,
        result_details: details,
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp no_send(operation, category, details) do
    Cases.record_operation_no_send(
      operation,
      operation.revision,
      %{
        outcome_category: category,
        result_details: details,
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Operation dispatch input is unavailable"}
      result -> result
    end
  end
end
