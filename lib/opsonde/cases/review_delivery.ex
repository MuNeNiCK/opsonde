defmodule Opsonde.Cases.ReviewDelivery do
  @moduledoc false

  alias Opsonde.{Cases, Providers}

  alias Opsonde.Cases.{
    AIInvocation,
    AIInvocationClaim,
    Budget,
    Case,
    CaseEvent,
    Proposal,
    ResolutionRun,
    ReviewDecision,
    ReviewProjection
  }

  alias Opsonde.Providers.AI

  def run(proposal_id, opts \\ []) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false) do
      case existing_decision(proposal.id) do
        {:ok, %ReviewDecision{} = decision} -> apply(decision)
        {:ok, nil} -> select_and_deliver(proposal, opts)
        {:error, _error} = error -> error
      end
    end
  end

  defp select_and_deliver(proposal, opts) do
    case assigned_selection(proposal) do
      {:ok, selection} -> deliver(proposal, selection, opts)
      {:error, error} -> persist_failure(proposal, nil, error)
    end
  end

  defp deliver(proposal, selection, opts) do
    with {:ok, current} <- current_selection(selection),
         {:ok, request} <- ReviewProjection.build(proposal.id, current),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, claim} <- claim_invocation(proposal, incident, current, request) do
      dispatch(proposal, current, request, claim, opts)
    else
      {:error, error} -> persist_failure(proposal, selection, error)
    end
  end

  defp dispatch(proposal, selection, request, %AIInvocationClaim{state: :claimed} = claim, opts) do
    invocation = invocation(proposal.case_id, Keyword.get(opts, :ai_invocation, %{}))

    case Providers.ai_review(selection.provider_id, request, invocation, authorize?: false) do
      {:ok, decision} ->
        with {:ok, stored} <- accept(proposal, selection, request, claim.invocation, decision) do
          apply(stored)
        end

      {:error, error} ->
        persist_failure(proposal, selection, error, claim.invocation)
    end
  end

  defp dispatch(
         proposal,
         selection,
         _request,
         %AIInvocationClaim{state: :interrupted, invocation: invocation},
         _opts
       ),
       do: persist_interruption(proposal, selection, invocation)

  defp dispatch(proposal, _selection, _request, %AIInvocationClaim{state: :terminal}, _opts) do
    case existing_decision(proposal.id) do
      {:ok, %ReviewDecision{} = decision} -> apply(decision)
      _missing -> {:error, "Reviewer AI invocation is already terminal"}
    end
  end

  defp claim_invocation(proposal, incident, selection, request) do
    Cases.claim_ai_invocation(
      :reviewer,
      proposal.case_id,
      incident.revision,
      proposal.resolution_run_id,
      nil,
      nil,
      proposal.id,
      proposal.revision,
      selection.provider_id,
      selection.assignment_id,
      selection.provider_revision,
      selection.assignment_revision,
      selection.source,
      AIInvocation.request_digest(request),
      authorize?: false
    )
  end

  defp assigned_selection(proposal) do
    key = assignment_key(proposal.id)

    case Cases.case_event_by_idempotency(proposal.case_id, key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %CaseEvent{} = event} -> selection_from_event(event, proposal)
      {:ok, nil} -> create_assignment(proposal, key)
      {:error, _error} = error -> error
    end
  end

  defp create_assignment(proposal, key) do
    resolver = proposal.resolver_identity

    with {:ok, %AI.Selection{role: :reviewer} = selection} <-
           Providers.select_reviewer_ai(
             resolver["assignment_id"],
             resolver["assignment_revision"],
             resolver["provider_revision"],
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: proposal.case_id,
               resolution_run_id: proposal.resolution_run_id,
               event_type: "reviewer_assigned",
               idempotency_key: key,
               data: selection_data(selection, proposal.id)
             },
             authorize?: false
           ) do
      {:ok, selection}
    else
      {:error, _error} = error ->
        case Cases.case_event_by_idempotency(proposal.case_id, key,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %CaseEvent{} = event} -> selection_from_event(event, proposal)
          _missing -> error
        end
    end
  end

  defp selection_data(selection, proposal_id) do
    %{
      "proposal_id" => proposal_id,
      "provider_id" => selection.provider_id,
      "provider_revision" => selection.provider_revision,
      "assignment_id" => selection.assignment_id,
      "assignment_revision" => selection.assignment_revision,
      "source" => to_string(selection.source)
    }
  end

  defp selection_from_event(%CaseEvent{data: data, resolution_run_id: run_id}, proposal)
       when run_id == proposal.resolution_run_id do
    source = source(data["source"])

    if data["proposal_id"] == proposal.id and is_binary(data["provider_id"]) and
         is_integer(data["provider_revision"]) and is_binary(data["assignment_id"]) and
         is_integer(data["assignment_revision"]) and not is_nil(source) do
      {:ok,
       %AI.Selection{
         role: :reviewer,
         provider_id: data["provider_id"],
         provider_revision: data["provider_revision"],
         assignment_id: data["assignment_id"],
         assignment_revision: data["assignment_revision"],
         source: source
       }}
    else
      {:error, ai_error(:invalid_input, "Persisted Reviewer assignment is invalid")}
    end
  end

  defp selection_from_event(_event, _proposal),
    do: {:error, ai_error(:invalid_input, "Persisted Reviewer assignment is invalid")}

  defp current_selection(%AI.Selection{source: :assignment} = selection) do
    case Providers.eligible_ai_usage_role_assignments(:reviewer, authorize?: false) do
      {:ok, assignments} ->
        if Enum.any?(assignments, fn item ->
             item.id == selection.assignment_id and item.revision == selection.assignment_revision and
               item.provider_id == selection.provider_id and
               item.provider.revision == selection.provider_revision
           end),
           do: {:ok, selection},
           else: {:error, ai_error(:unavailable, "Reviewer assignment changed")}

      {:error, _error} ->
        {:error, ai_error(:unavailable, "Reviewer assignment is unavailable")}
    end
  end

  defp current_selection(%AI.Selection{source: :resolver_fallback} = selection) do
    case Providers.load_resolver_ai_usage_role_assignment(
           selection.assignment_id,
           selection.assignment_revision,
           selection.provider_revision,
           authorize?: false
         ) do
      {:ok, _assignment} -> {:ok, selection}
      {:error, _error} -> {:error, ai_error(:unavailable, "Resolver fallback changed")}
    end
  end

  defp accept(proposal, selection, request, invocation, decision) do
    usage = decision.usage.input_tokens + decision.usage.output_tokens
    attrs = decision_attrs(proposal, selection, request, decision)

    Ash.transact([AIInvocation, Case, ResolutionRun, Proposal, ReviewDecision], fn ->
      with {:ok, charged} <-
             charge_usage(
               proposal,
               usage,
               "review-result:#{invocation.id}",
               %{
                 "action" => "review_ai_usage",
                 "proposal_id" => proposal.id,
                 "ai_invocation_id" => invocation.id
               }
             ) do
        case charged.status do
          status when status in [:charged, :duplicate] ->
            with {:ok, stored} <- store_decision(attrs),
                 {:ok, _invocation} <-
                   record_invocation(invocation, :completed,
                     input_tokens: decision.usage.input_tokens,
                     output_tokens: decision.usage.output_tokens,
                     result_digest: attrs.result_digest
                   ) do
              stored
            end

          :exhausted ->
            failure = failure_attrs(proposal, selection, "budget_exhausted", charged.reason)

            with {:ok, stored} <- store_decision(failure),
                 {:ok, _invocation} <-
                   record_invocation(invocation, :completed,
                     input_tokens: decision.usage.input_tokens,
                     output_tokens: decision.usage.output_tokens,
                     category: "budget_exhausted",
                     result_digest: failure.result_digest
                   ) do
              stored
            end
        end
      end
    end)
    |> accepted_or_existing(proposal.id)
  end

  defp decision_attrs(proposal, selection, request, decision) do
    base = %{
      proposal_id: proposal.id,
      case_id: proposal.case_id,
      resolution_run_id: proposal.resolution_run_id,
      provider_id: selection.provider_id,
      assignment_id: selection.assignment_id,
      outcome: :decision,
      verdict: decision.verdict,
      category: nil,
      reason: decision.reason,
      selection_source: selection.source,
      provider_revision: selection.provider_revision,
      assignment_revision: selection.assignment_revision,
      session_id: request.session_id,
      resolver_session_id: request.resolver_session_id,
      proposal_digest: proposal.proposal_digest,
      input_tokens: decision.usage.input_tokens,
      output_tokens: decision.usage.output_tokens,
      decided_at: DateTime.utc_now()
    }

    Map.put(base, :result_digest, result_digest(base))
  end

  defp store_decision(attrs),
    do: Cases.create_review_decision_record(attrs, authorize?: false)

  defp persist_failure(proposal, selection, error, invocation \\ nil) do
    {category, reason} = failure(error)
    attrs = failure_attrs(proposal, selection, category, reason)

    Ash.transact([AIInvocation, ReviewDecision], fn ->
      with {:ok, stored} <- store_decision(attrs),
           {:ok, _invocation} <- record_failure(invocation, category) do
        stored
      end
    end)
    |> accepted_or_existing(proposal.id)
    |> case do
      {:ok, stored} -> apply(stored)
      {:error, _error} = error -> error
    end
  end

  defp persist_interruption(proposal, selection, invocation) do
    reason =
      "Reviewer response is unknown after dispatch; #{invocation.reserved_units} AI usage units were reserved"

    attrs = failure_attrs(proposal, selection, "response_unknown", reason)

    Ash.transact([Case, ResolutionRun, Proposal, ReviewDecision], fn ->
      with {:ok, charged} <-
             charge_usage(
               proposal,
               invocation.reserved_units,
               "review-unknown:#{invocation.id}",
               %{
                 "action" => "reserve_unknown_review_usage",
                 "proposal_id" => proposal.id,
                 "ai_invocation_id" => invocation.id,
                 "reserved_usage_units" => invocation.reserved_units
               }
             ),
           true <-
             charged.status in [:charged, :duplicate] ||
               {:error, "Reviewer AI usage reservation could not be charged"},
           {:ok, stored} <- store_decision(attrs) do
        stored
      end
    end)
    |> accepted_or_existing(proposal.id)
    |> case do
      {:ok, stored} -> apply(stored)
      {:error, _error} = error -> error
    end
  end

  defp failure_attrs(proposal, selection, category, reason) do
    %{
      proposal_id: proposal.id,
      case_id: proposal.case_id,
      resolution_run_id: proposal.resolution_run_id,
      provider_id: selection && selection.provider_id,
      assignment_id: selection && selection.assignment_id,
      outcome: :delivery_failed,
      verdict: :needs_human,
      category: category,
      reason: String.slice(reason, 0, 1_000),
      selection_source: selection && selection.source,
      provider_revision: selection && selection.provider_revision,
      assignment_revision: selection && selection.assignment_revision,
      session_id: "reviewer:#{proposal.id}",
      resolver_session_id: "resolver:#{proposal.resolution_run_id}",
      proposal_digest: proposal.proposal_digest,
      input_tokens: 0,
      output_tokens: 0,
      decided_at: DateTime.utc_now()
    }
    |> then(&Map.put(&1, :result_digest, result_digest(&1)))
  end

  defp apply(decision) do
    case Cases.apply_proposal_review(decision.proposal_id, decision.id, authorize?: false) do
      {:ok, _proposal} ->
        :ok

      {:error, _error} = error ->
        with "budget_exhausted" <- decision.category,
             {:ok, %{status: :needs_attention}} <-
               Cases.get_case(decision.case_id, authorize?: false) do
          :ok
        else
          _other -> error
        end
    end
  end

  defp charge_usage(proposal, 0, _idempotency_key, _metadata) do
    with {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false) do
      {:ok, %Cases.BudgetResult{status: :charged, case: incident, run: run, value: run}}
    end
  end

  defp charge_usage(proposal, amount, idempotency_key, metadata) do
    Cases.charge_resolution_run(
      proposal.case_id,
      proposal.resolution_run_id,
      :ai_usage,
      amount,
      idempotency_key,
      metadata,
      "Increase the AI usage limit or decide the Proposal manually",
      authorize?: false
    )
  end

  defp record_failure(nil, _category), do: {:ok, nil}

  defp record_failure(invocation, category),
    do: record_invocation(invocation, :failed, category: category)

  defp record_invocation(invocation, status, attrs) do
    Cases.record_ai_invocation_outcome(
      invocation,
      invocation.revision,
      %{
        status: status,
        input_tokens: Keyword.get(attrs, :input_tokens, 0),
        output_tokens: Keyword.get(attrs, :output_tokens, 0),
        category: Keyword.get(attrs, :category),
        result_digest: Keyword.get(attrs, :result_digest),
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp existing_decision(proposal_id),
    do:
      Cases.review_decision_by_proposal(proposal_id,
        authorize?: false,
        not_found_error?: false
      )

  defp accepted_or_existing({:ok, stored}, _proposal_id), do: {:ok, stored}

  defp accepted_or_existing({:error, error}, proposal_id) do
    case existing_decision(proposal_id) do
      {:ok, %ReviewDecision{} = stored} -> {:ok, stored}
      _missing -> {:error, error}
    end
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

  defp failure(error) do
    case find_error(error) do
      %AI.Error{category: category} -> {to_string(category), public_failure(category)}
      _error -> {"failed", "Reviewer delivery failed"}
    end
  end

  defp public_failure(:authentication), do: "Reviewer authentication failed"
  defp public_failure(:unreachable), do: "Reviewer AI is unreachable"
  defp public_failure(:timeout), do: "Reviewer AI timed out"
  defp public_failure(:rate_limited), do: "Reviewer AI rate limit was exceeded"
  defp public_failure(:cancelled), do: "Reviewer decision was cancelled"
  defp public_failure(:invalid_input), do: "Reviewer input is invalid"
  defp public_failure(:invalid_output), do: "Reviewer output is invalid"
  defp public_failure(:unavailable), do: "Reviewer AI is unavailable"
  defp public_failure(_category), do: "Reviewer delivery failed"

  defp find_error(%AI.Error{} = error), do: error

  defp find_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_error/1)

  defp find_error(error), do: error

  defp result_digest(attrs) do
    attrs
    |> Map.drop([:decided_at, :result_digest])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp assignment_key(proposal_id), do: Budget.key("proposal:reviewer_assignment", proposal_id)
  defp source("assignment"), do: :assignment
  defp source("resolver_fallback"), do: :resolver_fallback
  defp source(_value), do: nil
  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
