defmodule Opsonde.Cases.Operation.Changes.SetResourceScope do
  use Ash.Resource.Change

  alias Opsonde.Cases.Operation.ResourceScope

  @impl true
  def change(changeset, _opts, _context) do
    capability = Ash.Changeset.get_attribute(changeset, :capability)
    selectors = Ash.Changeset.get_attribute(changeset, :selectors)

    Ash.Changeset.change_attribute(
      changeset,
      :resource_scope,
      ResourceScope.key(capability, selectors)
    )
  end
end
