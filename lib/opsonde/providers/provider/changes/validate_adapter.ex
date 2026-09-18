defmodule Opsonde.Providers.Provider.Changes.ValidateAdapter do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    adapter_type = Ash.Changeset.get_attribute(changeset, :adapter_type)
    role = Ash.Changeset.get_attribute(changeset, :role)

    case Opsonde.Providers.Registry.fetch(adapter_type) do
      {:ok, adapter} ->
        if Opsonde.Providers.Registry.role(adapter) == role do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :role,
            message: "does not match the selected adapter"
          )
        end

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :adapter_type,
          message: "is not available"
        )
    end
  end
end
