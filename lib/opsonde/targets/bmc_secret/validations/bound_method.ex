defmodule Opsonde.Targets.BMCSecret.Validations.BoundMethod do
  use Ash.Resource.Validation

  alias Opsonde.Targets.BMC.CurrentAccessMethod

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    method_id = Ash.Changeset.get_attribute(changeset, :access_method_id)

    case CurrentAccessMethod.get(method_id) do
      {:ok, _method} ->
        :ok

      {:error, _reason} ->
        {:error, field: :access_method_id, message: "must be an active BMC Access Method"}
    end
  end
end
