defmodule Opsonde.Cases.Proposal.Actions.Authority do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.{Accounts, Cases, Targets}

  alias Opsonde.Cases.{
    Approval,
    Budget,
    Case,
    CaseEvent,
    Proposal,
    ResolutionRun,
    ReviewDecision,
    Turn
  }

  alias Opsonde.Targets.{PolicyError, PolicyRequest, RequestClearance}

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :route -> route(input.arguments.proposal_id)
      :decide -> decide(input.arguments, context.actor)
      :review -> apply_review(input.arguments.proposal_id, input.arguments.review_decision_id)
    end
  end

  defp route(proposal_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, Approval, Turn, CaseEvent], fn ->
        with {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id) do
          route_locked(proposal, incident, run)
        end
      end)
    end
  end

  defp route_locked(%{status: :blocked} = proposal, incident, run) do
    require_attention(
      proposal,
      incident,
      run,
      proposal.preflight_reason || "Proposal is blocked by Target policy",
      "review_blocked_proposal",
      "Review the blocked Proposal and resume the Case"
    )
  end

  defp route_locked(%{status: :proposed} = proposal, incident, run) do
    with :ok <- valid_context(proposal, incident, run) do
      case proposal.authority_mode do
        :readonly -> recommend(proposal, incident, run)
        :ask -> await_human(proposal, incident)
        :auto -> await_reviewer(proposal, incident)
        :full_access -> authorize_full_access(proposal, incident, run)
      end
    end
  end

  defp route_locked(
         %{status: status} = proposal,
         _incident,
         _run
       )
       when status in [
              :recommended,
              :awaiting_human,
              :reviewing,
              :authorized,
              :rejected,
              :invalidated
            ],
       do: proposal

  defp decide(arguments, actor) do
    with {:ok, current_actor} <- current_actor(actor),
         {:ok, source} <- Cases.get_proposal(arguments.proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, Approval, Turn, CaseEvent], fn ->
        with {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id),
             {:ok, existing} <- existing_approval(proposal.id) do
          if existing do
            replay_human(existing, proposal, arguments, current_actor)
          else
            decide_locked(proposal, incident, run, arguments, current_actor)
          end
        end
      end)
    end
  end

  defp decide_locked(proposal, incident, run, arguments, actor) do
    with :ok <- expected_proposal(proposal, arguments),
         :ok <- human_decidable(proposal),
         :ok <- valid_context(proposal, incident, run),
         :ok <- available_pending(incident.pending_intent, proposal.id) do
      case arguments.decision do
        :approved -> approve_human(proposal, incident, run, arguments.reason, actor)
        :rejected -> reject_human(proposal, incident, run, arguments.reason, actor)
      end
    end
  end

  defp recommend(proposal, incident, run) do
    with {:ok, recommended} <- transition(proposal, :recommended) do
      require_attention(
        recommended,
        incident,
        run,
        "Readonly mode does not authorize remote effects",
        "view_recommendation",
        "Review the recommendation and handle the effect outside Opsonde"
      )
    end
  end

  defp await_human(proposal, incident) do
    with {:ok, waiting} <- transition(proposal, :awaiting_human),
         {:ok, _case} <-
           update_pending(incident, %{
             "action" => "decide_proposal",
             "proposal_id" => waiting.id,
             "proposal_digest" => waiting.proposal_digest
           }) do
      waiting
    end
  end

  defp await_reviewer(proposal, incident) do
    with {:ok, reviewing} <- transition(proposal, :reviewing),
         {:ok, _case} <-
           update_pending(incident, %{
             "action" => "review_proposal",
             "proposal_id" => reviewing.id,
             "proposal_digest" => reviewing.proposal_digest
           }),
         {:ok, _job} <- enqueue_review(reviewing.id) do
      reviewing
    end
  end

  defp apply_review(proposal_id, decision_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, decision} <- Cases.review_decision_by_proposal(proposal_id, authorize?: false),
         true <- decision.id == decision_id || {:error, "ReviewDecision does not match Proposal"} do
      Ash.transact([Case, ResolutionRun, Proposal, Approval, ReviewDecision], fn ->
        with {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id) do
          apply_review_locked(proposal, decision, incident, run)
        end
      end)
    end
  end

  defp apply_review_locked(%{status: :authorized} = proposal, _decision, _incident, _run),
    do: proposal

  defp apply_review_locked(%{status: :awaiting_human} = proposal, _decision, _incident, _run),
    do: proposal

  defp apply_review_locked(%{status: :reviewing} = proposal, decision, incident, run) do
    with :ok <- valid_context(proposal, incident, run),
         true <-
           decision.proposal_digest == proposal.proposal_digest ||
             {:error, "ReviewDecision Proposal digest changed"} do
      case decision.verdict do
        :approved ->
          approve_review(proposal, decision, incident, run)

        verdict when verdict in [:rejected, :needs_human] ->
          await_human_review(proposal, decision, incident)
      end
    end
  end

  defp apply_review_locked(_proposal, _decision, _incident, _run),
    do: {:error, "Proposal is not awaiting Reviewer decision"}

  defp approve_review(proposal, decision, incident, run) do
    with {:ok, actor} <- current_owner(incident),
         {:ok, clearance} <- revalidate(proposal, actor),
         {:ok, approval} <-
           create_approval(proposal, actor, :approved, :reviewer, decision.reason, clearance),
         {:ok, authorized} <- transition(proposal, :authorized),
         {:ok, _case} <- update_pending(incident, dispatch_pending(authorized, approval)) do
      authorized
    else
      {:blocked, category, reason} -> invalidate(proposal, incident, run, category, reason)
      {:error, _error} = error -> error
    end
  end

  defp await_human_review(proposal, decision, incident) do
    with {:ok, waiting} <- transition(proposal, :awaiting_human),
         {:ok, _case} <-
           update_pending(incident, %{
             "action" => "decide_proposal",
             "proposal_id" => waiting.id,
             "proposal_digest" => waiting.proposal_digest,
             "review_decision_id" => decision.id,
             "review_reason" => decision.reason
           }) do
      waiting
    end
  end

  defp authorize_full_access(proposal, incident, run) do
    with {:ok, actor} <- current_owner(incident),
         {:ok, clearance} <- revalidate(proposal, actor),
         {:ok, approval} <-
           create_approval(
             proposal,
             actor,
             :approved,
             :full_access,
             "FullAccess mode authorized the exact Proposal",
             clearance
           ),
         {:ok, authorized} <- transition(proposal, :authorized),
         {:ok, _case} <- update_pending(incident, dispatch_pending(authorized, approval)) do
      authorized
    else
      {:blocked, category, reason} -> invalidate(proposal, incident, run, category, reason)
      {:error, _error} = error -> error
    end
  end

  defp approve_human(proposal, incident, run, reason, actor) do
    with {:ok, clearance} <- revalidate(proposal, actor),
         {:ok, approval} <-
           create_approval(proposal, actor, :approved, :human, reason, clearance),
         {:ok, authorized} <- transition(proposal, :authorized),
         {:ok, _case} <- update_pending(incident, dispatch_pending(authorized, approval)) do
      authorized
    else
      {:blocked, category, blocked_reason} ->
        invalidate(proposal, incident, run, category, blocked_reason)

      {:error, _error} = error ->
        error
    end
  end

  defp reject_human(proposal, incident, run, reason, actor) do
    with {:ok, _approval} <-
           create_approval(proposal, actor, :rejected, :human, reason, nil),
         {:ok, rejected} <- transition(proposal, :rejected),
         {:ok, started} <- start_reconsideration(rejected, incident, run, reason, actor),
         {:ok, _case} <- continue_after_rejection(started, incident, rejected) do
      rejected
    end
  end

  defp start_reconsideration(proposal, incident, run, reason, actor) do
    Cases.start_turn(
      incident.id,
      run.id,
      Budget.key("proposal:rejected", proposal.id),
      %{
        "objective" => "Continue resolution after a rejected Proposal",
        "rejected_proposal_id" => proposal.id,
        "rejected_proposal_digest" => proposal.proposal_digest,
        "reason" => reason
      },
      %{"action" => "continue_resolution", "rejected_proposal_id" => proposal.id},
      "Review Resolver limits or handle the rejected Proposal manually",
      actor: actor,
      authorize?: false
    )
  end

  defp continue_after_rejection(%{status: status}, _incident, _proposal)
       when status == :exhausted,
       do: {:ok, :needs_attention}

  defp continue_after_rejection(%{value: %Turn{} = turn}, incident, proposal) do
    update_pending(incident, %{
      "action" => "resolve_turn",
      "proposal_id" => proposal.id,
      "turn_id" => turn.id,
      "rejected_proposal_id" => proposal.id
    })
  end

  defp invalidate(proposal, incident, run, category, reason) do
    with {:ok, invalidated} <- transition(proposal, :invalidated) do
      require_attention(
        invalidated,
        incident,
        run,
        "Proposal authorization failed: #{reason}",
        "review_invalidated_proposal",
        "Review the #{category} authorization failure and resume the Case"
      )
    end
  end

  defp create_approval(proposal, actor, decision, source, reason, clearance) do
    Cases.create_approval_record(
      %{
        proposal_id: proposal.id,
        case_id: proposal.case_id,
        resolution_run_id: proposal.resolution_run_id,
        actor_id: actor.id,
        actor_role_version: actor.role_version,
        decision: decision,
        source: source,
        proposal_digest: proposal.proposal_digest,
        proposal_revision: proposal.revision,
        case_generation: proposal.case_generation,
        clearance_digest: clearance_digest(clearance),
        reason: reason,
        decided_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp revalidate(proposal, actor) do
    case Targets.clear_target_request(policy_request(proposal), actor: actor) do
      {:ok, %RequestClearance{} = clearance} ->
        if clearance.provider_id == proposal.provider_id and
             clearance.provider_revision == proposal.provider_revision do
          {:ok, clearance}
        else
          {:blocked, :stale_context, "Target Provider changed after the Proposal"}
        end

      {:error, error} ->
        case find_error(error) do
          %PolicyError{category: category, message: message} ->
            {:blocked, category, message}

          _other ->
            {:error, error}
        end
    end
  end

  defp policy_request(proposal) do
    %PolicyRequest{
      kind: :effect,
      authority_mode: proposal.authority_mode,
      target_id: proposal.target_id,
      target_revision: proposal.target_revision,
      access_method_id: proposal.access_method_id,
      access_method_revision: proposal.access_method_revision,
      capability: proposal.capability,
      operation: proposal.operation,
      selectors: proposal.selectors,
      parameters: proposal.parameters,
      operation_id: proposal.reserved_operation_id,
      idempotency_key: proposal.operation_idempotency_key,
      max_attempts: 1
    }
  end

  defp require_attention(proposal, incident, run, reason, action, required_input) do
    pending = %{"action" => action, "proposal_id" => proposal.id}

    with {:ok, _case} <-
           Cases.require_case_attention(
             incident.id,
             incident.revision,
             run.id,
             run.revision,
             Budget.key("proposal:attention:#{action}", proposal.id),
             String.slice(reason, 0, 500),
             pending,
             required_input,
             authorize?: false
           ) do
      proposal
    end
  end

  defp transition(proposal, status) do
    Cases.transition_proposal(proposal, proposal.revision, %{status: status}, authorize?: false)
  end

  defp update_pending(incident, pending) do
    with :ok <- available_pending(incident.pending_intent, pending["proposal_id"]) do
      Cases.update_case_record(
        incident,
        incident.revision,
        %{pending_intent: pending, stop_reason: nil, required_human_input: nil},
        authorize?: false
      )
    end
  end

  defp valid_context(proposal, incident, run) do
    cond do
      incident.status != :running or incident.cancel_requested ->
        {:error, "Case resolution is not running"}

      run.status != :running ->
        {:error, "ResolutionRun is not running"}

      proposal.case_generation != run.generation ->
        {:error, "Proposal Case generation changed"}

      proposal.authority_mode != incident.authority_mode or
          proposal.authority_mode != run.authority_mode ->
        {:error, "Proposal authority mode changed"}

      DateTime.compare(DateTime.utc_now(), proposal.expires_at) != :lt ->
        {:error, "Proposal has expired"}

      true ->
        :ok
    end
  end

  defp expected_proposal(proposal, arguments) do
    cond do
      proposal.revision != arguments.expected_revision -> stale(:revision)
      proposal.proposal_digest != arguments.proposal_digest -> stale(:proposal_digest)
      true -> :ok
    end
  end

  defp stale(field) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: Proposal, field: field)}
  end

  defp human_decidable(%{status: :awaiting_human, authority_mode: mode})
       when mode in [:ask, :auto],
       do: :ok

  defp human_decidable(_proposal), do: {:error, "Proposal is not awaiting a human decision"}

  defp available_pending(pending, _proposal_id) when map_size(pending) == 0, do: :ok

  defp available_pending(%{"proposal_id" => proposal_id}, proposal_id), do: :ok

  defp available_pending(_pending, _proposal_id),
    do: {:error, "Case has another pending decision"}

  defp replay_human(approval, proposal, arguments, actor) do
    if approval.source == :human and approval.actor_id == actor.id and
         approval.decision == arguments.decision and
         approval.proposal_digest == arguments.proposal_digest and
         approval.reason == arguments.reason do
      proposal
    else
      {:error, "Proposal already has a different decision"}
    end
  end

  defp current_owner(%{current_owner_id: owner_id}) when is_binary(owner_id),
    do: current_actor(%{id: owner_id})

  defp current_owner(_incident), do: {:error, "Case has no operational owner"}

  defp current_actor(%{id: actor_id}) do
    case Accounts.get_user(actor_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] -> {:ok, actor}
      _unavailable -> {:error, "Actor cannot authorize a Proposal"}
    end
  end

  defp current_actor(_actor), do: {:error, "Actor cannot authorize a Proposal"}

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
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp lock_proposal(id, case_id, run_id) do
    Proposal
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Proposal is unavailable")
  end

  defp existing_approval(proposal_id) do
    Approval
    |> Ash.Query.for_read(:by_proposal, %{proposal_id: proposal_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp dispatch_pending(proposal, approval) do
    %{
      "action" => "dispatch_operation",
      "proposal_id" => proposal.id,
      "approval_id" => approval.id,
      "operation_id" => proposal.reserved_operation_id
    }
  end

  defp clearance_digest(nil), do: nil
  defp clearance_digest(clearance), do: Base.encode16(clearance.digest, case: :lower)

  defp find_error(%PolicyError{} = error), do: error

  defp find_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_error/1)

  defp find_error(_error), do: nil

  defp enqueue_review(proposal_id) do
    %{"proposal_id" => proposal_id}
    |> Opsonde.Cases.ReviewWorker.new()
    |> Oban.insert()
  end
end
