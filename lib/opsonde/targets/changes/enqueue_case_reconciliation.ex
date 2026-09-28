defmodule Opsonde.Targets.Changes.EnqueueCaseReconciliation do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      resource =
        case changeset.resource do
          Opsonde.Targets.Target -> "target"
          Opsonde.Targets.ExternalIdentity -> "external_identity"
        end

      args = %{"resource" => resource, "resource_id" => result.id, "revision" => result.revision}

      case args |> Opsonde.Cases.TargetCatalogReconciliationWorker.new() |> Oban.insert() do
        {:ok, _job} -> {:ok, result}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
