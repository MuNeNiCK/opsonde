defmodule Opsonde.Cases.Case.Actions.Reconnect do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Cases, Signals}
  alias Opsonde.Cases.Case.ReconnectSnapshot
  alias Opsonde.Cases.ConditionRecovery
  alias Opsonde.Reports

  @impl true
  def run(input, _opts, context) do
    case_id = input.arguments.id
    opts = [actor: context.actor]

    with {:ok, incident} <- Cases.get_case(case_id, opts),
         {:ok, history} <- Cases.condition_membership_history_for_case(case_id, authorize?: false),
         {:ok, conditions} <- current_conditions(incident, history),
         {:ok, runs} <- Cases.resolution_runs_for_case(case_id, opts),
         {:ok, proposals} <- Cases.proposals_for_case(case_id, opts),
         {:ok, operations} <- Cases.operations_for_case(case_id, opts),
         {:ok, attempts} <- Cases.verification_attempts_for_case(case_id, opts),
         {:ok, reports} <- Reports.reports_for_case(case_id, opts) do
      {:ok,
       %ReconnectSnapshot{
         case: incident,
         conditions: conditions,
         condition_history: history,
         resolution_runs: runs,
         proposals: proposals,
         operations: operations,
         verification_attempts: attempts,
         reports: reports
       }}
    end
  end

  defp current_conditions(incident, history) do
    assessments =
      case ConditionRecovery.assess_current(incident) do
        {:ok, items} -> Map.new(items, &{&1.condition_id, &1})
        {:error, _reason} -> %{}
      end

    history
    |> Enum.filter(&is_nil(&1.detached_at))
    |> Enum.reduce_while({:ok, []}, fn membership, {:ok, items} ->
      case Signals.get_condition(membership.condition_id, authorize?: false) do
        {:ok, condition} ->
          assessment = Map.get(assessments, condition.id)

          {:cont,
           {:ok,
            [%{condition: condition, membership: membership, assessment: assessment} | items]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end
end
