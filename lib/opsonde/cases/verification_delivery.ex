defmodule Opsonde.Cases.VerificationDelivery do
  @moduledoc false

  alias Opsonde.{Accounts, Cases, Targets}
  alias Opsonde.Cases.{VerificationAttempt, VerificationClaim}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.{PolicyRequest, RequestClearance}

  @terminal [:verified, :not_verified, :unknown]

  def run(attempt_id, opts \\ []) do
    case Cases.claim_verification_dispatch(attempt_id, authorize?: false) do
      {:ok, %VerificationClaim{state: :claimed, attempt: attempt}} ->
        dispatch(attempt, opts)

      {:ok, %VerificationClaim{state: :terminal, attempt: attempt}} ->
        handoff(attempt)

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(attempt, opts) do
    with {:ok, actor} <- current_actor(attempt),
         {:ok, %RequestClearance{} = clearance} <-
           Targets.clear_target_request(request(attempt), actor: actor),
         :ok <- exact_clearance(clearance, attempt) do
      invocation = invocation(attempt.case_id, Keyword.get(opts, :target_invocation, %{}))

      outcome =
        case Targets.dispatch_target_verification(clearance, invocation,
               actor: actor,
               authorize?: false
             ) do
          {:ok, %ProviderTarget.Verification{} = result} ->
            normalize(result)

          {:error, _error} ->
            unknown("verification_error", "Fresh verification result is unknown")
        end

      persist_and_handoff(attempt, outcome)
    else
      {:error, _error} ->
        persist_and_handoff(
          attempt,
          unknown(
            "authorization_invalidated",
            "Verification authorization changed before Target dispatch"
          )
        )
    end
  end

  defp persist_and_handoff(attempt, outcome) do
    with {:ok, terminal} <-
           Cases.record_verification_outcome(
             attempt,
             attempt.revision,
             %{
               status: outcome.status,
               outcome_category: outcome.category,
               facts: outcome.facts,
               provider_evidence: %{"items" => outcome.evidence},
               observed_at: outcome.observed_at,
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      handoff(terminal)
    end
  end

  defp normalize(%ProviderTarget.Verification{} = result) do
    %{
      status: result.status,
      category: "target_#{result.status}",
      facts: result.facts,
      evidence: result.evidence,
      observed_at: result.observed_at
    }
  end

  defp unknown(category, message) do
    %{
      status: :unknown,
      category: category,
      facts: %{},
      evidence: [%{"message" => message}],
      observed_at: DateTime.utc_now()
    }
  end

  defp handoff(%VerificationAttempt{status: status} = attempt) when status in @terminal do
    case Cases.get_case(attempt.case_id, authorize?: false) do
      {:ok, %{status: :running, cancel_requested: false}} -> handoff_running(attempt)
      {:ok, _stopped} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp handoff(_attempt), do: {:error, "VerificationAttempt has no terminal outcome"}

  defp handoff_running(attempt) do
    with {:ok, evidence} <-
           Cases.append_evidence(
             attempt.case_id,
             attempt.resolution_run_id,
             nil,
             "verification:outcome:#{attempt.id}",
             "target_verification",
             "verification",
             attempt.id,
             evidence_content(attempt),
             attempt.observed_at,
             authorize?: false
           ),
         {:ok, incident} <- Cases.get_case(attempt.case_id, authorize?: false) do
      continue_handoff(attempt, evidence, incident)
    end
  end

  defp continue_handoff(attempt, evidence, incident) do
    case available_pending(incident.pending_intent, attempt) do
      :ok ->
        with {:ok, _case} <-
               Cases.update_case_record(
                 incident,
                 incident.revision,
                 %{
                   pending_intent: %{
                     "action" => "evaluate_verification",
                     "verification_attempt_id" => attempt.id,
                     "verification_evidence_id" => evidence.id,
                     "operation_id" => attempt.operation_id
                   },
                   stop_reason: nil,
                   required_human_input: nil
                 },
                 authorize?: false
               ),
             :ok <- evaluate(attempt) do
          :ok
        end

      {:error, _error} = conflict ->
        case Cases.turn_by_idempotency(
               attempt.resolution_run_id,
               "verification-assessment:#{attempt.id}",
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Opsonde.Cases.Turn{}} -> :ok
          _missing -> conflict
        end
    end
  end

  defp evaluate(attempt) do
    case Cases.evaluate_verification(attempt.id, authorize?: false) do
      {:ok, _turn} ->
        :ok

      {:error, error} ->
        case Cases.get_case(attempt.case_id, authorize?: false) do
          {:ok, %{status: :needs_attention}} -> :ok
          _active -> {:error, error}
        end
    end
  end

  defp evidence_content(attempt) do
    %{
      "status" => to_string(attempt.status),
      "category" => attempt.outcome_category,
      "facts" => attempt.facts,
      "provider_evidence" => attempt.provider_evidence,
      "expected" => attempt.expected,
      "operation_id" => attempt.operation_id,
      "target_id" => attempt.target_id,
      "access_method_id" => attempt.access_method_id
    }
  end

  defp available_pending(
         %{"action" => "evaluate_verification", "verification_attempt_id" => id},
         %{id: id}
       ),
       do: :ok

  defp available_pending(
         %{"action" => "resolve_turn", "verification_attempt_id" => id},
         %{id: id}
       ),
       do: :ok

  defp available_pending(%{"action" => "verify_operation", "operation_id" => operation_id}, %{
         operation_id: operation_id
       }),
       do: :ok

  defp available_pending(_pending, _attempt),
    do: {:error, "Case has another pending action"}

  defp current_actor(attempt) do
    case Accounts.get_user(attempt.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == attempt.actor_role_version ->
        {:ok, actor}

      _unavailable ->
        {:error, "Verification actor authority changed"}
    end
  end

  defp request(attempt) do
    %PolicyRequest{
      kind: :verification,
      authority_mode: attempt.authority_mode,
      target_id: attempt.target_id,
      target_revision: attempt.target_revision,
      access_method_id: attempt.access_method_id,
      access_method_revision: attempt.access_method_revision,
      capability: attempt.capability,
      operation: attempt.operation,
      selectors: attempt.selectors,
      parameters: attempt.parameters,
      operation_id: attempt.operation_id,
      reference: attempt.operation_reference,
      expected: attempt.expected,
      max_attempts: 1
    }
  end

  defp exact_clearance(clearance, attempt) do
    digest = Base.encode16(clearance.digest, case: :lower)

    if clearance.provider_id == attempt.provider_id and
         clearance.provider_revision == attempt.provider_revision and
         digest == attempt.authorization_digest,
       do: :ok,
       else: {:error, "Verification clearance changed"}
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
