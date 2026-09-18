defmodule Opsonde.Cases.VerificationAttempt.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.Cases
  alias Opsonde.Cases.{Case, ResolutionRun, VerificationAttempt, VerificationClaim}

  @terminal [:verified, :not_verified, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source} <- Cases.get_verification_attempt(input.arguments.id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, VerificationAttempt], fn ->
        with {:ok, incident} <- lock(Case, source.case_id),
             {:ok, run} <- lock(ResolutionRun, source.resolution_run_id),
             {:ok, attempt} <- lock(VerificationAttempt, source.id) do
          claim(attempt, incident, run)
        end
      end)
    end
  end

  defp claim(%{status: :queued} = attempt, incident, run) do
    if incident.status == :running and not incident.cancel_requested and run.active and
         run.status == :running and run.generation == attempt.case_generation do
      with {:ok, claimed} <-
             Cases.mark_verification_dispatching(
               attempt,
               attempt.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             ) do
        %VerificationClaim{state: :claimed, attempt: claimed}
      end
    else
      now = DateTime.utc_now()

      with {:ok, terminal} <-
             Cases.record_verification_no_send(
               attempt,
               attempt.revision,
               %{
                 outcome_category: "cancelled_before_verification",
                 facts: %{},
                 provider_evidence: %{
                   "message" => "Case stopped before fresh verification was dispatched"
                 },
                 observed_at: now,
                 completed_at: now
               },
               authorize?: false
             ) do
        %VerificationClaim{state: :terminal, attempt: terminal}
      end
    end
  end

  defp claim(%{status: :dispatching} = attempt, _incident, _run) do
    now = DateTime.utc_now()

    with {:ok, terminal} <-
           Cases.record_verification_outcome(
             attempt,
             attempt.revision,
             %{
               status: :unknown,
               outcome_category: "verification_interrupted",
               facts: %{},
               provider_evidence: %{
                 "message" => "Verification ownership was lost after the dispatch marker"
               },
               observed_at: now,
               completed_at: now
             },
             authorize?: false
           ) do
      %VerificationClaim{state: :terminal, attempt: terminal}
    end
  end

  defp claim(%{status: status} = attempt, _incident, _run) when status in @terminal,
    do: %VerificationClaim{state: :terminal, attempt: attempt}

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Verification dispatch input is unavailable"}
      result -> result
    end
  end
end
