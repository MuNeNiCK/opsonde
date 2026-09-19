defmodule Opsonde.Cases.OperationAcceptanceWorker do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Cases.{Budget, Operation}

  use Oban.Worker,
    queue: :operations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :queue, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"proposal_id" => proposal_id}}) when is_binary(proposal_id) do
    case Cases.accept_operation(proposal_id, authorize?: false) do
      {:ok, _operation} -> :ok
      {:error, _error} = error -> require_attention(proposal_id, error)
    end
  end

  def perform(_job), do: {:cancel, "Operation acceptance job arguments are invalid"}

  defp require_attention(proposal_id, original_error) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false) do
      cond do
        operation_exists?(proposal.id) ->
          :ok

        incident.status == :needs_attention ->
          :ok

        proposal.status == :authorized and incident.status == :running and
          not incident.cancel_requested and run.status == :running and run.active ->
          pause(incident, run, proposal.id, original_error)

        true ->
          {:cancel, "Operation acceptance is no longer applicable"}
      end
    else
      _unavailable -> original_error
    end
  end

  defp operation_exists?(proposal_id) do
    match?(
      {:ok, %Operation{}},
      Cases.operation_by_proposal(proposal_id,
        authorize?: false,
        not_found_error?: false
      )
    )
  end

  defp pause(incident, run, proposal_id, original_error) do
    case Cases.require_case_attention(
           incident.id,
           incident.revision,
           run.id,
           run.revision,
           Budget.key("operation:acceptance:failure", proposal_id),
           "Operation acceptance failed",
           incident.pending_intent,
           "Review the current authority and Target policy, then resume the Case",
           authorize?: false
         ) do
      {:ok, _case} -> :ok
      {:error, _error} -> original_error
    end
  end
end
