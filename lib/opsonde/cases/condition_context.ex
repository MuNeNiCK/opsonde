defmodule Opsonde.Cases.ConditionContext do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Cases.ResolverProjection
  alias Opsonde.Providers.AI

  # The completed Resolver Turn owns the Conditions considered when it made a
  # decision. An authorization based on that Turn must still see exactly those
  # Conditions. Callers taking a decision hold the Case admission lock.
  def current?(%{trigger_kind: :signal} = incident, source_turn_id) do
    with {:ok, turn} <- Cases.get_turn(source_turn_id, authorize?: false),
         {:ok, revisions} <- ResolverProjection.current_condition_revisions(incident) do
      {:ok,
       turn.case_id == incident.id and is_list(turn.result["condition_revisions"]) and
         revisions == turn.result["condition_revisions"]}
    end
  end

  def current?(_incident, _source_turn_id), do: {:ok, true}

  def affected_current?(incident, request_kind, claims) do
    with {:ok, conditions} <- ResolverProjection.current_conditions(incident) do
      {:ok, AI.valid_affected_conditions?(request_kind, claims, conditions)}
    end
  end
end
