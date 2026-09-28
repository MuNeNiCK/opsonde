defmodule Opsonde.Cases.Operation.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  import Ash.Expr
  require Ash.Query

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    Budget,
    Case,
    CaseAdmissionLock,
    CaseEvent,
    ConditionContext,
    Evidence,
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
           {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id),
           {:ok, affected_current?} <-
             ConditionContext.affected_current?(
               incident,
               proposal.request_kind,
               proposal.affected_conditions,
               proposal.evidence_ids,
               proposal,
               operation.id
             ) do
        if current? and affected_current? do
          with {:ok, conflict} <- effect_conflict(operation, proposal) do
            claim_after_conflict(operation, incident, run, conflict)
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

  defp claim_after_conflict(operation, _incident, _run, :clear) do
    with {:ok, claimed} <-
           Cases.mark_operation_dispatching(
             operation,
             operation.revision,
             %{dispatch_started_at: DateTime.utc_now()},
             authorize?: false
           ) do
      %OperationClaim{state: :claimed, operation: claimed}
    end
  end

  defp claim_after_conflict(operation, _incident, _run, {:busy, _prior}),
    do: %OperationClaim{state: :deferred, operation: operation}

  defp claim_after_conflict(operation, incident, run, {:changed, prior}) do
    stop_stale_dispatch(operation, incident, run, "target_effect_changed", %{
      "message" => "A prior Target effect requires a new observation before another effect",
      "prior_operation_id" => prior.id
    })
  end

  defp claim_after_conflict(operation, incident, run, {:unknown, prior}) do
    key = Budget.key("operation:unknown-prior-effect", operation.id)

    with {:ok, terminal} <-
           no_send(operation, "prior_effect_unknown", %{
             "message" => "A prior Target effect has an unknown result",
             "prior_operation_id" => prior.id
           }),
         {:ok, _attention} <-
           Cases.require_case_attention(
             incident.id,
             incident.revision,
             run.id,
             run.revision,
             key,
             "A prior Target effect has an unknown result",
             %{"action" => "review_target_effect", "prior_operation_id" => prior.id},
             "Observe the Target before approving another effect",
             authorize?: false
           ) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp effect_conflict(%{request_kind: :observation}, _proposal), do: {:ok, :clear}

  defp effect_conflict(operation, proposal) do
    with {:ok, active} <- conflicting_effect(operation, [:dispatching]),
         {:ok, prior} <- conflicting_effect(operation, [:applied, :partial, :failed, :unknown]) do
      cond do
        active -> {:ok, {:busy, active}}
        is_nil(prior) -> {:ok, :clear}
        fresh_observation?(proposal, operation, prior) -> {:ok, :clear}
        prior.status == :unknown -> {:ok, {:unknown, prior}}
        true -> {:ok, {:changed, prior}}
      end
    end
  end

  defp conflicting_effect(operation, statuses) do
    target = operation.target_id
    scope = operation.resource_scope

    query =
      Operation
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        expr(
          target_id == ^target and request_kind == :effect and
            status in ^statuses and
            (status != :failed or not is_nil(dispatch_started_at))
        )
      )

    query =
      if scope == "target" do
        query
      else
        Ash.Query.filter(
          query,
          expr(resource_scope in ^["target", scope])
        )
      end

    query
    |> Ash.Query.sort(
      completed_at: :desc_nils_last,
      dispatch_started_at: :desc_nils_last,
      id: :desc
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp fresh_observation?(proposal, operation, prior) do
    Enum.any?(proposal.evidence_ids, fn id ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok,
         %Evidence{
           case_id: case_id,
           kind: "observation",
           source: "operation",
           source_ref: source_ref,
           observed_at: observed_at,
           content: %{"status" => "applied", "target_id" => target_id}
         }}
        when case_id == operation.case_id and target_id == operation.target_id ->
          DateTime.compare(observed_at, prior.completed_at) == :gt and
            source_observation_current?(source_ref, operation, prior)

        _other ->
          false
      end
    end)
  end

  defp source_observation_current?(source_ref, operation, prior) do
    case Cases.get_operation(source_ref, authorize?: false) do
      {:ok,
       %{
         request_kind: :observation,
         status: :applied,
         target_id: target_id,
         case_id: case_id,
         resource_scope: scope,
         completed_at: completed_at
       }}
      when target_id == operation.target_id and case_id == operation.case_id ->
        DateTime.compare(completed_at, prior.completed_at) == :gt and
          (scope == "target" or
             (scope == operation.resource_scope and scope == prior.resource_scope))

      _other ->
        false
    end
  end

  defp stop_stale_dispatch(operation, incident, run) do
    stop_stale_dispatch(operation, incident, run, "source_context_changed", %{
      "message" => "Signal Conditions changed before Target dispatch"
    })
  end

  defp stop_stale_dispatch(operation, incident, run, category, details) do
    with {:ok, terminal} <-
           no_send(operation, category, details),
         {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             Budget.key("operation:context-changed", operation.id),
             %{
               "objective" => "Reassess the Target before another request",
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
    Cases.handoff_case_operation(
      incident,
      incident.revision,
      operation_id,
      :stale_dispatch,
      turn.id,
      nil,
      nil,
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
