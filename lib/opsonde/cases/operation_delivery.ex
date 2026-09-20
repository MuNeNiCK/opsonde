defmodule Opsonde.Cases.OperationDelivery do
  @moduledoc false

  alias Opsonde.{Accounts, Cases, Targets}
  alias Opsonde.Cases.{Operation, OperationClaim}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.{PolicyRequest, RequestClearance}

  @terminal [:applied, :failed, :partial, :unknown]

  def run(operation_id, opts \\ []) do
    case Cases.claim_operation_dispatch(operation_id, authorize?: false) do
      {:ok, %OperationClaim{state: :claimed, operation: operation}} ->
        dispatch(operation, opts)

      {:ok, %OperationClaim{state: :terminal, operation: operation}} ->
        handoff(operation)

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(operation, opts) do
    with {:ok, actor} <- current_actor(operation),
         {:ok, %RequestClearance{} = clearance} <-
           Targets.clear_target_request(request(operation), actor: actor),
         :ok <- exact_clearance(clearance, operation) do
      invocation = invocation(operation.case_id, Keyword.get(opts, :target_invocation, %{}))

      outcome = dispatch_target(operation, clearance, invocation, actor)

      persist_and_handoff(operation, outcome)
    else
      {:error, _error} ->
        persist_and_handoff(operation, %{
          status: :failed,
          category: "authorization_invalidated",
          reference: nil,
          details: %{"message" => "Operation authorization changed before dispatch"}
        })
    end
  end

  defp dispatch_target(%{request_kind: :observation}, clearance, invocation, actor) do
    case Targets.dispatch_target_observation(clearance, invocation,
           actor: actor,
           authorize?: false
         ) do
      {:ok, %ProviderTarget.Observation{} = result} -> normalize(result)
      {:error, error} -> failed_observation(error)
    end
  end

  defp dispatch_target(%{request_kind: :effect}, clearance, invocation, actor) do
    case Targets.dispatch_target_effect(clearance, invocation,
           actor: actor,
           authorize?: false
         ) do
      {:ok, %ProviderTarget.EffectResult{} = result} -> normalize(result)
      {:error, _error} -> unknown("dispatch_error", "Target dispatch result is unknown")
    end
  end

  defp persist_and_handoff(operation, outcome) do
    with {:ok, terminal} <-
           Cases.record_operation_outcome(
             operation,
             operation.revision,
             %{
               status: outcome.status,
               outcome_category: outcome.category,
               reference: outcome.reference,
               result_details: outcome.details,
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      handoff(terminal)
    end
  end

  defp normalize(%ProviderTarget.EffectResult{} = result) do
    %{
      status: result.status,
      category: "target_#{result.status}",
      reference: result.reference,
      details: result.details
    }
  end

  defp normalize(%ProviderTarget.Observation{} = result) do
    %{
      status: :applied,
      category: "target_observed",
      reference: nil,
      details: %{
        "facts" => result.facts,
        "evidence" => result.evidence,
        "observed_at" => DateTime.to_iso8601(result.observed_at)
      }
    }
  end

  defp failed_observation(error) do
    %{
      status: :failed,
      category: "observation_failed",
      reference: nil,
      details: %{"message" => Exception.message(error)}
    }
  rescue
    _error ->
      %{status: :failed, category: "observation_failed", reference: nil, details: %{}}
  end

  defp unknown(category, message) do
    %{status: :unknown, category: category, reference: nil, details: %{"message" => message}}
  end

  defp handoff(%Operation{status: status} = operation) when status in @terminal do
    case Cases.get_case(operation.case_id, authorize?: false) do
      {:ok, %{status: :running, cancel_requested: false}} -> handoff_running(operation)
      {:ok, _stopped} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp handoff(_operation), do: {:error, "Operation has no terminal outcome"}

  defp handoff_running(operation) do
    with {:ok, proposal} <- Cases.get_proposal(operation.proposal_id, authorize?: false),
         {:ok, evidence} <-
           Cases.append_evidence(
             operation.case_id,
             operation.resolution_run_id,
             evidence_turn_id(operation, proposal),
             "operation:outcome:#{operation.id}",
             evidence_kind(operation),
             "operation",
             operation.id,
             evidence_content(operation, proposal),
             operation.completed_at,
             authorize?: false
           ),
         {:ok, incident} <- Cases.get_case(operation.case_id, authorize?: false) do
      continue_handoff(operation, proposal, evidence, incident)
    end
  end

  defp continue_handoff(%{request_kind: :effect} = operation, _proposal, _evidence, incident) do
    case available_pending(incident.pending_intent, operation) do
      :ok ->
        with {:ok, _case} <-
               Cases.update_case_record(
                 incident,
                 incident.revision,
                 %{
                   pending_intent: %{
                     "action" => "verify_operation",
                     "operation_id" => operation.id,
                     "proposal_id" => operation.proposal_id
                   },
                   stop_reason: nil,
                   required_human_input: nil
                 },
                 authorize?: false
               ),
             :ok <- accept_verification(operation) do
          :ok
        end

      {:error, _error} = conflict ->
        case Cases.verification_attempt_by_operation(operation.id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Opsonde.Cases.VerificationAttempt{}} -> :ok
          _missing -> conflict
        end
    end
  end

  defp continue_handoff(
         %{request_kind: :observation} = operation,
         proposal,
         evidence,
         incident
       ) do
    with :ok <- available_pending(incident.pending_intent, operation),
         {:ok, result} <-
           Cases.start_turn(
             operation.case_id,
             operation.resolution_run_id,
             "operation:observation:next-turn:#{operation.id}",
             %{
               "objective" => "Continue resolution with the reviewed Target observation",
               "source" => "observation",
               "source_turn_id" => proposal.source_turn_id,
               "evidence_id" => evidence.id
             },
             %{"action" => "continue_resolution", "operation_id" => operation.id},
             "Review Resolver limits or continue the Case manually",
             authorize?: false
           ) do
      set_observation_pending(operation, proposal, evidence, incident, result)
    end
  end

  defp set_observation_pending(_operation, _proposal, _evidence, _incident, %{status: :exhausted}),
       do: :ok

  defp set_observation_pending(operation, proposal, evidence, incident, %{
         status: status,
         value: turn
       })
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => turn.id,
      "source_turn_id" => proposal.source_turn_id,
      "operation_id" => operation.id,
      "evidence_id" => evidence.id
    }

    case Cases.get_case(incident.id, authorize?: false) do
      {:ok, %{pending_intent: ^pending}} ->
        :ok

      {:ok, current} ->
        Cases.update_case_record(
          current,
          current.revision,
          %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
          authorize?: false
        )
        |> case do
          {:ok, _case} -> :ok
          {:error, _error} = error -> error
        end

      {:error, _error} = error ->
        error
    end
  end

  defp accept_verification(operation) do
    case Cases.accept_verification(operation.id, authorize?: false) do
      {:ok, _attempt} ->
        :ok

      {:error, error} ->
        case Cases.get_case(operation.case_id, authorize?: false) do
          {:ok, %{status: :needs_attention}} -> :ok
          _active -> {:error, error}
        end
    end
  end

  defp evidence_content(operation, proposal) do
    %{
      "status" => to_string(operation.status),
      "category" => operation.outcome_category,
      "reference" => operation.reference,
      "details" => operation.result_details,
      "facts" => operation.result_details["facts"] || %{},
      "tool_id" => proposal.tool_id,
      "target_id" => operation.target_id,
      "access_method_id" => operation.access_method_id
    }
  end

  defp evidence_kind(%{request_kind: :observation}), do: "observation"
  defp evidence_kind(%{request_kind: :effect}), do: "operation_outcome"

  defp evidence_turn_id(%{request_kind: :observation}, proposal), do: proposal.source_turn_id
  defp evidence_turn_id(%{request_kind: :effect}, _proposal), do: nil

  defp available_pending(%{"action" => "verify_operation", "operation_id" => id}, %{id: id}),
    do: :ok

  defp available_pending(%{"action" => "dispatch_operation", "operation_id" => id}, %{id: id}),
    do: :ok

  defp available_pending(pending, _operation) when map_size(pending) == 0, do: :ok
  defp available_pending(_pending, _operation), do: {:error, "Case has another pending action"}

  defp current_actor(operation) do
    case Accounts.get_user(operation.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == operation.actor_role_version ->
        {:ok, actor}

      _unavailable ->
        {:error, "Operation actor authority changed"}
    end
  end

  defp request(operation) do
    %PolicyRequest{
      kind: operation.request_kind,
      authority_mode: operation.authority_mode,
      target_id: operation.target_id,
      target_revision: operation.target_revision,
      access_method_id: operation.access_method_id,
      access_method_revision: operation.access_method_revision,
      capability: operation.capability,
      operation: operation.operation,
      selectors: operation.selectors,
      parameters: operation.parameters,
      operation_id: operation.id,
      idempotency_key: operation.idempotency_key,
      max_attempts: 1
    }
  end

  defp exact_clearance(clearance, operation) do
    digest = Base.encode16(clearance.digest, case: :lower)

    if clearance.provider_id == operation.provider_id and
         clearance.provider_revision == operation.provider_revision and
         digest == operation.authorization_digest,
       do: :ok,
       else: {:error, "Operation clearance changed"}
  end

  defp invocation(case_id, supplied) do
    supplied_cancelled = Map.get(supplied, :cancelled?)

    Map.put(supplied, :cancelled?, fn ->
      cancelled?(supplied_cancelled) or case_stopped?(case_id)
    end)
  end

  defp cancelled?(callback) when is_function(callback, 0), do: callback.()
  defp cancelled?(_callback), do: false

  defp case_stopped?(case_id) do
    case Cases.get_case(case_id, authorize?: false) do
      {:ok, %{status: :running, cancel_requested: false}} -> false
      _stopped -> true
    end
  end
end
