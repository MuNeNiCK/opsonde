defmodule Opsonde.Targets.AccessMethod.Validations.TargetProvider do
  use Ash.Resource.Validation

  alias Opsonde.Providers
  alias Opsonde.Targets.BMC.AccessBinding

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
      {:ok, provider} ->
        with :ok <- AccessBinding.validate(changeset, provider) do
          validate_http(changeset, provider)
        end

      {:error, _error} ->
        {:error,
         field: :provider_id,
         message: "must reference an enabled target Provider at the specified revision"}
    end
  end

  defp validate_http(changeset, %{adapter_type: "generic-http"} = provider) do
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)
    capabilities = Ash.Changeset.get_attribute(changeset, :capabilities)

    if Ash.Changeset.get_attribute(changeset, :method) == "http_get" and
         endpoint == provider.configuration["endpoint"] and
         capabilities == ["observe.http"] do
      :ok
    else
      {:error,
       field: :endpoint,
       message:
         "HTTP Access Method must use its checked Provider endpoint and observe.http capability"}
    end
  end

  defp validate_http(_changeset, _provider), do: :ok
end
