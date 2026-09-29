defmodule Opsonde.Cases.Operation.Delivery do
  @moduledoc false

  alias Opsonde.{Accounts, Cases, Targets}

  alias Opsonde.Cases.{
    Case,
    CaseEvent,
    Operation,
    ResolutionRun,
    Turn
  }

  alias Opsonde.Cases.Operation.Claim, as: OperationClaim
  alias Opsonde.Cases.ResolutionRun.Budget, as: Budget
  alias Opsonde.Cases.ResolutionRun.BudgetResult

  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.TargetRequest.{Request, Clearance}

  @terminal [:applied, :failed, :partial, :unknown]

  def run(operation_id, opts \\ []) do
    case Cases.claim_operation_dispatch(operation_id, authorize?: false) do
      {:ok, %OperationClaim{state: :claimed, operation: operation}} ->
        dispatch(operation, opts)

      {:ok, %OperationClaim{state: :deferred}} ->
        {:snooze, 5}

      {:ok, %OperationClaim{state: :terminal, operation: operation}} ->
        handoff(operation)

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(operation, opts) do
    with {:ok, actor} <- current_actor(operation),
         {:ok, %Clearance{} = clearance} <-
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
    details = %{
      "facts" => result.facts,
      "evidence" => result.evidence,
      "observed_at" => DateTime.to_iso8601(result.observed_at)
    }

    %{
      status: :applied,
      category: "target_observed",
      reference: nil,
      details:
        if(result.state_facts,
          do: Map.put(details, "state_facts", result.state_facts),
          else: details
        )
    }
  end

  defp failed_observation(error) do
    %{
      status: :failed,
      category: "observation_failed",
      reference: nil,
      details:
        %{"message" => observation_failure_message(error)}
        |> maybe_put_provider_category(observation_failure_category(error))
    }
  rescue
    _error ->
      %{status: :failed, category: "observation_failed", reference: nil, details: %{}}
  end

  defp observation_failure_message(%ProviderTarget.Error{message: message}), do: message

  defp observation_failure_message(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &target_error_message/1) || "Target observation failed"
  end

  defp observation_failure_message(error), do: Exception.message(error)

  defp observation_failure_category(%ProviderTarget.Error{category: category}),
    do: category

  defp observation_failure_category(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &observation_failure_category/1)

  defp observation_failure_category(_error), do: nil

  defp maybe_put_provider_category(details, category)
       when category in [:retryable, :timeout, :failed, :cancelled],
       do: Map.put(details, "provider_category", Atom.to_string(category))

  defp maybe_put_provider_category(details, _category), do: details

  defp target_error_message(%ProviderTarget.Error{message: message}), do: message

  defp target_error_message(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &target_error_message/1)

  defp target_error_message(_error), do: nil

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
         {:ok, progress} <- account_observation_progress(operation),
         {:ok, incident} <- Cases.get_case(operation.case_id, authorize?: false) do
      if progress == :exhausted or incident.status != :running,
        do: :ok,
        else: continue_handoff(operation, proposal, evidence, incident)
    end
  end

  defp account_observation_progress(%Operation{request_kind: :observation} = operation) do
    case Cases.account_observation_progress(operation.id, authorize?: false) do
      {:ok, %BudgetResult{status: :exhausted}} ->
        {:ok, :exhausted}

      {:ok, %BudgetResult{status: status}} when status in [:charged, :duplicate] ->
        {:ok, :continue}

      {:error, _error} = error ->
        error
    end
  end

  defp account_observation_progress(_operation), do: {:ok, :continue}

  defp continue_handoff(
         %{outcome_category: category} = operation,
         _proposal,
         _evidence,
         incident
       )
       when category in ["source_context_changed", "target_effect_changed"] do
    if incident.pending_intent["source_operation_id"] == operation.id and
         incident.pending_intent["action"] == "resolve_turn",
       do: :ok,
       else: {:error, "Stale Operation has no reassessment Turn"}
  end

  defp continue_handoff(
         %{outcome_category: "authorization_invalidated"} = operation,
         _proposal,
         _evidence,
         incident
       ) do
    with {:ok, target} <- Targets.get_target(operation.target_id, authorize?: false),
         true <- target.active and incident.selected_target_id == target.id,
         {:ok, current} <- refresh_selected_target(incident, target),
         {:ok, run} <- Cases.get_resolution_run(operation.resolution_run_id, authorize?: false),
         {:ok, started} <-
           Cases.start_turn(
             current.id,
             run.id,
             Budget.key("operation:authorization-changed", operation.id),
             %{
               "objective" => "Reassess this Target under its current operating instructions",
               "source_operation_id" => operation.id
             },
             %{"action" => "continue_resolution", "source_operation_id" => operation.id},
             "Review Resolver limits",
             authorize?: false
           ) do
      case started do
        %{status: :exhausted} ->
          :ok

        %{status: status, case: updated, value: turn} when status in [:charged, :duplicate] ->
          case Cases.handoff_case_operation(
                 updated,
                 updated.revision,
                 operation.id,
                 :stale_dispatch,
                 turn.id,
                 nil,
                 nil,
                 authorize?: false
               ) do
            {:ok, _case} -> :ok
            {:error, _error} = error -> error
          end
      end
    else
      false -> {:error, "Target changed before Operation reassessment"}
      {:error, _error} = error -> error
    end
  end

  defp continue_handoff(%{request_kind: :effect} = operation, _proposal, _evidence, incident) do
    pending = %{
      "action" => "verify_operation",
      "operation_id" => operation.id,
      "proposal_id" => operation.proposal_id
    }

    result =
      if incident.pending_intent == pending do
        {:ok, incident}
      else
        Cases.handoff_case_operation(
          incident,
          incident.revision,
          operation.id,
          :verification,
          nil,
          nil,
          nil,
          authorize?: false
        )
      end

    case result do
      {:ok, _case} ->
        accept_verification(operation)

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
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, source_turn} <- Cases.get_turn(proposal.source_turn_id, authorize?: false),
           {:ok, result} <-
             Cases.start_turn(
               operation.case_id,
               operation.resolution_run_id,
               "operation:observation:next-turn:#{operation.id}",
               observation_turn_intent(source_turn, evidence),
               %{"action" => "continue_resolution", "operation_id" => operation.id},
               "Review Resolver limits or continue the Case manually",
               authorize?: false
             ) do
        set_observation_pending(operation, proposal, evidence, incident, result)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp refresh_selected_target(%{selected_target_revision: revision} = incident, %{
         revision: revision
       }),
       do: {:ok, incident}

  defp refresh_selected_target(incident, target) do
    Cases.record_case_selected_target(
      incident,
      incident.revision,
      target.id,
      target.revision,
      authorize?: false
    )
  end

  defp observation_turn_intent(source_turn, evidence) do
    intent = %{
      "objective" => "Continue resolution with the reviewed Target observation",
      "source" => "observation",
      "source_turn_id" => source_turn.id,
      "evidence_id" => evidence.id
    }

    case source_turn.intent do
      %{"source" => "target_relationship", "relationship_id" => relationship_id} ->
        Map.put(intent, "prior_relationship_id", relationship_id)

      _other ->
        intent
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
        Cases.handoff_case_operation(
          current,
          current.revision,
          operation.id,
          :observation,
          turn.id,
          proposal.source_turn_id,
          evidence.id,
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
      "request_kind" => to_string(operation.request_kind),
      "capability" => operation.capability,
      "operation" => operation.operation,
      "selectors" => operation.selectors,
      "parameters" => operation.parameters,
      "details" => operation.result_details,
      "facts" => operation.result_details["facts"] || %{},
      "tool_id" => proposal.tool_id,
      "target_id" => operation.target_id,
      "access_method_id" => operation.access_method_id,
      "access_method_revision" => operation.access_method_revision
    }
  end

  defp evidence_kind(%{request_kind: :observation}), do: "observation"
  defp evidence_kind(%{request_kind: :effect}), do: "operation_outcome"

  defp evidence_turn_id(%{request_kind: :observation}, proposal), do: proposal.source_turn_id
  defp evidence_turn_id(%{request_kind: :effect}, _proposal), do: nil

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
    %Request{
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
