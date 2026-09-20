defmodule Opsonde.Audits.AuditRunWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :audits,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"audit_run_id" => id}} = job) when is_binary(id) do
    case Opsonde.Audits.AuditRunDispatch.run(id, final_attempt?: job.attempt >= job.max_attempts) do
      {:ok, _run} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Audit Run job arguments are invalid"}
end
