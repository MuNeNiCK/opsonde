defmodule Opsonde.Targets.Profiles.IOSXE do
  @moduledoc false

  alias Opsonde.Providers.Target

  @system {"observe.system", "ios_xe.system.inspect"}
  @interface {"observe.interface", "ios_xe.interface.inspect"}
  @description {"effect.interface", "ios_xe.interface.description.set"}
  @admin_state {"effect.interface", "ios_xe.interface.admin_state.set"}
  @interface_pattern ~r/^[A-Za-z][A-Za-z0-9._\/-]{0,127}$/
  @verification_fields ~w(name description enabled admin_status oper_status input_errors output_errors)
  @interfaces_namespace "urn:ietf:params:xml:ns:yang:ietf-interfaces"
  @ios_xe_namespace "http://cisco.com/ns/yang/Cisco-IOS-XE-native"

  def access_method_profile(method, method_observation, method_effect) do
    %Target.AccessMethodProfile{
      method: method,
      capabilities: Target.capability_names(capabilities()) ++ [method_observation, method_effect]
    }
  end

  def capabilities do
    %Target.Capabilities{
      observations: [
        operation(
          @system,
          "Inspect IOS XE hostname and software version",
          empty_schema(),
          system_output_schema()
        ),
        operation(
          @interface,
          "Inspect one IOS XE interface",
          interface_schema(%{}, []),
          interface_output_schema(),
          interface_verification_schema()
        )
      ],
      effects: [
        %{
          operation(
            @description,
            "Set one interface description after checking its observed value",
            interface_schema(
              %{
                "description" => %{"type" => "string", "minLength" => 1, "maxLength" => 240},
                "expected_description" => %{"type" => ["string", "null"], "maxLength" => 240}
              },
              ~w(description expected_description)
            )
          )
          | evidence_requirements: [
              %Target.EvidenceRequirement{
                parameter: "expected_description",
                fact: "description",
                observation: "ios_xe.interface.inspect"
              }
            ]
        },
        %{
          operation(
            @admin_state,
            "Set one interface administrative state after checking its observed value",
            interface_schema(
              %{
                "enabled" => %{"type" => "boolean"},
                "expected_enabled" => %{"type" => "boolean"}
              },
              ~w(enabled expected_enabled)
            )
          )
          | evidence_requirements: [
              %Target.EvidenceRequirement{
                parameter: "expected_enabled",
                fact: "enabled",
                observation: "ios_xe.interface.inspect"
              }
            ]
        }
      ]
    }
  end

  def observation_request(request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, selectors, parameters}
      when {capability, operation} == @system and selectors == %{} and parameters == %{} ->
        {:ok, :system}

      {capability, operation, %{"interface" => name} = selectors, parameters}
      when {capability, operation} == @interface and map_size(selectors) == 1 and
             parameters == %{} ->
        if valid_interface?(name), do: {:ok, {:interface, name}}, else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  def effect_request(request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, %{"interface" => name} = selectors,
       %{"description" => description, "expected_description" => expected} = parameters}
      when {capability, operation} == @description and map_size(selectors) == 1 and
             map_size(parameters) == 2 ->
        if valid_interface?(name) and valid_description?(description) and
             valid_description?(expected, true),
           do: {:ok, {:description, name, expected, description}},
           else: invalid_request()

      {capability, operation, %{"interface" => name} = selectors,
       %{"enabled" => enabled, "expected_enabled" => expected} = parameters}
      when {capability, operation} == @admin_state and map_size(selectors) == 1 and
             map_size(parameters) == 2 and is_boolean(enabled) and is_boolean(expected) ->
        if valid_interface?(name),
          do: {:ok, {:admin_state, name, expected, enabled}},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  def verification_request(request) do
    with {:ok, {:interface, name}} <- observation_request(request),
         {:ok, expected} <- verification_expected(request.expected) do
      {:ok, name, expected}
    end
  end

  def observation(facts, evidence \\ []) when is_map(facts) do
    {:ok, %Target.Observation{facts: facts, observed_at: DateTime.utc_now(), evidence: evidence}}
  end

  def verification(facts, expected, evidence \\ []) when is_map(facts) and is_map(expected) do
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
       evidence: evidence
     }}
  end

  def applied(details \\ %{}),
    do: {:ok, %Target.EffectResult{status: :applied, details: details}}

  def stale(field, observed) do
    {:ok,
     %Target.EffectResult{
       status: :failed,
       details: %{"category" => "stale", "field" => field, "observed" => observed}
     }}
  end

  def effect_error(category, message)
      when category in [
             :timeout_after_dispatch,
             :cancelled_after_dispatch,
             :disconnected_after_dispatch,
             :output_limit_after_dispatch,
             :unknown_after_dispatch
           ],
      do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  def effect_error(:cancelled, message), do: {:error, :cancelled, message}

  def effect_error(category, message)
      when category in [:rejected, :conflict, :not_found, :forbidden, :authentication],
      do:
        {:ok,
         %Target.EffectResult{
           status: :failed,
           details: %{"category" => to_string(category), "error" => message}
         }}

  def effect_error(_category, message), do: {:error, :failed, message}

  def read_error(:cancelled, message), do: {:error, :cancelled, message}

  def read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  def read_error(category, message)
      when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
      do: {:error, :retryable, message}

  def read_error(_category, message), do: {:error, :failed, message}

  def valid_interface?(value), do: is_binary(value) and String.match?(value, @interface_pattern)

  def valid_description?(value, allow_nil \\ false)
  def valid_description?(nil, true), do: true

  def valid_description?(value, _allow_nil)
      when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= 240,
      do: not String.match?(value, ~r/[\x00-\x1F\x7F]/)

  def valid_description?(_value, _allow_nil), do: false

  # IOS XE CLI vocabulary and response interpretation belong to this product
  # profile. The SSH adapter owns the session and delivery of these commands.
  def ssh_system_commands do
    [
      "show running-config | include ^hostname",
      "show version | include Cisco IOS XE Software, Version"
    ]
  end

  def ssh_interface_commands(name) do
    [
      "show running-config interface #{name}",
      "show interfaces #{name} | include line protocol|Description|input errors|output errors"
    ]
  end

  def ssh_description_commands(name, desired),
    do: ["configure terminal", "interface #{name}", "description #{desired}", "end"]

  def ssh_admin_state_commands(name, desired),
    do: [
      "configure terminal",
      "interface #{name}",
      if(desired, do: "no shutdown", else: "shutdown"),
      "end"
    ]

  def ssh_system_facts(output) do
    with [hostname] <- ssh_capture(output, ~r/^hostname\s+(\S+)\s*$/m),
         [version] <- ssh_capture(output, ~r/^Cisco IOS XE Software, Version[ \t]+([^\r\n]+)/m) do
      {:ok, %{"hostname" => hostname, "version" => String.trim(version)}}
    else
      _output -> {:error, :failed, "IOS XE SSH system response is invalid"}
    end
  end

  def ssh_interface_facts(name, output) do
    line =
      Regex.run(
        ~r/^#{Regex.escape(name)} is (administratively down|up|down), line protocol is (up|down)/m,
        output,
        capture: :all_but_first
      )

    case line do
      [admin, operational] ->
        description =
          case ssh_capture(output, ~r/^\s*Description:\s*(.*?)\s*$/m) do
            [value] -> value
            [] -> ssh_running_description(name, output)
          end

        {:ok,
         %{
           "name" => name,
           "description" => description,
           "enabled" => admin != "administratively down",
           "admin_status" => if(admin == "administratively down", do: "down", else: admin),
           "oper_status" => operational,
           "input_errors" => ssh_error_count(output, "input"),
           "output_errors" => ssh_error_count(output, "output")
         }}

      _line ->
        {:error, :not_found, "IOS XE interface was not found"}
    end
  end

  def ssh_command_accepted?(output) do
    if Regex.match?(
         ~r/% (Invalid input|Incomplete command|Ambiguous command|Command rejected)/i,
         output
       ),
       do: {:error, :rejected, "IOS XE SSH command was rejected"},
       else: :ok
  end

  def ssh_readonly_command?(command) do
    command = command |> String.trim() |> String.downcase()
    String.starts_with?(command, "show ") or command == "show"
  end

  def restconf_system_paths do
    {
      "/restconf/data/Cisco-IOS-XE-native:native/hostname",
      "/restconf/data/Cisco-IOS-XE-native:native/version"
    }
  end

  def restconf_system_facts(
        %{"Cisco-IOS-XE-native:hostname" => hostname},
        %{"Cisco-IOS-XE-native:version" => version}
      ),
      do: {:ok, %{"hostname" => hostname, "version" => version}}

  def restconf_system_facts(_hostname, _version),
    do: {:error, :failed, "IOS XE RESTCONF system response is invalid"}

  def restconf_interface_paths(name) do
    key = URI.encode_www_form(name)

    {
      "/restconf/data/ietf-interfaces:interfaces/interface=#{key}",
      "/restconf/data/ietf-interfaces:interfaces-state/interface=#{key}"
    }
  end

  def restconf_interface_body(name, values),
    do: %{"ietf-interfaces:interface" => Map.put(values, "name", name)}

  def restconf_interface_facts(
        name,
        %{"ietf-interfaces:interface" => configuration},
        %{"ietf-interfaces:interface" => operational}
      ) do
    {:ok,
     %{
       "name" => name,
       "description" => configuration["description"],
       "enabled" => Map.get(configuration, "enabled", true),
       "admin_status" => operational["admin-status"],
       "oper_status" => operational["oper-status"],
       "input_errors" => get_in(operational, ["statistics", "in-errors"]),
       "output_errors" => get_in(operational, ["statistics", "out-errors"])
     }}
  end

  def restconf_interface_facts(_name, _configuration, _operational),
    do: {:error, :failed, "IOS XE RESTCONF interface response is invalid"}

  def match_expected(observed, expected, _field) when observed == expected, do: :ok
  def match_expected(observed, _expected, field), do: {:stale, observed, field}

  def netconf_system_filter do
    """
    <get><filter type="subtree"><native xmlns="#{@ios_xe_namespace}"><hostname/><version/></native></filter></get>
    """
  end

  def netconf_system_facts(hostname, version),
    do: %{"hostname" => hostname, "version" => version}

  def netconf_interface_filter(name) do
    escaped = xml_escape(name)

    """
    <get><filter type="subtree"><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces><interfaces-state xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces-state></filter></get>
    """
  end

  def netconf_interface_edit(name, field, value) when field in ["description", "enabled"] do
    """
    <edit-config><target><running/></target><default-operation>merge</default-operation><error-option>rollback-on-error</error-option><config><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{xml_escape(name)}</name><#{field}>#{xml_escape(value)}</#{field}></interface></interfaces></config></edit-config>
    """
  end

  def netconf_interface_facts(name, raw) do
    %{
      "name" => name,
      "description" => raw["description"],
      "enabled" => netconf_boolean(raw["enabled"], true),
      "admin_status" => raw["admin_status"],
      "oper_status" => raw["oper_status"],
      "input_errors" => netconf_integer(raw["input_errors"]),
      "output_errors" => netconf_integer(raw["output_errors"])
    }
  end

  defp xml_escape(value) when is_boolean(value), do: to_string(value)

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp netconf_boolean("true", _default), do: true
  defp netconf_boolean("false", _default), do: false
  defp netconf_boolean(_value, default), do: default

  defp netconf_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp netconf_integer(_value), do: nil

  defp ssh_running_description(name, output) do
    pattern =
      ~r/^interface #{Regex.escape(name)}\s*$\n(?:^[ !].*$\n)*?^ description\s+(.+?)\s*$/m

    case ssh_capture(output, pattern) do
      [description] -> description
      [] -> nil
    end
  end

  defp ssh_error_count(output, direction) do
    case ssh_capture(output, ~r/^\s*([0-9,]+) #{direction} errors,/m) do
      [value] -> value |> String.replace(",", "") |> String.to_integer()
      [] -> nil
    end
  end

  defp ssh_capture(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      nil -> []
      values -> values
    end
  end

  defp verification_expected(expected) when is_map(expected) do
    if Enum.all?(Map.keys(expected), &(&1 in @verification_fields)),
      do: {:ok, expected},
      else: invalid_request()
  end

  defp verification_expected(_expected), do: invalid_request()

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

  defp system_output_schema,
    do:
      facts_schema(%{
        "hostname" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
        "version" => %{"type" => "string", "minLength" => 1, "maxLength" => 255}
      })

  defp interface_output_schema,
    do:
      facts_schema(%{
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "description" => nullable("string"),
        "enabled" => nullable("boolean"),
        "admin_status" => nullable("string"),
        "oper_status" => nullable("string"),
        "input_errors" => nullable("integer"),
        "output_errors" => nullable("integer")
      })

  defp interface_verification_schema,
    do: Map.put(interface_output_schema(), "minProperties", 1)

  defp facts_schema(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

  defp nullable(type), do: %{"type" => [type, "null"]}

  defp empty_schema, do: schema(%{}, [], %{}, [])

  defp interface_schema(parameters, required),
    do:
      schema(
        %{"interface" => %{"type" => "string", "pattern" => "^[A-Za-z][A-Za-z0-9._/-]{0,127}$"}},
        ["interface"],
        parameters,
        required
      )

  defp schema(selectors, selector_required, parameters, parameter_required) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => selectors,
          "required" => selector_required,
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameters,
          "required" => parameter_required,
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp invalid_request, do: {:error, :failed, "IOS XE request is invalid"}
end
