defmodule Opsonde.Cases.SignalCaseReconciliationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Opsonde.Cases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"change_key" => change_key}}) when is_binary(change_key) do
    with {:ok, incidents} <- Cases.active_unresolved_signal_cases(authorize?: false) do
      result =
        Enum.reduce_while(incidents, {:ok, false}, fn incident, {:ok, busy?} ->
          case wake(incident, change_key) do
            :ok -> {:cont, {:ok, busy?}}
            :busy -> {:cont, {:ok, true}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      case result do
        {:ok, true} -> {:error, "Signal Case still has an active Resolver Turn"}
        {:ok, false} -> :ok
        {:error, _error} = error -> error
      end
    end
  end

  def perform(_job), do: {:cancel, "Signal Case reconciliation arguments are invalid"}

  defp wake(incident, change_key) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, started} <- Cases.started_turns_for_run(run.id, authorize?: false) do
      if started == [] do
        start_turn(incident, run, change_key)
      else
        :busy
      end
    end
  end

  defp start_turn(incident, run, change_key) do
    key = "target-catalog:" <> digest([incident.id, change_key])

    case Cases.start_turn(
           incident.id,
           run.id,
           key,
           %{"objective" => "Re-evaluate the incident after the Target catalog changed"},
           %{"action" => "continue"},
           "Review Resolver limits",
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate, :exhausted] -> :ok
      {:error, _error} = error -> already_started_or(error, run.id)
    end
  end

  defp already_started_or(error, run_id) do
    case Cases.started_turns_for_run(run_id, authorize?: false) do
      {:ok, [_started | _rest]} -> :ok
      _missing -> error
    end
  end

  defp digest(parts) do
    raw = Enum.join(parts, ":")
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
