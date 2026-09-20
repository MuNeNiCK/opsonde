defmodule Opsonde.Cases.Case.Preparations.Queue do
  @moduledoc false

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _options, _context) do
    sort =
      case Ash.Query.get_argument(query, :sort) do
        :updated_asc -> [updated_at: :asc, id: :asc]
        :severity_desc -> [severity_rank: :desc, updated_at: :desc, id: :desc]
        _other -> [updated_at: :desc, id: :desc]
      end

    Ash.Query.sort(query, sort)
  end
end
