defmodule Opsonde.Targets.Changes.ReconcileSignalCases do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      change_key =
        [inspect(changeset.resource), result.id, Map.get(result, :revision, 1)]
        |> Enum.join(":")

      case change_key
           |> then(&Opsonde.Signals.CaseReconciliationWorker.new(%{"change_key" => &1}))
           |> Oban.insert() do
        {:ok, _job} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
