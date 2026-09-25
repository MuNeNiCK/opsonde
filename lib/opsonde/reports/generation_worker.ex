defmodule Opsonde.Reports.GenerationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Opsonde.Cases
  alias Opsonde.Reports

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"case_id" => case_id, "case_revision" => case_revision},
        attempt: attempt,
        max_attempts: max_attempts
      })
      when is_binary(case_id) and is_integer(case_revision) and case_revision > 0 do
    result =
      with {:ok, setting} <- Reports.current_setting(authorize?: false) do
        if setting.automatic_case_reports_enabled do
          Reports.generate_report(case_id, case_revision, authorize?: false)
        else
          {:ok, :disabled}
        end
      end

    case result do
      {:ok, _report_or_disabled} ->
        :ok

      {:error, error} when attempt >= max_attempts ->
        record_failure(case_id, case_revision, error)

      {:error, error} ->
        {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Report generation job arguments are invalid"}

  defp record_failure(case_id, case_revision, report_error) do
    event_key = "report-generation-failed:#{case_revision}"

    case Cases.case_event_by_idempotency(case_id, event_key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, nil} -> create_failure_event(case_id, case_revision, event_key, report_error)
      {:ok, _event} -> {:error, report_error}
      {:error, event_error} -> {:error, event_error}
    end
  end

  defp create_failure_event(case_id, case_revision, event_key, report_error) do
    case Cases.create_case_event_record(
           %{
             case_id: case_id,
             event_type: "report_generation_failed",
             idempotency_key: event_key,
             data: %{
               "case_revision" => case_revision,
               "required_action" => "Retry Report generation"
             }
           },
           authorize?: false
         ) do
      {:ok, _event} -> {:error, report_error}
      {:error, event_error} -> {:error, event_error}
    end
  end
end
