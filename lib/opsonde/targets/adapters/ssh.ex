defmodule Opsonde.Targets.Adapters.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport
  alias Opsonde.Targets.Adapters.SSH.Command

  @effect_capability "request.ssh.effect"

  @impl Opsonde.Providers.Adapter
  def type, do: "ssh-exec"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "ssh",
      capabilities: [@effect_capability]
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
    {:ok,
     %Target.Capabilities{
       observations: [],
       effects: [Command.effect_operation(@effect_capability, "SSH")]
     }}
  end

  @impl Opsonde.Providers.Target
  def classify_request(_state, request) do
    with {:ok, _command} <- Command.effect_command(request, @effect_capability) do
      {:ok, :effect}
    else
      _ -> {:error, :failed, "SSH command request is invalid"}
    end
  end

  @impl Opsonde.Providers.Target
  def observe(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands require effect authority"}

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, command} <- Command.effect_command(request, @effect_capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands cannot verify an effect"}

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

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
