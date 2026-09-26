defmodule Opsonde.Cases.Case.Actions.RecoveryCompletion do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Cases.ConditionRecovery
  alias Opsonde.Reports.GenerationWorker

  # Internal step shared by Case actions. The caller owns the transaction and
  # proves that its recovery evidence is current before entering this step.
  def complete(incident, run, idempotency_key, data) do
    now = DateTime.utc_now()

    with :ok <- condition_completion_ready(incident),
         {:ok, resolved} <-
           Cases.update_case_record(
             incident,
             incident.revision,
             %{
               status: :resolved,
               resolved_at: now,
               pending_intent: %{},
               stop_reason: nil,
               required_human_input: nil
             },
             authorize?: false
           ),
         {:ok, _completed} <-
           Cases.retire_resolution_run(
             run,
             run.revision,
             %{status: :completed, ended_at: now},
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "case_resolved",
               idempotency_key: idempotency_key,
               data: data
             },
             authorize?: false
           ),
         {:ok, _job} <-
           %{"case_id" => resolved.id, "case_revision" => resolved.revision}
           |> GenerationWorker.new()
           |> Oban.insert() do
      {:ok, resolved}
    end
  end

  defp condition_completion_ready(%{trigger_kind: :signal} = incident) do
    with {:ok, assessments} <- ConditionRecovery.assess_current(incident),
         true <-
           ConditionRecovery.all_healthy?(assessments) ||
             {:error, "Some Signal Conditions lack current subject recovery proof"} do
      :ok
    end
  end

  defp condition_completion_ready(_incident), do: :ok
end
