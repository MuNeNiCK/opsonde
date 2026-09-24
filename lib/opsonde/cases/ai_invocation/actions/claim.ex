defmodule Opsonde.Cases.AIInvocation.Actions.Claim do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  @max_reservation 65_536

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    AIInvocation,
    AIInvocationClaim,
    Case,
    Proposal,
    ResolutionRun,
    Turn
  }

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    Ash.transact([AIInvocation, Case, Proposal, ResolutionRun, Turn], fn ->
      with {:ok, incident} <- lock(Case, arguments.case_id),
           {:ok, run} <- lock(ResolutionRun, arguments.resolution_run_id),
           :ok <- current_context(arguments, incident, run),
           {:ok, existing} <- invocation(arguments) do
        claim(existing, arguments, run)
      end
    end)
  end

  defp claim(nil, arguments, run) do
    remaining = run.max_ai_usage_units - run.ai_usage_units

    if remaining > 0 do
      attrs = %{
        role: arguments.role,
        case_id: arguments.case_id,
        resolution_run_id: arguments.resolution_run_id,
        turn_id: arguments.turn_id,
        proposal_id: arguments.proposal_id,
        provider_id: arguments.provider_id,
        assignment_id: arguments.assignment_id,
        idempotency_key: idempotency_key(arguments),
        request_digest: arguments.request_digest,
        provider_revision: arguments.provider_revision,
        assignment_revision: arguments.assignment_revision,
        selection_source: arguments.selection_source,
        reserved_units: min(remaining, @max_reservation),
        dispatch_started_at: DateTime.utc_now()
      }

      with {:ok, invocation} <- Cases.create_ai_invocation_record(attrs, authorize?: false) do
        %AIInvocationClaim{state: :claimed, invocation: invocation}
      end
    else
      {:error, "AI usage limit exhausted"}
    end
  end

  defp claim(%{status: :dispatching} = invocation, _arguments, _run) do
    with {:ok, invocation} <-
           Cases.record_ai_invocation_outcome(
             invocation,
             invocation.revision,
             %{
               status: :unknown,
               category: "response_unknown",
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      %AIInvocationClaim{state: :interrupted, invocation: invocation}
    end
  end

  defp claim(%{status: :unknown} = invocation, _arguments, _run),
    do: %AIInvocationClaim{state: :interrupted, invocation: invocation}

  defp claim(invocation, _arguments, _run),
    do: %AIInvocationClaim{state: :terminal, invocation: invocation}

  defp current_context(arguments, incident, run) do
    with true <-
           (incident.revision == arguments.expected_case_revision and
              incident.status == :running and not incident.cancel_requested) ||
             {:error, "Case AI context changed"},
         true <-
           (run.case_id == incident.id and run.active and run.status == :running) ||
             {:error, "ResolutionRun AI context changed"},
         :ok <- subject_context(arguments, incident.id, run.id) do
      :ok
    end
  end

  defp subject_context(%{role: :resolver} = arguments, case_id, run_id)
       when is_binary(arguments.turn_id) and is_nil(arguments.proposal_id) and
              is_integer(arguments.expected_turn_revision) do
    with {:ok, turn} <- lock(Turn, arguments.turn_id),
         true <-
           (turn.case_id == case_id and turn.resolution_run_id == run_id and
              turn.status == :started and turn.revision == arguments.expected_turn_revision) ||
             {:error, "Resolver Turn AI context changed"} do
      :ok
    end
  end

  defp subject_context(%{role: :reviewer} = arguments, case_id, run_id)
       when is_binary(arguments.proposal_id) and is_nil(arguments.turn_id) and
              is_integer(arguments.expected_proposal_revision) do
    with {:ok, proposal} <- lock(Proposal, arguments.proposal_id),
         true <-
           (proposal.case_id == case_id and proposal.resolution_run_id == run_id and
              proposal.status == :reviewing and
              proposal.revision == arguments.expected_proposal_revision) ||
             {:error, "Reviewer Proposal AI context changed"} do
      :ok
    end
  end

  defp subject_context(_arguments, _case_id, _run_id),
    do: {:error, "AI invocation subject is invalid"}

  defp invocation(arguments) do
    with {:ok, exact} <-
           AIInvocation
           |> Ash.Query.for_read(:by_idempotency, %{
             idempotency_key: idempotency_key(arguments)
           })
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(authorize?: false) do
      case exact do
        nil -> unresolved_invocation(arguments)
        invocation -> {:ok, invocation}
      end
    end
  end

  defp unresolved_invocation(%{role: :resolver, turn_id: turn_id}) do
    AIInvocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(turn_id == ^turn_id and status == :dispatching)
    |> unresolved_invocation()
  end

  defp unresolved_invocation(%{role: :reviewer, proposal_id: proposal_id}) do
    AIInvocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(proposal_id == ^proposal_id and status == :dispatching)
    |> unresolved_invocation()
  end

  defp unresolved_invocation(query) do
    query
    |> Ash.Query.sort(dispatch_started_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp idempotency_key(%{role: :reviewer, proposal_id: proposal_id, delivery_attempt: attempt})
       when is_binary(proposal_id) and is_integer(attempt),
       do: "reviewer:#{proposal_id}:attempt:#{attempt}"

  defp idempotency_key(arguments) do
    subject_id = arguments.turn_id || arguments.proposal_id
    "#{arguments.role}:#{subject_id}:#{arguments.request_digest}"
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "AI invocation context is unavailable"}
      result -> result
    end
  end
end
