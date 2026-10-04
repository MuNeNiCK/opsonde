defmodule Opsonde.Cases.Case.Actions.Reconnect do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Cases, Signals}
  alias Opsonde.Cases.Case.ReconnectSnapshot
  alias Opsonde.Cases.AIInvocation
  alias Opsonde.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Opsonde.Reports

  @impl true
  def run(input, _opts, context) do
    case_id = input.arguments.id
    opts = [actor: context.actor]

    with {:ok, incident} <-
           Cases.get_case(case_id, Keyword.put(opts, :load, AIInvocation.usage_aggregates())),
         {:ok, history} <- Cases.condition_membership_history_for_case(case_id, authorize?: false),
         {:ok, conditions} <- current_conditions(incident, history),
         {:ok, condition_context} <- latest_condition_context(incident, conditions, opts),
         {:ok, runs} <- Cases.resolution_runs_for_case(case_id, opts),
         {:ok, proposals} <- Cases.proposal_summaries_for_case(case_id, opts),
         {:ok, operations} <- Cases.operation_summaries_for_case(case_id, opts),
         {:ok, attempts} <- Cases.verification_summaries_for_case(case_id, opts),
         {:ok, reports} <- Reports.report_summaries_for_case(case_id, opts) do
      {:ok,
       %ReconnectSnapshot{
         case: incident,
         ai_usage: AIInvocation.usage_summary(incident),
         conditions: conditions,
         condition_history: history,
         condition_context: condition_context,
         resolution_runs: runs,
         proposals: proposals,
         operations: operations,
         verification_attempts: attempts,
         reports: reports
       }}
    end
  end

  defp latest_condition_context(_incident, [], _opts),
    do: {:ok, %{groups: nil, assessments: nil}}

  defp latest_condition_context(incident, conditions, opts) do
    revisions =
      Opsonde.Cases.Case.ConditionContext.condition_revisions(
        Enum.map(conditions, & &1.condition)
      )

    with {:ok, groups} <-
           Cases.latest_turn_condition_context(incident.id, revisions, "condition_groups", opts),
         {:ok, assessments} <-
           Cases.latest_turn_condition_context(
             incident.id,
             revisions,
             "condition_assessments",
             opts
           ) do
      {:ok, %{groups: List.first(groups), assessments: List.first(assessments)}}
    end
  end

  defp current_conditions(incident, history) do
    memberships = Enum.filter(history, &is_nil(&1.detached_at))

    with {:ok, assessments} <- current_assessments(incident, memberships) do
      memberships
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

  defp current_assessments(_incident, []), do: {:ok, %{}}

  defp current_assessments(incident, _memberships) do
    case ConditionRecovery.assess_current(incident) do
      {:ok, items} -> {:ok, Map.new(items, &{&1.condition_id, &1})}
      {:error, %ConditionRecovery.EffectIncomplete{}} -> {:ok, %{}}
      {:error, _cause} = error -> error
    end
  end
end
