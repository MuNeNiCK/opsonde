defmodule Opsonde.Cases.ReviewWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"proposal_id" => proposal_id}}) when is_binary(proposal_id),
    do: Opsonde.Cases.ReviewDelivery.run(proposal_id)

  def perform(_job), do: {:cancel, "Reviewer job arguments are invalid"}
end
