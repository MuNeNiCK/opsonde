defmodule Opsonde.Targets.Generic.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport
  alias Opsonde.Targets.Adapters.SSH.Command

  @observation_capability "native.ssh.observe"
  @effect_capability "native.ssh.effect"

  @impl Opsonde.Providers.Adapter
  def type, do: "generic-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      platform: "generic",
      method: "ssh",
      capabilities: [@observation_capability, @effect_capability]
    }
  end

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials), do: Transport.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "SSH check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    {observation, effect} =
      Command.operations(@observation_capability, @effect_capability, "SSH")

    {:ok,
     %Target.Capabilities{
       observations: [observation],
       effects: [effect]
     }}
  end

  @impl Opsonde.Providers.Target
  def preflight(_state, %{capability: @observation_capability} = request) do
    case Command.observation_command(request, @observation_capability) do
      {:ok, _command} -> :ok
      {:error, _category, _message} = error -> error
    end
  end

  def preflight(_state, _request),
    do: {:error, :failed, "Generic SSH observation is unsupported"}

  @impl Opsonde.Providers.Target
  def observe(state, request, invocation) do
    with {:ok, command} <- Command.observation_command(request, @observation_capability),
         {:ok, result} <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      {:ok,
       %Target.Observation{
         facts: Command.facts(result),
         observed_at: DateTime.utc_now()
       }}
    end
  end

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, command} <- Command.effect_command(request, @effect_capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(state, request, invocation) do
    with {:ok, command} <-
           Command.observation_command(request, @observation_capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      verification_result(result)
    end
  end

  defp effect_result({:ok, result}) do
    {:ok,
     %Target.EffectResult{
       status: if(result.exit_status == 0, do: :applied, else: :failed),
       details: Command.facts(result)
     }}
  end

  defp effect_result({:error, category, message})
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_result({:error, :cancelled, message}), do: {:error, :cancelled, message}
  defp effect_result({:error, _category, message}), do: {:error, :failed, message}

  defp verification_result({:ok, result}) do
    {:ok,
     %Target.Verification{
       status: :unknown,
       observed_at: DateTime.utc_now(),
       facts: Command.facts(result)
     }}
  end

  defp verification_result({:error, :cancelled, message}), do: {:error, :cancelled, message}

  defp verification_result({:error, category, message})
       when category in [:timeout, :timeout_after_dispatch],
       do: {:error, :timeout, message}

  defp verification_result({:error, category, message})
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp verification_result({:error, _category, message}), do: {:error, :failed, message}

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
