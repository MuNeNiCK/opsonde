defmodule Opsonde.Cases.Operation.Actions.Accept do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.{Accounts, Cases, Targets}
  alias Opsonde.Cases.{Budget, Operation, Proposal}
  alias Opsonde.Targets.{PolicyRequest, RequestClearance}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, proposal} <- Cases.get_proposal(input.arguments.proposal_id, authorize?: false),
         {:ok, existing} <- existing(proposal.id) do
      if existing, do: {:ok, existing}, else: consume(proposal)
    end
  end

  defp consume(proposal) do
    case Budget.consume(
           case_id: proposal.case_id,
           resolution_run_id: proposal.resolution_run_id,
           kind: budget_kind(proposal.request_kind),
           amount: 1,
           ledger_key: Budget.key("proposal:#{proposal.request_kind}", proposal.id),
           actor: nil,
           event_type: "#{proposal.request_kind}_budget_charged",
           event_data: %{"proposal_id" => proposal.id},
           pending_intent: %{
             "action" => "review_#{proposal.request_kind}_limit",
             "proposal_id" => proposal.id
           },
           required_human_input:
             "Increase the Target request limit or handle the Proposal manually",
           operation: fn incident, run -> accept_locked(proposal.id, incident, run) end,
           duplicate: fn _incident, _run -> required_existing(proposal.id) end
         ) do
      {:ok, %{status: status, value: %Operation{} = operation}}
      when status in [:charged, :duplicate] ->
        {:ok, operation}

      {:ok, %{status: :exhausted}} ->
        {:error, "Target request budget exhausted"}

      other ->
        other
    end
  end

  defp accept_locked(proposal_id, incident, run) do
    with {:ok, proposal} <- lock(Proposal, proposal_id),
         :ok <- valid_context(proposal, incident, run),
         {:ok, approval} <- Cases.approval_by_proposal(proposal.id, authorize?: false),
         :ok <- valid_approval(approval, proposal),
         {:ok, actor} <- current_actor(approval),
         {:ok, %RequestClearance{} = clearance} <-
           Targets.clear_target_request(request(proposal), actor: actor),
         :ok <- exact_provider(clearance, proposal),
         {:ok, operation} <- create(proposal, approval, actor, clearance),
         {:ok, _job} <- enqueue(operation.id) do
      {:ok, operation}
    end
  end

  defp valid_context(proposal, incident, run) do
    if proposal.status == :authorized and incident.status == :running and
         not incident.cancel_requested and run.active and run.status == :running and
         run.generation == proposal.case_generation and
         proposal.authority_mode == incident.authority_mode and
         proposal.authority_mode == run.authority_mode and
         DateTime.compare(DateTime.utc_now(), proposal.expires_at) == :lt,
       do: :ok,
       else: {:error, "Authorized Proposal is stale"}
  end

  defp valid_approval(approval, proposal) do
    if approval.decision == :approved and approval.proposal_digest == proposal.proposal_digest and
         approval.proposal_revision + 1 == proposal.revision and
         approval.case_generation == proposal.case_generation,
       do: :ok,
       else: {:error, "Approval does not authorize the current Proposal"}
  end

  defp current_actor(approval) do
    case Accounts.get_user(approval.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == approval.actor_role_version ->
        {:ok, actor}

      _unavailable ->
        {:error, "Approval actor authority changed"}
    end
  end

  defp request(proposal) do
    %PolicyRequest{
      kind: proposal.request_kind,
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

  defp exact_provider(clearance, proposal) do
    if clearance.provider_id == proposal.provider_id and
         clearance.provider_revision == proposal.provider_revision,
       do: :ok,
       else: {:error, "Target Provider changed after approval"}
  end

  defp create(proposal, approval, actor, clearance) do
    Cases.create_operation_record(
      %{
        id: proposal.reserved_operation_id,
        case_id: proposal.case_id,
        resolution_run_id: proposal.resolution_run_id,
        proposal_id: proposal.id,
        approval_id: approval.id,
        actor_id: actor.id,
        target_id: proposal.target_id,
        access_method_id: proposal.access_method_id,
        provider_id: proposal.provider_id,
        case_generation: proposal.case_generation,
        authority_mode: proposal.authority_mode,
        proposal_revision: proposal.revision,
        approval_proposal_revision: approval.proposal_revision,
        actor_role_version: actor.role_version,
        target_revision: proposal.target_revision,
        access_method_revision: proposal.access_method_revision,
        provider_revision: proposal.provider_revision,
        request_kind: proposal.request_kind,
        capability: proposal.capability,
        operation: proposal.operation,
        selectors: proposal.selectors,
        parameters: proposal.parameters,
        idempotency_key: proposal.operation_idempotency_key,
        authorization_digest: Base.encode16(clearance.digest, case: :lower),
        policy_context: %{
          "policy_revisions" =>
            Enum.map(clearance.policy_revisions, fn {id, revision} ->
              %{"id" => id, "revision" => revision}
            end)
        },
        accepted_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp enqueue(id),
    do: id |> then(&Opsonde.Cases.OperationWorker.new(%{"operation_id" => &1})) |> Oban.insert()

  defp required_existing(proposal_id) do
    case existing(proposal_id) do
      {:ok, %Operation{} = operation} -> {:ok, operation}
      _missing -> {:error, "Effect budget ledger exists without its Operation"}
    end
  end

  defp existing(proposal_id) do
    Cases.operation_by_proposal(proposal_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp budget_kind(:observation), do: :target_request
  defp budget_kind(:effect), do: :effect

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Operation input is unavailable"}
      result -> result
    end
  end
end
