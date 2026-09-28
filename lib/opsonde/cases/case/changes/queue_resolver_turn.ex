defmodule Opsonde.Cases.Case.Changes.QueueResolverTurn do
  use Ash.Resource.Change

  alias Opsonde.Cases

  @impl true
  def change(changeset, _opts, _context) do
    source_id = Ash.Changeset.get_argument(changeset, :source_turn_id)
    next_id = Ash.Changeset.get_argument(changeset, :next_turn_id)
    current = changeset.data.pending_intent

    cond do
      not available?(current, source_id) ->
        Ash.Changeset.add_error(changeset,
          field: :pending_intent,
          message: "Case already has another pending decision"
        )

      not same_run?(changeset.data, source_id, next_id) ->
        Ash.Changeset.add_error(changeset,
          field: :next_turn_id,
          message: "Resolver Turn belongs to another Case or ResolutionRun"
        )

      true ->
        changeset
        |> Ash.Changeset.change_attribute(:pending_intent, %{
          "action" => "resolve_turn",
          "turn_id" => next_id,
          "source_turn_id" => source_id
        })
        |> Ash.Changeset.change_attribute(:stop_reason, nil)
        |> Ash.Changeset.change_attribute(:required_human_input, nil)
    end
  end

  defp available?(%{"action" => action, "turn_id" => source_id}, source_id)
       when action in ["resolve_turn", "route_resolver_decision"],
       do: true

  defp available?(current, _source_id) when map_size(current) == 0, do: true
  defp available?(_current, _source_id), do: false

  defp same_run?(incident, source_id, next_id) when source_id != next_id do
    with {:ok, source} <- Cases.get_turn(source_id, authorize?: false),
         {:ok, next_turn} <- Cases.get_turn(next_id, authorize?: false) do
      source.case_id == incident.id and next_turn.case_id == incident.id and
        source.resolution_run_id == next_turn.resolution_run_id
    else
      _unavailable -> false
    end
  end

  defp same_run?(_incident, _source_id, _next_id), do: false
end
