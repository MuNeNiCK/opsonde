defmodule Opsonde.Cases.VerificationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :operations,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"verification_attempt_id" => id}}) when is_binary(id),
    do: Opsonde.Cases.VerificationDelivery.run(id)

  def perform(_job), do: {:cancel, "Verification job arguments are invalid"}
end
