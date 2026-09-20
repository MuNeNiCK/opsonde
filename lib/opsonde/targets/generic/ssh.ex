defmodule Opsonde.Targets.Generic.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport
  alias Opsonde.Targets.NativeShell

  @capability "native.ssh"

  @impl Opsonde.Providers.Adapter
  def type, do: "generic-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

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
    {observation, effect} = NativeShell.operations(@capability, "SSH")

    {:ok,
     %Target.Capabilities{
       observations: [observation],
       effects: [effect]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(state, request, invocation) do
    with {:ok, command} <- NativeShell.observation_command(request, @capability),
         {:ok, result} <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      {:ok,
       %Target.Observation{
         facts: NativeShell.facts(result),
         observed_at: DateTime.utc_now()
       }}
    end
  end

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, command} <- NativeShell.effect_command(request, @capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(state, request, invocation) do
    with {:ok, command} <- NativeShell.command(request, @capability, "command.observe"),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      verification_result(result)
    end
  end

  defp effect_result({:ok, result}) do
    {:ok,
     %Target.EffectResult{
       status: if(result.exit_status == 0, do: :applied, else: :failed),
       details: NativeShell.facts(result)
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
       facts: NativeShell.facts(result)
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
