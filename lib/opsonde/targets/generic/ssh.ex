defmodule Opsonde.Targets.Generic.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport

  @capability "effect.command"
  @operation "command.execute"

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
    {:ok,
     %Target.Capabilities{
       observations: [],
       effects: [
         %Target.Operation{
           capability: @capability,
           operation: @operation,
           description: "Execute one exact command as an effect and return raw SSH output",
           input_schema: command_schema()
         }
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(_state, _request, _invocation),
    do: {:error, :failed, "Generic SSH commands require effect authorization"}

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, command} <- exact_command(request),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(state, request, invocation) do
    with {:ok, command} <- exact_command(request),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      verification_result(result)
    end
  end

  defp exact_command(%{
         capability: @capability,
         operation: @operation,
         selectors: selectors,
         parameters: %{"command" => command}
       })
       when selectors == %{} and is_binary(command) and byte_size(command) in 1..4_096,
       do: {:ok, command}

  defp exact_command(_request), do: {:error, :failed, "Generic SSH request is invalid"}

  defp effect_result({:ok, result}) do
    {:ok,
     %Target.EffectResult{
       status: if(result.exit_status == 0, do: :applied, else: :failed),
       details: evidence(result)
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
       facts: evidence(result)
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

  defp evidence(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end

  defp command_schema do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
          },
          "required" => ["command"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
