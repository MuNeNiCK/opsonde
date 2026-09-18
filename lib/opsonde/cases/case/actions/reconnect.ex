defmodule Opsonde.Cases.Case.Actions.Reconnect do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Cases
  alias Opsonde.Cases.ReconnectSnapshot

  @impl true
  def run(input, _opts, context) do
    case_id = input.arguments.id
    opts = [actor: context.actor]

    with {:ok, incident} <- Cases.get_case(case_id, opts),
         {:ok, runs} <- Cases.resolution_runs_for_case(case_id, opts),
         {:ok, proposals} <- Cases.proposals_for_case(case_id, opts),
         {:ok, operations} <- Cases.operations_for_case(case_id, opts),
         {:ok, attempts} <- Cases.verification_attempts_for_case(case_id, opts) do
      {:ok,
       %ReconnectSnapshot{
         case: incident,
         resolution_runs: runs,
         proposals: proposals,
         operations: operations,
         verification_attempts: attempts
       }}
    end
  end
end
