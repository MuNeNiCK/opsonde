defmodule Opsonde.Targets.Validations.TargetProvider do
  use Ash.Resource.Validation

  alias Opsonde.Providers

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    provider_id = Ash.Changeset.get_attribute(changeset, :provider_id)
    provider_revision = Ash.Changeset.get_attribute(changeset, :provider_revision)

    case Providers.load_provider_for_invocation(
           provider_id,
           provider_revision,
           :target,
           authorize?: false
         ) do
      {:ok, _provider} ->
        :ok

      {:error, _error} ->
        {:error,
         field: :provider_id,
         message: "must reference an enabled target Provider at the specified revision"}
    end
  end
end
