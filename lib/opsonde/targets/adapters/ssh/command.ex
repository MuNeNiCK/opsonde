defmodule Opsonde.Targets.Adapters.SSH.Command do
  @moduledoc false

  alias Opsonde.Providers.Target

  def effect_operation(capability, description) do
    %Target.Operation{
      capability: capability,
      operation: "command.execute",
      description: "Run one exact #{description} command after authority review",
      input_schema: command_schema()
    }
  end

  def effect_command(request, capability),
    do: command(request, capability, "command.execute")

  defp command(request, capability, operation) do
    case request do
      %{
        capability: ^capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{"command" => command} = parameters
      }
      when selectors == %{} and map_size(parameters) == 1 and is_binary(command) and
             byte_size(command) in 1..4_096 ->
        {:ok, command}

      _request ->
        {:error, :failed, "SSH request is invalid"}
    end
  end

  def facts(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  def command_schema do
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

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end
end
