defmodule Opsonde.Audits.AuditSchedule.Actions.Create do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Opsonde.Audits
  alias Opsonde.Audits.AuditSchedule
  alias Opsonde.Audits.AuditSchedule.Scheduling
  alias Opsonde.Targets.{ManagementBoundary, Target}

  @impl true
  def run(input, _opts, _context) do
    arguments = normalize(input.arguments)
    now = DateTime.utc_now()

    result =
      with :ok <- validate_scope(arguments),
           {:ok, next_run_at} <-
             Scheduling.next_run(arguments.cron_expression, arguments.timezone, now) do
        Ash.transact([AuditSchedule, ManagementBoundary, Target], fn ->
          with :ok <- validate_scope_records(arguments),
               {:ok, schedule} <- create_record(arguments, next_run_at),
               {:ok, _job} <- enqueue(schedule) do
            schedule
          end
        end)
      end

    case result do
      {:error, message} when is_binary(message) ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :schedule, message: message)}

      other ->
        other
    end
  end

  defp normalize(arguments) do
    %{arguments | target_ids: arguments.target_ids |> Enum.uniq() |> Enum.sort()}
  end

  defp validate_scope(%{target_ids: [_ | _], management_boundary_id: nil}), do: :ok
  defp validate_scope(%{target_ids: [], management_boundary_id: id}) when is_binary(id), do: :ok

  defp validate_scope(_arguments),
    do: {:error, "Select Target IDs or one management boundary"}

  defp validate_scope_records(%{target_ids: [_ | _] = ids}) do
    Target
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, targets} when length(targets) == length(ids) ->
        if Enum.all?(targets, & &1.active),
          do: :ok,
          else: {:error, "Audit Target is inactive"}

      {:ok, _targets} ->
        {:error, "Audit Target is unavailable"}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_scope_records(%{management_boundary_id: id}) do
    ManagementBoundary
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{active: true}} -> :ok
      {:ok, nil} -> {:error, "Management boundary is unavailable"}
      {:ok, _boundary} -> {:error, "Management boundary is inactive"}
      {:error, _error} -> {:error, "Management boundary is unavailable"}
    end
  end

  defp create_record(arguments, next_run_at) do
    Audits.create_audit_schedule_record(
      %{
        name: arguments.name,
        objective: arguments.objective,
        timezone: arguments.timezone,
        cron_expression: arguments.cron_expression,
        report_language: arguments.report_language,
        target_ids: arguments.target_ids,
        management_boundary_id: arguments.management_boundary_id,
        active: true,
        next_run_at: next_run_at
      },
      authorize?: false
    )
  end

  defp enqueue(schedule) do
    schedule
    |> Opsonde.Audits.AuditWakeWorker.job()
    |> Oban.insert()
  end
end
