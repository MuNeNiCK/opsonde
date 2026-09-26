defmodule Opsonde.Cases.Operation.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    Budget,
    Case,
    CaseAdmissionLock,
    CaseEvent,
    ConditionContext,
    Operation,
    OperationClaim,
    Proposal,
    ResolutionRun,
    Turn
  }

  @terminal [:applied, :failed, :partial, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source} <- Cases.get_operation(input.arguments.id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Operation, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock(Case, source.case_id),
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
      with {:ok, proposal} <- lock(Proposal, operation.proposal_id),
           {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
        if current? do
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
          stop_stale_dispatch(operation, incident, run)
        end
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

  defp stop_stale_dispatch(operation, incident, run) do
    with {:ok, terminal} <-
           no_send(operation, "source_context_changed", %{
             "message" => "Signal Conditions changed before Target dispatch"
           }),
         {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             Budget.key("operation:context-changed", operation.id),
             %{
               "objective" => "Reassess the Case before another Target request",
               "source_operation_id" => operation.id
             },
             %{"action" => "continue_resolution", "source_operation_id" => operation.id},
             "Review Resolver limits",
             authorize?: false
           ),
         {:ok, _pending} <- pending_after_context_change(started, operation.id) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp pending_after_context_change(%{status: :exhausted}, _operation_id),
    do: {:ok, :needs_attention}

  defp pending_after_context_change(%{status: status, case: incident, value: turn}, operation_id)
       when status in [:charged, :duplicate] do
    Cases.update_case_record(
      incident,
      incident.revision,
      %{
        pending_intent: %{
          "action" => "resolve_turn",
          "turn_id" => turn.id,
          "source_operation_id" => operation_id
        },
        stop_reason: nil,
        required_human_input: nil
      },
      authorize?: false
    )
  end

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
