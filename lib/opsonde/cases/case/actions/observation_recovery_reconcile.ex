defmodule Opsonde.Cases.Case.Actions.ObservationRecoveryReconcile do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Opsonde.Cases

  alias Opsonde.Cases.{
    Case,
    CaseAdmissionLock,
    CaseEvent,
    ConditionRecovery,
    Evidence,
    ResolutionRun,
    Turn
  }

  alias Opsonde.Cases.Case.Actions.SplitConditions

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent, Turn], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, incident} <- lock_case(input.arguments.id),
           {:ok, observation} <-
             Cases.get_operation(input.arguments.observation_operation_id,
               authorize?: false
             ),
           :ok <- current_observation(incident, observation),
           {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           true <-
             run.id == observation.resolution_run_id ||
               {:error, "Observation belongs to another resolution run"},
           {:ok, attempt} <- latest_verified_effect(incident.id, run.id) do
        reconcile(incident, observation, attempt)
      end
    end)
    |> case do
      {:ok, {:ok, %Case{} = incident}} -> {:ok, incident}
      {:ok, {:error, _error} = error} -> error
      {:error, _error} = error -> error
    end
  end

  defp reconcile(incident, _observation, nil), do: {:ok, incident}

  defp reconcile(incident, _observation, attempt) do
    wait_until =
      attempt.completed_at
      |> DateTime.add(ConditionRecovery.monitor_wait_seconds(), :second)

    if DateTime.compare(DateTime.utc_now(), wait_until) == :lt do
      {:ok, incident}
    else
      with {:ok, assessments} <- ConditionRecovery.assess_current(incident) do
        healthy? = Enum.any?(assessments, &(&1.status == :healthy))
        unresolved? = Enum.any?(assessments, &(&1.status != :healthy))

        if healthy? and unresolved? do
          with {:ok, cleared} <-
                 Cases.update_case_record(
                   incident,
                   incident.revision,
                   %{pending_intent: %{}},
                   authorize?: false
                 ) do
            SplitConditions.split_recovered(cleared, attempt, assessments)
          end
        else
          {:ok, incident}
        end
      end
    end
  end

  defp current_observation(incident, observation) do
    with true <-
           (incident.trigger_kind == :signal and incident.status == :running and
              not incident.cancel_requested and observation.case_id == incident.id and
              observation.request_kind == :observation and observation.status == :applied and
              is_struct(observation.completed_at, DateTime) and
              incident.pending_intent["operation_id"] == observation.id and
              incident.pending_intent["action"] in ["dispatch_operation", "verify_operation"]) ||
             {:error, "Observation is not current for this Signal Case"},
         {:ok, %Evidence{} = evidence} <-
           Cases.evidence_by_idempotency(
             incident.id,
             "operation:outcome:#{observation.id}",
             authorize?: false
           ),
         true <-
           (evidence.kind == "observation" and evidence.source_ref == observation.id and
              evidence.content["status"] == "applied") ||
             {:error, "Observation evidence is unavailable"} do
      :ok
    end
  end

  defp latest_verified_effect(case_id, run_id) do
    with {:ok, operations} <- Cases.operations_for_case(case_id, authorize?: false) do
      operations
      |> Enum.filter(&(&1.request_kind == :effect and is_struct(&1.accepted_at, DateTime)))
      |> Enum.max_by(&DateTime.to_unix(&1.accepted_at, :microsecond), fn -> nil end)
      |> case do
        nil ->
          {:ok, nil}

        %{status: :applied, resolution_run_id: ^run_id} = operation ->
          case Cases.verification_attempt_by_operation(operation.id,
                 authorize?: false,
                 not_found_error?: false
               ) do
            {:ok,
             %{status: :verified, resolution_run_id: ^run_id, completed_at: %DateTime{}} = attempt} ->
              {:ok, attempt}

            {:ok, _other} ->
              {:ok, nil}

            {:error, _error} = error ->
              error
          end

        _other ->
          {:ok, nil}
      end
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Case{} = incident} -> {:ok, incident}
      {:ok, nil} -> {:error, "Case is unavailable"}
      {:error, _error} = error -> error
    end
  end
end
