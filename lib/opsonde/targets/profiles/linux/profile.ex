defmodule Opsonde.Targets.Profiles.Linux do
  @moduledoc false
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Adapters.SSH.Command
  alias Opsonde.Targets.ResourceScope

  @identity {"observe.identity", "linux.identity.inspect"}
  @processes {"observe.processes", "linux.process.list"}
  @service {"observe.service", "linux.service.inspect"}
  @service_list {"observe.service", "linux.service.list"}
  @journal {"observe.journal", "linux.journal.read"}
  @restart {"effect.service", "linux.service.restart"}
  @method_observation "request.ssh.observe"
  @method_effect "request.ssh.effect"
  @unit_pattern ~r/^[A-Za-z0-9_.@:-]+\.service$/
  @digest_pattern ~r/^[a-f0-9]{64}$/
  @service_state_pattern ~r/^[a-z0-9_-]{1,64}$/
  @max_service_page 200
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

  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "ssh",
      capabilities:
        Enum.uniq(
          Enum.map(
            [@identity, @processes, @service, @service_list, @journal, @restart],
            &elem(&1, 0)
          ) ++
            [@method_observation, @method_effect]
        )
    }
  end

  def resource_scope(operation, capability, selectors)
      when operation in ["linux.service.restart", "linux.service.inspect"] and
             capability in ["effect.service", "observe.service"] and is_map(selectors) do
    case selectors do
      %{"unit" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      _other -> "target"
    end
  end

  def resource_scope(_operation, _capability, _selectors), do: "target"

  def capabilities(privilege) do
    {method_observation, method_effect} =
      Command.operations(@method_observation, @method_effect, "Linux shell")

    method_observation = describe_privilege(method_observation, privilege)
    method_effect = describe_privilege(method_effect, privilege)

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
           @service_list,
           "Discover exact installed systemd service unit names by page. Use this before service inspection when a unit is unknown; monitoring job and instance names are not unit names. Then inspect the discovered unit to learn its live state.",
           service_list_schema(),
           service_list_output_schema()
         ),
         operation(
           @service,
           "Inspect a known installed systemd service unit and its definition. Requires an exact unit name; if only monitoring labels are known, discover units with linux.service.list first.",
           unit_schema(),
           service_output_schema(),
           service_verification_schema()
         ),
         operation(
           @journal,
           "Read bounded recent journal entries for one systemd service",
           journal_schema(),
           journal_output_schema()
         ),
         method_observation
       ],
       effects: [
         %{
           operation(
             @restart,
             "Restart one systemd service using the exact definition_sha256 from a supplied " <>
               "linux.service.inspect observation; inspect the service first when unavailable",
             restart_schema()
           )
           | evidence_requirements: [
               %Target.EvidenceRequirement{
                 parameter: "expected_definition_sha256",
                 fact: "definition_sha256",
                 observation: "linux.service.inspect"
               }
             ]
         },
         method_effect
       ]
     }}
  end

  def expected_status(_facts, expected) when expected == %{}, do: :unknown

  def expected_status(facts, expected) when is_map(expected) do
    if Enum.all?(expected, fn {key, value} -> facts[key] == value end),
      do: :verified,
      else: :not_verified
  end

  def observation_command(privilege, request) do
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

      {capability, operation, selectors, parameters}
      when {capability, operation} == @service_list and selectors == %{} ->
        case service_page(parameters) do
          {:ok, offset, limit} ->
            {:ok, service_list_command(offset, limit), {:service_list, offset, limit}}

          error ->
            error
        end

      {capability, operation, %{"unit" => unit}, %{"lines" => lines}}
      when {capability, operation} == @journal and is_integer(lines) and lines in 1..200 ->
        if valid_unit?(unit),
          do: {:ok, journal_command(privilege, unit, lines), {:journal, unit}},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  def restart_command(privilege, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, %{"unit" => unit}, %{"expected_definition_sha256" => expected}}
      when {capability, operation} == @restart ->
        if valid_unit?(unit) and is_binary(expected) and Regex.match?(@digest_pattern, expected),
          do: {:ok, restart_command(privilege, unit, expected)},
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

  defp service_list_command(offset, limit) do
    first = offset + 1
    last = offset + limit + 1

    "units=\"$(systemctl list-unit-files --type=service --no-legend --no-pager --plain)\" || exit $?; " <>
      "printf '%s\\n' \"$units\" | sed -n '#{first},#{last}p'"
  end

  defp service_page(parameters) when is_map(parameters) do
    if Map.keys(parameters) -- ["offset", "limit"] == [] do
      offset = Map.get(parameters, "offset", 0)
      limit = Map.get(parameters, "limit", @max_service_page)

      if is_integer(offset) and offset in 0..10_000 and is_integer(limit) and
           limit in 1..@max_service_page,
         do: {:ok, offset, limit},
         else: invalid_request()
    else
      invalid_request()
    end
  end

  defp service_page(_parameters), do: invalid_request()

  defp journal_command(privilege, unit, lines) do
    command =
      "journalctl --unit=#{shell_quote(unit)} --lines=#{lines} --no-pager --output=short-iso"

    privileged(privilege, command)
  end

  defp restart_command(privilege, unit, expected) do
    quoted = shell_quote(unit)

    "definition=\"$(systemctl cat -- #{quoted})\" || exit $?; " <>
      "actual=\"$(printf '%s' \"$definition\" | sha256sum | cut -d' ' -f1)\"; " <>
      "if [ \"$actual\" != '#{expected}' ]; then printf 'service definition changed\\n' >&2; exit 65; fi; " <>
      privileged(privilege, "systemctl restart -- #{quoted}")
  end

  def decode_observation(:identity, result) do
    facts = parse_pairs(result.stdout)

    case facts do
      %{"Kernel" => kernel, "MachineId" => machine_id}
      when byte_size(kernel) > 0 and byte_size(machine_id) > 0 ->
        {:ok, %{"kernel" => kernel, "machine_id" => machine_id}}

      _facts ->
        {:error, :failed, "Linux identity response is invalid"}
    end
  end

  def decode_observation(:processes, result) do
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

  def decode_observation(:service, result) do
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

  def decode_observation({:service_list, offset, limit}, result) do
    lines = String.split(result.stdout, "\n", trim: true)

    if length(lines) > limit + 1 do
      {:error, :failed, "Linux service list exceeded the requested page bound"}
    else
      lines
      |> Enum.take(limit)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, services} ->
        case String.split(line, ~r/\s+/, trim: true) do
          [unit, state | _rest]
          when is_binary(unit) and is_binary(state) ->
            if valid_unit?(unit) and Regex.match?(@service_state_pattern, state),
              do: {:cont, {:ok, [%{"unit" => unit, "unit_file_state" => state} | services]}},
              else: {:halt, {:error, :failed, "Linux service list response is invalid"}}

          _line ->
            {:halt, {:error, :failed, "Linux service list response is invalid"}}
        end
      end)
      |> case do
        {:ok, services} ->
          services = Enum.reverse(services)

          {:ok,
           %{
             "services" => services,
             "offset" => offset,
             "next_offset" => offset + length(services),
             "has_more" => length(lines) > limit
           }}

        error ->
          error
      end
    end
  end

  def decode_observation({:journal, unit}, result) do
    {:ok, %{"unit" => unit, "entries" => String.split(result.stdout, "\n", trim: true)}}
  end

  def verification_expected(expected) when is_map(expected) do
    if expected == %{"active_state" => "active"},
      do: {:ok, expected},
      else: {:error, :failed, "Linux verification expectation is invalid"}
  end

  def verification_expected(_expected),
    do: {:error, :failed, "Linux verification expectation is invalid"}

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

  defp service_list_output_schema do
    facts_schema(%{
      "services" => %{
        "type" => "array",
        "maxItems" => @max_service_page,
        "items" =>
          object_schema(
            %{
              "unit" => unit_property(),
              "unit_file_state" => fact_string(64, 1)
            },
            ["unit", "unit_file_state"]
          )
      },
      "offset" => %{"type" => "integer", "minimum" => 0},
      "next_offset" => %{"type" => "integer", "minimum" => 0},
      "has_more" => %{"type" => "boolean"}
    })
  end

  defp service_verification_schema do
    %{
      "type" => "object",
      "properties" => %{
        "active_state" => %{
          "type" => "string",
          "enum" => ["active"],
          "description" => "The canonical successful postcondition for linux.service.restart"
        }
      },
      "required" => ["active_state"],
      "additionalProperties" => false
    }
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

  defp service_list_schema do
    request_schema(
      %{},
      [],
      %{
        "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => 10_000},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_service_page}
      },
      []
    )
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
          "pattern" => "^[a-f0-9]{64}$",
          "description" =>
            "Copy the exact definition_sha256 from cited linux.service.inspect observation " <>
              "Evidence; never infer or invent this value"
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

  defp describe_privilege(operation, "sudo") do
    %{
      operation
      | description:
          operation.description <>
            "; the Access Method prefixes this command with configured non-interactive sudo, so do not add sudo"
    }
  end

  defp describe_privilege(operation, "none"), do: operation

  def privileged("sudo", command), do: "sudo -n " <> command
  def privileged("none", command), do: command

  defp valid_unit?(value),
    do: is_binary(value) and byte_size(value) <= 255 and Regex.match?(@unit_pattern, value)

  defp shell_quote(value), do: "'" <> value <> "'"
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp invalid_request, do: {:error, :failed, "Linux SSH request is invalid"}
end
