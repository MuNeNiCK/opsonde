defmodule Opsonde.Cases.Turn.RecoveryReviewDelivery do
  @moduledoc false

  alias Opsonde.{Cases, Providers}

  alias Opsonde.Cases.{AIInvocation, Case, CaseEvent, ResolutionRun, Turn}
  alias Opsonde.Cases.Turn.RecoveryReviewFingerprint, as: RecoveryReviewFingerprint

  alias Opsonde.Cases.ResolutionRun.Budget, as: Budget

  alias Opsonde.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  alias Opsonde.Cases.AIInvocation.Claim, as: AIInvocationClaim
  alias Opsonde.Cases.ResolutionRun.BudgetResult

  alias Opsonde.Providers.AI

  def run(turn_id, opts \\ []) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, event} <- result_event(turn) do
      if event do
        apply_result(turn, event)
      else
        deliver(turn, opts)
      end
    end
  end

  defp deliver(turn, opts) do
    with {:ok, selection} <- selection(turn),
         {:ok, selection} <- current_selection(selection),
         {:ok, retry_context} <- retry_context(turn),
         {:ok, request} <-
           Opsonde.Cases.Turn.RecoveryReviewProjection.build(
             turn.id,
             selection,
             retry_context
           ),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, %AIInvocationClaim{} = claim} <-
           claim(turn, incident, selection, request, delivery_attempt(opts)) do
      dispatch(turn, selection, request, claim, opts)
    else
      {:error, error} -> attention(turn, "Recovery Reviewer is unavailable", error)
    end
  end

  defp current_selection(%AI.Selection{source: :assignment} = selection) do
    case Providers.load_current_ai_usage_role_assignment(
           selection.assignment_id,
           :reviewer,
           selection.assignment_revision,
           selection.provider_revision,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{provider_id: provider_id}} when provider_id == selection.provider_id ->
        {:ok, selection}

      {:ok, _changed} ->
        {:error, "Recovery Reviewer assignment changed"}

      {:error, _error} ->
        {:error, "Recovery Reviewer assignment is unavailable"}
    end
  end

  defp current_selection(_selection), do: {:error, "Recovery Reviewer assignment is invalid"}

  defp selection(turn) do
    key = Budget.key("recovery-review:assignment", turn.id)

    case Cases.case_event_by_idempotency(turn.case_id, key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %CaseEvent{} = event} ->
        persisted_selection(turn, event)

      {:ok, nil} ->
        with {:ok, %AI.Selection{role: :reviewer, source: :assignment} = selection} <-
               Providers.select_reviewer_ai([], authorize?: false),
             {:ok, _event} <-
               Cases.create_case_event_record(
                 %{
                   case_id: turn.case_id,
                   resolution_run_id: turn.resolution_run_id,
                   event_type: "recovery_reviewer_assigned",
                   idempotency_key: key,
                   data: %{
                     "turn_id" => turn.id,
                     "provider_id" => selection.provider_id,
                     "provider_revision" => selection.provider_revision,
                     "assignment_id" => selection.assignment_id,
                     "assignment_revision" => selection.assignment_revision
                   }
                 },
                 authorize?: false
               ) do
          {:ok, selection}
        end

      error ->
        error
    end
  end

  defp persisted_selection(turn, event) do
    data = event.data

    if event.event_type == "recovery_reviewer_assigned" and
         event.resolution_run_id == turn.resolution_run_id and data["turn_id"] == turn.id and
         is_binary(data["provider_id"]) and is_integer(data["provider_revision"]) and
         is_binary(data["assignment_id"]) and is_integer(data["assignment_revision"]) do
      {:ok,
       %AI.Selection{
         role: :reviewer,
         source: :assignment,
         provider_id: data["provider_id"],
         provider_revision: data["provider_revision"],
         assignment_id: data["assignment_id"],
         assignment_revision: data["assignment_revision"]
       }}
    else
      {:error, "Recovery Reviewer assignment is invalid"}
    end
  end

  defp claim(turn, incident, selection, request, attempt) do
    digest =
      AIInvocation.request_digest(
        {request, attempt, selection.provider_id, selection.assignment_id}
      )

    Cases.claim_ai_invocation(
      :reviewer,
      turn.case_id,
      incident.revision,
      turn.resolution_run_id,
      turn.id,
      turn.revision,
      nil,
      nil,
      selection.provider_id,
      selection.assignment_id,
      selection.provider_revision,
      selection.assignment_revision,
      selection.source,
      digest,
      attempt,
      authorize?: false
    )
  end

  defp dispatch(turn, selection, request, %AIInvocationClaim{state: :claimed} = claim, opts) do
    invocation =
      opts
      |> Keyword.get(:ai_invocation, %{})
      |> Map.put(:cancelled?, fn -> not current?(turn) end)

    case Providers.ai_review_recovery(selection.provider_id, request, invocation,
           authorize?: false
         ) do
      {:ok, %AI.ReviewDecision{} = decision} ->
        settle(turn, selection, request, claim.invocation, decision)

      {:error, error} ->
        settle_failure(turn, claim.invocation, error, opts)
    end
  end

  defp dispatch(
         turn,
         _selection,
         _request,
         %AIInvocationClaim{state: :interrupted} = claim,
         _opts
       ) do
    with {:ok, _result} <-
           charge(turn, claim.invocation.reserved_units, "unknown:#{claim.invocation.id}"),
         :ok <- attention(turn, "Recovery Reviewer response is unknown", "Response was lost") do
      :ok
    end
  end

  defp dispatch(turn, _selection, _request, %AIInvocationClaim{state: :terminal}, _opts) do
    with {:ok, event} <- result_event(turn) do
      if event,
        do: apply_result(turn, event),
        else: attention(turn, "Recovery Reviewer failed", "Invocation is terminal")
    end
  end

  defp settle(turn, selection, request, invocation, decision) do
    usage = decision.usage
    amount = usage.input_tokens + usage.output_tokens

    data = %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "evidence_ids" => request.conclusion.evidence_ids,
      "condition_claims" => request.conclusion.condition_claims,
      "desired_outcome_claims" => request.conclusion.desired_outcome_claims,
      "desired_outcome_assessment" => decision.desired_outcome_assessment,
      "review_fingerprint" => RecoveryReviewFingerprint.reviewed(request),
      "verdict" => to_string(decision.verdict),
      "reason" => decision.reason,
      "ai_invocation_id" => invocation.id,
      "invocation_key" => invocation.idempotency_key,
      "provider_id" => selection.provider_id,
      "assignment_id" => selection.assignment_id
    }

    result =
      Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, charged} <- charge(turn, amount, "result:#{invocation.id}"),
             {:ok, _recorded} <-
               Cases.record_ai_invocation_outcome(
                 invocation,
                 invocation.revision,
                 %{
                   status: :completed,
                   input_tokens: usage.input_tokens,
                   output_tokens: usage.output_tokens,
                   cached_tokens: usage.cached_tokens,
                   reasoning_tokens: usage.reasoning_tokens,
                   finish_reason: usage.finish_reason,
                   result_digest: AIInvocation.request_digest(data),
                   completed_at: DateTime.utc_now()
                 },
                 authorize?: false
               ) do
          cond do
            match?(%BudgetResult{status: :exhausted}, charged) ->
              {:outcome, :budget_exhausted}

            not current?(turn) or match?({:error, _}, current_selection(selection)) ->
              {:outcome, :context_changed}

            true ->
              Cases.create_case_event_record(
                %{
                  case_id: turn.case_id,
                  resolution_run_id: turn.resolution_run_id,
                  event_type: "recovery_review_decided",
                  idempotency_key: result_key(turn),
                  data: data
                },
                authorize?: false
              )
          end
        end
      end)

    case result do
      {:ok, {:ok, event}} ->
        apply_result(turn, event)

      {:ok, {:outcome, :context_changed}} ->
        attention(turn, "Recovery Review context changed", "Review was superseded")

      {:ok, {:outcome, :budget_exhausted}} ->
        :ok

      {:error, _error} = error ->
        error
    end
  end

  defp settle_failure(turn, invocation, error, opts) do
    accounting = AIInvocation.failure_accounting(error, invocation.reserved_units)
    ai_error = accounting.ai_error
    usage = accounting.usage

    category = if match?(%AI.Error{}, ai_error), do: to_string(ai_error.category), else: "failed"
    code = if match?(%AI.Error{}, ai_error), do: ai_error.failure_code

    with {:ok, _result} <-
           Ash.transact([AIInvocation, Case, ResolutionRun, CaseEvent], fn ->
             with {:ok, _charged} <- charge(turn, accounting.amount, "failure:#{invocation.id}"),
                  {:ok, recorded} <-
                    Cases.record_ai_invocation_outcome(
                      invocation,
                      invocation.revision,
                      %{
                        status: :failed,
                        input_tokens: if(usage, do: usage.input_tokens, else: 0),
                        output_tokens: if(usage, do: usage.output_tokens, else: 0),
                        cached_tokens: if(usage, do: usage.cached_tokens),
                        reasoning_tokens: if(usage, do: usage.reasoning_tokens),
                        finish_reason: if(usage, do: usage.finish_reason),
                        category: category,
                        failure_code: code,
                        rejection_path: AIInvocation.rejection_path(ai_error),
                        completed_at: DateTime.utc_now()
                      },
                      authorize?: false
                    ) do
               recorded
             end
           end) do
      if category == "invalid_output" and delivery_attempt(opts) < 2 and
           delivery_attempt(opts) < max_delivery_attempts(opts) do
        {:error, "Recovery Reviewer output was invalid on attempt #{delivery_attempt(opts)}"}
      else
        attention(turn, "Recovery Reviewer failed", category)
      end
    end
  end

  defp retry_context(turn) do
    case Cases.list_ai_invocations(
           query: [
             filter: [
               turn_id: turn.id,
               role: :reviewer,
               status: :failed,
               category: "invalid_output"
             ]
           ],
           authorize?: false
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, failures} ->
        {:ok, AIInvocation.retry_context(failures)}

      {:error, _error} = error ->
        error
    end
  end

  defp delivery_attempt(opts), do: max(Keyword.get(opts, :delivery_attempt, 1), 1)
  defp max_delivery_attempts(opts), do: max(Keyword.get(opts, :max_delivery_attempts, 1), 1)

  defp charge(_turn, 0, _key), do: {:ok, :no_usage}

  defp charge(turn, amount, key) do
    Cases.charge_resolution_run(
      turn.case_id,
      turn.resolution_run_id,
      :ai_usage,
      amount,
      Budget.key("recovery-review:usage", key),
      %{"action" => "review_ai_usage", "turn_id" => turn.id},
      "Review the Case and AI usage limit",
      authorize?: false
    )
  end

  defp apply_result(turn, %CaseEvent{data: %{"verdict" => "approved"}}) do
    case Cases.route_downstream_decision(turn.id, authorize?: false) do
      {:ok, _resolved} -> :ok
      {:error, error} -> attention(turn, "Recovery Review could not be applied", error)
    end
  end

  defp apply_result(turn, %CaseEvent{data: %{"verdict" => "rejected", "reason" => reason}}) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
      if incident.status == :running and
           incident.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id} do
        reconsider_rejected_recovery(turn, reason)
      else
        :ok
      end
    end
  end

  defp apply_result(turn, %CaseEvent{data: %{"verdict" => "needs_human", "reason" => reason}}),
    do: attention(turn, "Recovery requires operator input", reason)

  defp apply_result(turn, _event),
    do: attention(turn, "Recovery Review is invalid", "No valid Reviewer verdict")

  defp reconsider_rejected_recovery(turn, reason) do
    with {:ok, result} <-
           Cases.start_turn(
             turn.case_id,
             turn.resolution_run_id,
             "recovery-review-rejected:#{turn.id}",
             %{
               "source" => "recovery_review_rejected",
               "source_turn_id" => turn.id,
               "review_reason" => reason,
               "objective" => "Reassess recovery using evidence relevant to each symptom"
             },
             %{"action" => "review_recovery", "turn_id" => turn.id},
             "Review the Case if the AI investigation limit is exhausted",
             authorize?: false
           ) do
      case result do
        %{status: status, value: next_turn} when status in [:charged, :duplicate] ->
          with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
            if incident.status == :running and
                 incident.pending_intent ==
                   %{"action" => "review_recovery", "turn_id" => turn.id} do
              case Cases.queue_case_resolver_turn(
                     incident,
                     incident.revision,
                     turn.id,
                     next_turn.id,
                     authorize?: false
                   ) do
                {:ok, _updated} -> :ok
                {:error, _error} = error -> error
              end
            else
              :ok
            end
          end

        %{status: :exhausted} ->
          :ok
      end
    end
  end

  defp attention(turn, reason, detail) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      if incident.status == :running and run.active and run.status == :running do
        pending = %{"action" => "review_recovery", "turn_id" => turn.id}

        case Cases.require_case_attention(
               incident.id,
               incident.revision,
               run.id,
               run.revision,
               Budget.key("recovery-review:attention", turn.id),
               reason,
               pending,
               String.slice(inspect(detail), 0, 1_000),
               authorize?: false
             ) do
          {:ok, _updated} -> :ok
          {:error, _error} = error -> error
        end
      else
        :ok
      end
    end
  end

  defp result_event(turn),
    do:
      Cases.case_event_by_idempotency(turn.case_id, result_key(turn),
        authorize?: false,
        not_found_error?: false
      )

  defp result_key(turn), do: Budget.key("recovery-review:result", turn.id)

  defp current?(turn) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
         {:ok, true} <- Opsonde.Cases.Case.ConditionContext.current?(incident, turn.id) do
      incident.status == :running and not incident.cancel_requested and
        incident.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id} and
        run.active and run.status == :running
    else
      _other -> false
    end
  end
end
