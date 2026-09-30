defmodule Opsonde.Targets.AccessMethod.Actions.Check do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Providers, Targets}
  alias Opsonde.Providers.Target.{Capabilities, CapabilitiesRequest, Connection}

  @impl true
  def run(input, _opts, context) do
    %{id: id, expected_revision: revision, invocation: invocation} = input.arguments

    with {:ok, method} <- Targets.get_access_method(id, authorize?: false),
         {:ok, target} <- Targets.get_target(method.target_id, authorize?: false),
         {:ok, begun} <-
           Targets.begin_access_method_check(method, revision, Ecto.UUID.generate(),
             actor: context.actor,
             authorize?: false
           ) do
      request = %CapabilitiesRequest{
        provider_revision: begun.provider_revision,
        connection: %Connection{endpoint: begun.endpoint}
      }

      # Both writes are actions around the role call. No transaction spans the network.
      result =
        Providers.check_target_connection(begun.provider_id, request, invocation,
          authorize?: false
        )

      with {:ok, current} <- Targets.get_access_method(id, authorize?: false) do
        {status, message, catalog} = outcome(result)

        with {:ok, recorded} <-
               Targets.record_access_method_check(
                 current,
                 current.revision,
                 begun.check_attempt_id,
                 begun.connection_revision,
                 target.revision,
                 status,
                 message,
                 catalog,
                 actor: context.actor,
                 authorize?: false
               ) do
          Targets.get_access_method(recorded.id, actor: context.actor, authorize?: false)
        end
      end
    end
  end

  defp outcome({:ok, %Capabilities{} = catalog}), do: {:passed, nil, catalog}

  defp outcome({:error, _error}),
    do:
      {:failed, "Connection check failed. Verify the endpoint, credentials and trust settings.",
       nil}
end
