defmodule Opsonde.Providers.Provider.Actions.FailRuntimeContract do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{AI, Provider}

  @impl true
  def run(input, _opts, context) do
    %{id: id, expected_revision: expected_revision} = input.arguments

    with {:ok, provider} <- Providers.get_provider(id, authorize?: false),
         :ok <- ensure_current_ai(provider, expected_revision) do
      fail_contract(provider, expected_revision, context)
    end
  end

  defp ensure_current_ai(%{kind: :ai, revision: revision}, revision), do: :ok

  defp ensure_current_ai(%{revision: revision}, revision),
    do: {:error, AI.Error.exception(category: :invalid_input, message: "Provider is not AI")}

  defp ensure_current_ai(_provider, _expected_revision),
    do: {:error, Ash.Error.Changes.StaleRecord.exception(resource: Provider, field: :revision)}

  defp fail_contract(%{enabled: false, check_status: :failed} = provider, _revision, _context),
    do: {:ok, provider}

  defp fail_contract(provider, expected_revision, context) do
    Providers.record_provider_check(
      provider,
      expected_revision,
      :failed,
      :capability,
      "Runtime structured output contract failed",
      actor: context.actor,
      authorize?: false
    )
  end
end
