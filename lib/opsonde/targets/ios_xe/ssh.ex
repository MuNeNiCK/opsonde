defmodule Opsonde.Targets.IOSXE.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Targets.IOSXE
  alias Opsonde.Transports.SSH, as: Transport

  @impl Opsonde.Providers.Adapter
  def type, do: "ios-xe-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials), do: Transport.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(%Transport.Config{} = state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IOS XE SSH check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation), do: {:ok, IOSXE.capabilities()}

  @impl Opsonde.Providers.Target
  def observe(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             operation,
             cancelled?(invocation)
           ) do
      IOSXE.observation(facts, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(
        state,
        request.connection.endpoint,
        operation,
        cancelled?(invocation)
      )
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%Transport.Config{} = state, request, invocation) do
    with {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             {:interface, name},
             cancelled?(invocation)
           ) do
      IOSXE.verification(facts, expected, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  defp observe_operation(state, endpoint, :system, cancelled?) do
    script =
      script([
        "show running-config | include ^hostname",
        "show version | include Cisco IOS XE Software, Version"
      ])

    with {:ok, output} <- run_shell(state, endpoint, script, cancelled?),
         [hostname] <- capture(output, ~r/^hostname\s+(\S+)\s*$/m),
         [version] <- capture(output, ~r/^Cisco IOS XE Software, Version[ \t]+([^\r\n]+)/m) do
      {:ok, %{"hostname" => hostname, "version" => String.trim(version)}, output}
    else
      {:error, _category, _message} = error -> error
      _output -> {:error, :failed, "IOS XE SSH system response is invalid"}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, cancelled?) do
    script =
      script([
        "show running-config interface #{name}",
        "show interfaces #{name} | include line protocol|Description|input errors|output errors"
      ])

    with {:ok, output} <- run_shell(state, endpoint, script, cancelled?),
         {:ok, facts} <- interface_facts(name, output) do
      {:ok, facts, output}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, cancelled?) do
    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["description"], expected, "description"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(["configure terminal", "interface #{name}", "description #{desired}", "end"]),
             cancelled?
           ),
         :ok <- accepted(output) do
      IOSXE.applied(%{
        "interface" => name,
        "description" => desired,
        "evidence" => evidence(output)
      })
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, cancelled?) do
    command = if desired, do: "no shutdown", else: "shutdown"

    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["enabled"], expected, "enabled"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(["configure terminal", "interface #{name}", command, "end"]),
             cancelled?
           ),
         :ok <- accepted(output) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired, "evidence" => evidence(output)})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp run_shell(state, endpoint, script, cancelled?) do
    case Transport.shell(state, endpoint, script, cancelled?) do
      {:ok, %Transport.ShellResult{output: output}} -> {:ok, normalize(output)}
      {:error, category, message} -> {:error, category, message}
    end
  end

  defp interface_facts(name, output) do
    line =
      Regex.run(
        ~r/^#{Regex.escape(name)} is (administratively down|up|down), line protocol is (up|down)/m,
        output,
        capture: :all_but_first
      )

    case line do
      [admin, operational] ->
        description =
          case capture(output, ~r/^\s*Description:\s*(.*?)\s*$/m) do
            [value] -> value
            [] -> running_description(name, output)
          end

        {:ok,
         %{
           "name" => name,
           "description" => description,
           "enabled" => admin != "administratively down",
           "admin_status" => if(admin == "administratively down", do: "down", else: admin),
           "oper_status" => operational,
           "input_errors" => error_count(output, "input"),
           "output_errors" => error_count(output, "output")
         }}

      _line ->
        {:error, :not_found, "IOS XE interface was not found"}
    end
  end

  defp running_description(name, output) do
    pattern =
      ~r/^interface #{Regex.escape(name)}\s*$\n(?:^[ !].*$\n)*?^ description\s+(.+?)\s*$/m

    case capture(output, pattern) do
      [description] -> description
      [] -> nil
    end
  end

  defp error_count(output, direction) do
    case capture(output, ~r/^\s*([0-9,]+) #{direction} errors,/m) do
      [value] -> value |> String.replace(",", "") |> String.to_integer()
      [] -> nil
    end
  end

  defp accepted(output) do
    if Regex.match?(
         ~r/% (Invalid input|Incomplete command|Ambiguous command|Command rejected)/i,
         output
       ),
       do: {:error, :rejected, "IOS XE SSH command was rejected"},
       else: :ok
  end

  defp script(commands),
    do:
      Enum.join(["terminal length 0", "terminal width 511" | commands] ++ ["exit"], "\n") <> "\n"

  defp normalize(output) do
    output
    |> String.replace("\r", "")
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
  end

  defp capture(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      nil -> []
      values -> values
    end
  end

  defp evidence(output), do: %{"transport" => "ssh-cli", "output" => output}
  defp matches(observed, expected, _field) when observed == expected, do: :ok
  defp matches(observed, _expected, field), do: {:stale, observed, field}
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
