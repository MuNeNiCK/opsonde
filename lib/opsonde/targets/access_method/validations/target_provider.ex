defmodule Opsonde.Targets.AccessMethod.Validations.TargetProvider do
  use Ash.Resource.Validation

  alias Opsonde.{Providers, Targets}
  alias Opsonde.Providers.Registry
  alias Opsonde.Providers.Target.AccessMethodProfile
  alias Opsonde.Targets.TypeCatalog

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
        validate_profile(changeset, provider)

      {:error, _error} ->
        {:error,
         field: :provider_id,
         message: "must reference an enabled target Provider at the specified revision"}
    end
  end

  defp validate_profile(changeset, provider) do
    case Registry.fetch(provider.adapter_type, Providers.Target) do
      {:ok, adapter} ->
        case adapter.access_method_profile() do
          :unrestricted ->
            :ok

          %AccessMethodProfile{} = profile ->
            validate_binding(changeset, provider, profile)

          _invalid ->
            {:error, field: :provider_id, message: "Target Provider has no binding profile"}
        end

      {:error, _reason} ->
        {:error, field: :provider_id, message: "must reference a Target Provider adapter"}
    end
  end

  defp validate_binding(changeset, provider, profile) do
    target_id = Ash.Changeset.get_attribute(changeset, :target_id)
    capabilities = Ash.Changeset.get_attribute(changeset, :capabilities)
    endpoint = Ash.Changeset.get_attribute(changeset, :endpoint)

    with true <- Ash.Changeset.get_attribute(changeset, :method) == profile.method,
         true <-
           not profile.configuration_endpoint? or endpoint == provider.configuration["endpoint"],
         true <- is_list(capabilities) and capabilities != [],
         true <- Enum.uniq(capabilities) == capabilities,
         true <- Enum.all?(capabilities, &(&1 in profile.capabilities)),
         true <- Enum.all?(profile.required_capabilities, &(&1 in capabilities)),
         {:ok, %{active: true} = target} <- Targets.get_target(target_id, authorize?: false),
         true <- TypeCatalog.allows_method?(target.type_id, provider.adapter_type) do
      :ok
    else
      _other ->
        {:error,
         field: :method,
         message: "Access Method must match its checked Provider, Target and capabilities"}
    end
  end
end
