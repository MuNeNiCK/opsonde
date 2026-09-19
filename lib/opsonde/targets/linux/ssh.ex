defmodule Opsonde.Targets.Linux.SSH do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport

  @identity {"observe.identity", "linux.identity.inspect"}
  @processes {"observe.processes", "linux.process.list"}
  @service {"observe.service", "linux.service.inspect"}
  @journal {"observe.journal", "linux.journal.read"}
  @restart {"effect.service", "linux.service.restart"}
  @unit_pattern ~r/^[A-Za-z0-9_.@:-]+\.service$/
  @digest_pattern ~r/^[a-f0-9]{64}$/
  @service_fields %{
    "Id" => "unit",
    "LoadState" => "load_state",
    "ActiveState" => "active_state",
    "SubState" => "sub_state",
    "UnitFileState" => "unit_file_state",
    "FragmentPath" => "fragment_path",
    "DropInPaths" => "drop_in_paths",
    "NeedDaemonReload" => "need_daemon_reload",
    "ExecMainPID" => "main_pid",
    "DefinitionSHA256" => "definition_sha256"
  }
  @verifiable_fields ~w(load_state active_state sub_state unit_file_state need_daemon_reload definition_sha256)

  defmodule State do
    @moduledoc false
    @enforce_keys [:transport, :privilege]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "linux-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) do
    {privilege, transport_configuration} = Map.pop(configuration, "privilege", "none")

    with true <- privilege in ["none", "sudo"],
         {:ok, transport} <- Transport.build(transport_configuration, credentials) do
      {:ok, %State{transport: transport, privilege: privilege}}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{transport: transport}, %{"endpoint" => endpoint}) do
    case Transport.check(transport, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Linux SSH check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    {:ok,
     %Target.Capabilities{
       observations: [
         operation(
           @identity,
           "Inspect fixed Linux kernel and machine identity",
           empty_schema(),
           identity_output_schema()
         ),
         operation(
           @processes,
           "List a bounded set of Linux processes",
           process_schema(),
           processes_output_schema()
         ),
         operation(
           @service,
           "Inspect one systemd service and its definition",
           unit_schema(),
           service_output_schema(),
           service_verification_schema()
         ),
         operation(
           @journal,
           "Read bounded recent journal entries for one systemd service",
           journal_schema(),
           journal_output_schema()
         )
       ],
       effects: [
         operation(
           @restart,
           "Restart one systemd service only if its observed definition is unchanged",
           restart_schema()
         )
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with {:ok, command, decoder} <- observation_command(state, request),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- decode_observation(decoder, result) do
      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, request, invocation) do
    with {:ok, command} <- restart_command(state, request),
         result <- execute_raw(state, request, command, invocation) do
      effect_result(result)
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with {:ok, command, :service} <- observation_command(state, request),
         {:ok, expected} <- verification_expected(request.expected),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- decode_observation(:service, result) do
      status =
        cond do
          map_size(expected) == 0 -> :unknown
          Enum.all?(expected, fn {key, value} -> facts[key] == value end) -> :verified
          true -> :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         observed_at: DateTime.utc_now(),
         facts: facts,
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
      _error -> {:error, :failed, "Linux verification request is invalid"}
    end
  end

  defp observation_command(state, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, selectors, parameters}
      when {capability, operation} == @identity and selectors == %{} and parameters == %{} ->
        {:ok, "printf 'Kernel='; uname -srm; printf 'MachineId='; cat /etc/machine-id", :identity}

      {capability, operation, selectors, %{"limit" => limit}}
      when {capability, operation} == @processes and selectors == %{} and
             is_integer(limit) and limit in 1..100 ->
        {:ok, "ps -eo pid=,ppid=,stat=,comm= --sort=-pcpu | head -n #{limit}", :processes}

      {capability, operation, %{"unit" => unit}, parameters}
      when {capability, operation} == @service and parameters == %{} ->
        if valid_unit?(unit),
          do: {:ok, service_command(unit), :service},
          else: invalid_request()

      {capability, operation, %{"unit" => unit}, %{"lines" => lines}}
      when {capability, operation} == @journal and is_integer(lines) and lines in 1..200 ->
        if valid_unit?(unit),
          do: {:ok, journal_command(state, unit, lines), {:journal, unit}},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  defp restart_command(state, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, %{"unit" => unit}, %{"expected_definition_sha256" => expected}}
      when {capability, operation} == @restart ->
        if valid_unit?(unit) and is_binary(expected) and Regex.match?(@digest_pattern, expected),
          do: {:ok, restart_command(state, unit, expected)},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  defp service_command(unit) do
    quoted = shell_quote(unit)

    "definition=\"$(systemctl cat -- #{quoted})\" || exit $?; " <>
      "systemctl show --no-pager " <>
      "--property=Id,LoadState,ActiveState,SubState,UnitFileState,FragmentPath,DropInPaths,NeedDaemonReload,ExecMainPID " <>
      "-- #{quoted} || exit $?; " <>
      "printf 'DefinitionSHA256='; printf '%s' \"$definition\" | sha256sum | cut -d' ' -f1"
  end

  defp journal_command(state, unit, lines) do
    command =
      "journalctl --unit=#{shell_quote(unit)} --lines=#{lines} --no-pager --output=short-iso"

    privileged(state, command)
  end

  defp restart_command(state, unit, expected) do
    quoted = shell_quote(unit)

    "definition=\"$(systemctl cat -- #{quoted})\" || exit $?; " <>
      "actual=\"$(printf '%s' \"$definition\" | sha256sum | cut -d' ' -f1)\"; " <>
      "if [ \"$actual\" != '#{expected}' ]; then printf 'service definition changed\\n' >&2; exit 65; fi; " <>
      privileged(state, "systemctl restart -- #{quoted}")
  end

  defp execute(state, request, command, invocation) do
    case execute_raw(state, request, command, invocation) do
      {:ok, %Transport.Result{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, %Transport.Result{exit_status: status}} ->
        {:error, :failed, "Linux observation exited with status #{status}"}

      {:error, category, message} ->
        {:error, category, message}
    end
  end

  defp execute_raw(state, request, command, invocation) do
    Transport.exec(
      state.transport,
      request.connection.endpoint,
      command,
      cancelled?(invocation)
    )
  end

  defp decode_observation(:identity, result) do
    facts = parse_pairs(result.stdout)

    case facts do
      %{"Kernel" => kernel, "MachineId" => machine_id}
      when byte_size(kernel) > 0 and byte_size(machine_id) > 0 ->
        {:ok, %{"kernel" => kernel, "machine_id" => machine_id}}

      _facts ->
        {:error, :failed, "Linux identity response is invalid"}
    end
  end

  defp decode_observation(:processes, result) do
    processes =
      result.stdout
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ~r/\s+/, parts: 4, trim: true))

    if Enum.all?(processes, &(length(&1) == 4)) do
      {:ok,
       %{
         "processes" =>
           Enum.map(processes, fn [pid, parent_pid, state, command] ->
             %{
               "pid" => integer(pid),
               "parent_pid" => integer(parent_pid),
               "state" => state,
               "command" => command
             }
           end)
       }}
    else
      {:error, :failed, "Linux process response is invalid"}
    end
  end

  defp decode_observation(:service, result) do
    facts =
      result.stdout
      |> parse_pairs()
      |> Map.new(fn {key, value} -> {Map.get(@service_fields, key, key), value} end)

    if Enum.all?(
         ~w(unit load_state active_state sub_state definition_sha256),
         &nonempty?(facts[&1])
       ) and
         Regex.match?(@digest_pattern, facts["definition_sha256"]) do
      {:ok, facts}
    else
      {:error, :failed, "Linux service response is invalid"}
    end
  end

  defp decode_observation({:journal, unit}, result) do
    {:ok, %{"unit" => unit, "entries" => String.split(result.stdout, "\n", trim: true)}}
  end

  defp verification_expected(expected) when is_map(expected) do
    if Enum.all?(expected, fn {key, value} ->
         key in @verifiable_fields and is_binary(value) and byte_size(value) in 1..1_024
       end),
       do: {:ok, expected},
       else: {:error, :failed, "Linux verification expectation is invalid"}
  end

  defp verification_expected(_expected),
    do: {:error, :failed, "Linux verification expectation is invalid"}

  defp effect_result({:ok, %Transport.Result{exit_status: 0} = result}) do
    {:ok, %Target.EffectResult{status: :applied, details: evidence(result)}}
  end

  defp effect_result({:ok, %Transport.Result{exit_status: 65} = result}) do
    {:ok,
     %Target.EffectResult{
       status: :failed,
       details: Map.put(evidence(result), "category", "stale_definition")
     }}
  end

  defp effect_result({:ok, %Transport.Result{} = result}) do
    {:ok, %Target.EffectResult{status: :failed, details: evidence(result)}}
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

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}

  defp read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  defp read_error(category, message)
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp operation(
         {capability, operation},
         description,
         schema,
         output_schema \\ nil,
         verification_schema \\ nil
       ) do
    %Target.Operation{
      capability: capability,
      operation: operation,
      description: description,
      input_schema: schema,
      output_schema: output_schema,
      verification_schema: verification_schema
    }
  end

  defp identity_output_schema do
    facts_schema(%{
      "kernel" => fact_string(1_024, 1),
      "machine_id" => fact_string(255, 1)
    })
  end

  defp processes_output_schema do
    facts_schema(%{
      "processes" => %{
        "type" => "array",
        "maxItems" => 100,
        "items" =>
          facts_schema(%{
            "pid" => %{"type" => "integer"},
            "parent_pid" => %{"type" => "integer"},
            "state" => fact_string(64, 1),
            "command" => fact_string(1_024, 1)
          })
      }
    })
  end

  defp service_output_schema do
    @service_fields
    |> Map.values()
    |> Map.new(&{&1, fact_string(1_024)})
    |> facts_schema()
  end

  defp service_verification_schema do
    @verifiable_fields
    |> Map.new(&{&1, fact_string(1_024, 1)})
    |> facts_schema()
    |> Map.put("minProperties", 1)
  end

  defp journal_output_schema do
    facts_schema(%{
      "unit" => fact_string(255, 1),
      "entries" => %{
        "type" => "array",
        "maxItems" => 200,
        "items" => fact_string(8_192, 1)
      }
    })
  end

  defp facts_schema(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

  defp fact_string(maximum, minimum \\ 0),
    do: %{"type" => "string", "minLength" => minimum, "maxLength" => maximum}

  defp empty_schema, do: request_schema(%{}, [], %{}, [])

  defp process_schema do
    request_schema(
      %{},
      [],
      %{"limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}},
      ["limit"]
    )
  end

  defp unit_schema do
    request_schema(%{"unit" => unit_property()}, ["unit"], %{}, [])
  end

  defp journal_schema do
    request_schema(
      %{"unit" => unit_property()},
      ["unit"],
      %{"lines" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}},
      ["lines"]
    )
  end

  defp restart_schema do
    request_schema(
      %{"unit" => unit_property()},
      ["unit"],
      %{
        "expected_definition_sha256" => %{
          "type" => "string",
          "pattern" => "^[a-f0-9]{64}$"
        }
      },
      ["expected_definition_sha256"]
    )
  end

  defp request_schema(
         selector_properties,
         selector_required,
         parameter_properties,
         parameter_required
       ) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => object_schema(selector_properties, selector_required),
        "parameters" => object_schema(parameter_properties, parameter_required)
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp unit_property do
    %{
      "type" => "string",
      "minLength" => 9,
      "maxLength" => 255,
      "pattern" => "^[A-Za-z0-9_.@:-]+\\.service$"
    }
  end

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

  defp parse_pairs(value) do
    value
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, item] -> {key, String.trim(item)}
        [key] -> {key, ""}
      end
    end)
  end

  defp integer(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _error -> value
    end
  end

  defp privileged(%State{privilege: "sudo"}, command), do: "sudo -n " <> command
  defp privileged(%State{privilege: "none"}, command), do: command

  defp valid_unit?(value),
    do: is_binary(value) and byte_size(value) <= 255 and Regex.match?(@unit_pattern, value)

  defp shell_quote(value), do: "'" <> value <> "'"
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
  defp invalid_request, do: {:error, :failed, "Linux SSH request is invalid"}
end
