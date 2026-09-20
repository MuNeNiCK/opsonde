defmodule Opsonde.Targets.NativeShell do
  @moduledoc false

  alias Opsonde.Providers.Target

  @read_commands ~w(
    cat cut date df dmesg du ethtool file find free getent grep head hostname
    id iostat ip journalctl ls lscpu lsblk lsof mpstat pgrep pidof printenv ps pwd
    readlink realpath rg ss stat systemctl tail top uname uptime vmstat wc who whoami
  )

  @forbidden_tokens [";", "&&", "||", ">", "<", "`", "$(", "\n", "\r"]

  def operations(capability, description) do
    schema = command_schema()
    output = output_schema()

    {
      %Target.Operation{
        capability: capability,
        operation: "command.observe",
        description: "Run one exact non-mutating #{description} command and return raw output",
        input_schema: schema,
        output_schema: output,
        verification_schema: Map.put(output, "minProperties", 1),
        native?: true
      },
      %Target.Operation{
        capability: capability,
        operation: "command.execute",
        description: "Run one exact #{description} command after authority review",
        input_schema: schema,
        native?: true
      }
    }
  end

  def observation_command(request, capability) do
    with {:ok, command} <- command(request, capability, "command.observe"),
         true <- readonly?(command) do
      {:ok, command}
    else
      false -> {:error, :failed, "Command is not provably non-mutating; submit it as an effect"}
      {:error, _category, _message} = error -> error
    end
  end

  def effect_command(request, capability),
    do: command(request, capability, "command.execute")

  def command(request, capability, operation) do
    case request do
      %{
        capability: ^capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{"command" => command}
      }
      when selectors == %{} and is_binary(command) and byte_size(command) in 1..4_096 ->
        {:ok, command}

      _request ->
        {:error, :failed, "Native SSH request is invalid"}
    end
  end

  def readonly?(command) when is_binary(command) do
    not Enum.any?(@forbidden_tokens, &String.contains?(command, &1)) and
      command
      |> String.split("|", trim: true)
      |> Enum.all?(&readonly_segment?/1)
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

  def output_schema do
    encoded = %{
      "type" => "object",
      "properties" => %{
        "encoding" => %{"type" => "string", "enum" => ["utf-8", "base64"]},
        "value" => %{"type" => "string", "maxLength" => 65_536}
      },
      "required" => ["encoding", "value"],
      "additionalProperties" => false
    }

    %{
      "type" => "object",
      "properties" => %{
        "stdout" => encoded,
        "stderr" => encoded,
        "exit_status" => %{"type" => "integer"}
      },
      "required" => ["stdout", "stderr", "exit_status"],
      "additionalProperties" => false
    }
  end

  defp readonly_segment?(segment) do
    case segment |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [command] ->
        Path.basename(command) in @read_commands

      [command, arguments] ->
        command = Path.basename(command)
        command in @read_commands and readonly_arguments?(command, arguments)

      _empty ->
        false
    end
  end

  defp readonly_arguments?("date", arguments), do: excludes?(arguments, ["-s", "--set"])

  defp readonly_arguments?("dmesg", arguments),
    do:
      excludes?(arguments, [
        "-c",
        "-C",
        "--clear",
        "-n",
        "--console-level",
        "--console-on",
        "--console-off"
      ])

  defp readonly_arguments?("find", arguments),
    do:
      excludes?(arguments, [
        "-delete",
        "-exec",
        "-execdir",
        "-ok",
        "-okdir",
        "-fprint",
        "-fprintf",
        "-fls"
      ])

  defp readonly_arguments?("hostname", _arguments), do: false

  defp readonly_arguments?("ip", arguments),
    do:
      excludes?(arguments, [
        " add ",
        " del ",
        " delete ",
        " set ",
        " replace ",
        " flush ",
        " -batch ",
        " batch ",
        " exec "
      ])

  defp readonly_arguments?("ethtool", arguments),
    do: not String.starts_with?(String.trim(arguments), "-")

  defp readonly_arguments?("journalctl", arguments),
    do:
      excludes?(arguments, [
        "--vacuum-size",
        "--vacuum-time",
        "--vacuum-files",
        "--rotate",
        "--flush",
        "--sync",
        "--relinquish-var"
      ])

  defp readonly_arguments?("systemctl", arguments) do
    command =
      arguments
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()

    command in ~w(status show cat list-units list-unit-files is-active is-enabled is-failed)
  end

  defp readonly_arguments?(_command, _arguments), do: true

  defp excludes?(arguments, tokens) do
    padded = " " <> arguments <> " "
    not Enum.any?(tokens, &String.contains?(padded, &1))
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end
end
