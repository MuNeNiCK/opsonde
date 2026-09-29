defmodule Opsonde.Targets.Adapters.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport

  @effect_capability "request.ssh.effect"

  @impl Opsonde.Providers.Adapter
  def type, do: "ssh"

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
       effects: [
         effect_operation(@effect_capability, "SSH"),
         shell_operation(@effect_capability)
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def classify_request(_state, request) do
    validation =
      case request.operation do
        "shell.execute" -> shell_script(request, @effect_capability)
        _other -> effect_command(request, @effect_capability)
      end

    with {:ok, _command} <- validation do
      {:ok, :effect}
    else
      _ -> {:error, :failed, "SSH command request is invalid"}
    end
  end

  @impl Opsonde.Providers.Target
  def observe(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands require effect authority"}

  @impl Opsonde.Providers.Target
  def effect(state, %{operation: "shell.execute"} = request, invocation) do
    with {:ok, script} <- shell_script(request, @effect_capability),
         result <-
           Transport.shell(state, request.connection.endpoint, script, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  def effect(state, request, invocation) do
    with {:ok, command} <- effect_command(request, @effect_capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, cancelled?(invocation)) do
      effect_result(result)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands cannot verify an effect"}

  defp effect_result({:ok, %Transport.ShellResult{} = result}) do
    {:ok, %Target.EffectResult{status: :applied, details: shell_facts(result)}}
  end

  defp effect_result({:ok, %Transport.Result{} = result}) do
    {:ok,
     %Target.EffectResult{
       status: if(result.exit_status == 0, do: :applied, else: :failed),
       details: facts(result)
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

  # Shared SSH request contract used by product profiles in addition to this
  # generic Method. Profiles may add operations, but reuse the same raw request.
  def effect_operation(capability, description) do
    %Target.Operation{
      capability: capability,
      operation: "command.execute",
      description: "Run one exact #{description} command after authority review",
      input_schema: request_schema("command")
    }
  end

  def shell_operation(capability) do
    %Target.Operation{
      capability: capability,
      operation: "shell.execute",
      description: "Send one exact interactive SSH shell script after authority review",
      input_schema: request_schema("script")
    }
  end

  def effect_command(request, capability),
    do: command(request, capability, "command.execute", "command")

  def shell_script(request, capability),
    do: command(request, capability, "shell.execute", "script")

  def facts(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  def shell_facts(result), do: %{"output" => encode(result.output)}

  defp command(request, capability, operation, field) do
    case request do
      %{
        capability: ^capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{^field => value} = parameters
      }
      when selectors == %{} and map_size(parameters) == 1 and is_binary(value) and
             byte_size(value) in 1..4_096 ->
        {:ok, value}

      _request ->
        {:error, :failed, "SSH request is invalid"}
    end
  end

  defp request_schema(field) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            field => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
          },
          "required" => [field],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end
end
