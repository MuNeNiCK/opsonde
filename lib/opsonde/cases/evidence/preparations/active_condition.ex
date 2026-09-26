defmodule Opsonde.Cases.Evidence.Preparations.ActiveCondition do
  @moduledoc false

  use Ash.Resource.Preparation

  require Ash.Query

  alias Opsonde.Cases

  @impl true
  def prepare(query, _options, _context) do
    case Cases.active_conditions_for_case(Ash.Query.get_argument(query, :case_id),
           authorize?: false
         ) do
      {:ok, memberships} ->
        ids = Enum.map(memberships, & &1.condition_id)
        Ash.Query.filter(query, content["condition_id"] in ^ids)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end
end
