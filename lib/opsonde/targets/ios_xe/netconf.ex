defmodule Opsonde.Targets.IOSXE.NETCONF do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Targets.IOSXE
  alias Opsonde.Transports.{NETCONF, SSH}

  @message_id "opsonde-1"
  @netconf_namespace "urn:ietf:params:xml:ns:netconf:base:1.0"
  @interfaces_namespace "urn:ietf:params:xml:ns:yang:ietf-interfaces"
  @native_namespace "http://cisco.com/ns/yang/Cisco-IOS-XE-native"

  @impl Opsonde.Providers.Adapter
  def type, do: "ios-xe-netconf"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials), do: SSH.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(%SSH.Config{} = state, %{"endpoint" => endpoint}) do
    case NETCONF.check(state, endpoint) do
      {:ok, _session} -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IOS XE NETCONF check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation), do: {:ok, IOSXE.capabilities()}

  @impl Opsonde.Providers.Target
  def observe(%SSH.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts} <-
           observe_operation(
             state,
             request.connection.endpoint,
             operation,
             cancelled?(invocation)
           ) do
      IOSXE.observation(facts)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%SSH.Config{} = state, request, invocation) do
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
  def verify(%SSH.Config{} = state, request, invocation) do
    with {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts} <-
           observe_operation(
             state,
             request.connection.endpoint,
             {:interface, name},
             cancelled?(invocation)
           ) do
      IOSXE.verification(facts, expected)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  defp observe_operation(state, endpoint, :system, cancelled?) do
    rpc =
      rpc("""
      <get><filter type="subtree"><native xmlns="#{@native_namespace}"><hostname/><version/></native></filter></get>
      """)

    with {:ok, root} <- request(state, endpoint, rpc, cancelled?),
         {:ok, data} <- reply_data(root),
         {:ok, native} <- child(data, "native"),
         {:ok, hostname} <- child_text(native, "hostname"),
         {:ok, version} <- child_text(native, "version") do
      {:ok, %{"hostname" => hostname, "version" => version}}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, cancelled?) do
    escaped = xml_escape(name)

    rpc =
      rpc("""
      <get><filter type="subtree"><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces><interfaces-state xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces-state></filter></get>
      """)

    with {:ok, root} <- request(state, endpoint, rpc, cancelled?),
         {:ok, data} <- reply_data(root),
         {:ok, configuration} <- data |> child("interfaces") |> interface(name),
         {:ok, operational} <- data |> child("interfaces-state") |> interface(name) do
      {:ok,
       %{
         "name" => name,
         "description" => optional_child_text(configuration, "description"),
         "enabled" => boolean(optional_child_text(configuration, "enabled"), true),
         "admin_status" => optional_child_text(operational, "admin-status"),
         "oper_status" => optional_child_text(operational, "oper-status"),
         "input_errors" => statistic(operational, "in-errors"),
         "output_errors" => statistic(operational, "out-errors")
       }}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, cancelled?) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["description"], expected, "description"),
         {:ok, _root} <- edit_interface(state, endpoint, name, "description", desired, cancelled?) do
      IOSXE.applied(%{"interface" => name, "description" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, cancelled?) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["enabled"], expected, "enabled"),
         {:ok, _root} <-
           edit_interface(state, endpoint, name, "enabled", to_string(desired), cancelled?) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp edit_interface(state, endpoint, name, field, value, cancelled?) do
    body = """
    <edit-config><target><running/></target><default-operation>merge</default-operation><error-option>rollback-on-error</error-option><config><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{xml_escape(name)}</name><#{field}>#{xml_escape(value)}</#{field}></interface></interfaces></config></edit-config>
    """

    request(state, endpoint, rpc(body), cancelled?)
  end

  defp request(state, endpoint, rpc, cancelled?) do
    with {:ok, %NETCONF.Result{reply: reply}} <- NETCONF.request(state, endpoint, rpc, cancelled?),
         {:ok, root} <- parse(reply),
         :ok <- valid_reply(root) do
      {:ok, root}
    end
  end

  defp parse(xml) do
    case Saxy.SimpleForm.parse_string(xml, expand_entity: :never) do
      {:ok, root} -> {:ok, root}
      {:error, _error} -> {:error, :failed, "IOS XE NETCONF response is invalid"}
    end
  end

  defp valid_reply({name, attributes, _children} = root) do
    cond do
      local_name(name) != "rpc-reply" ->
        {:error, :failed, "IOS XE NETCONF response is invalid"}

      attribute(attributes, "message-id") != @message_id ->
        {:error, :failed, "IOS XE NETCONF response message ID is invalid"}

      descendants(root, "rpc-error") != [] ->
        {:error, :rejected, "IOS XE NETCONF request was rejected"}

      true ->
        :ok
    end
  end

  defp valid_reply(_root), do: {:error, :failed, "IOS XE NETCONF response is invalid"}

  defp reply_data(root) do
    case descendants(root, "data") do
      [data | _rest] -> {:ok, data}
      [] -> {:error, :failed, "IOS XE NETCONF response has no data"}
    end
  end

  defp interface({:ok, parent}, name) do
    parent
    |> children("interface")
    |> Enum.find(&(optional_child_text(&1, "name") == name))
    |> case do
      nil -> {:error, :not_found, "IOS XE interface was not found"}
      element -> {:ok, element}
    end
  end

  defp interface({:error, _category, _message} = error, _name), do: error

  defp statistic(interface, field) do
    case child(interface, "statistics") do
      {:ok, statistics} -> integer(optional_child_text(statistics, field))
      _error -> nil
    end
  end

  defp child({_name, _attributes, children}, wanted) do
    case Enum.find(children, fn
           {name, _attributes, _children} -> local_name(name) == wanted
           _text -> false
         end) do
      nil -> {:error, :failed, "IOS XE NETCONF response is incomplete"}
      element -> {:ok, element}
    end
  end

  defp children({_name, _attributes, children}, wanted) do
    Enum.filter(children, fn
      {name, _attributes, _children} -> local_name(name) == wanted
      _text -> false
    end)
  end

  defp child_text(element, wanted) do
    case child(element, wanted) do
      {:ok, child} -> {:ok, text(child)}
      error -> error
    end
  end

  defp optional_child_text(element, wanted) do
    case child_text(element, wanted) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  defp descendants({name, _attributes, children} = element, wanted) do
    own = if local_name(name) == wanted, do: [element], else: []

    own ++
      Enum.flat_map(children, fn
        {_name, _attributes, _children} = child -> descendants(child, wanted)
        _text -> []
      end)
  end

  defp text({_name, _attributes, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp attribute(attributes, wanted) do
    Enum.find_value(attributes, fn {name, value} ->
      if local_name(name) == wanted, do: value
    end)
  end

  defp rpc(body),
    do: "<rpc xmlns=\"#{@netconf_namespace}\" message-id=\"#{@message_id}\">#{body}</rpc>"

  defp xml_escape(value) when is_boolean(value), do: to_string(value)

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp boolean("true", _default), do: true
  defp boolean("false", _default), do: false
  defp boolean(_value, default), do: default

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp integer(_value), do: nil
  defp matches(observed, expected, _field) when observed == expected, do: :ok
  defp matches(observed, _expected, field), do: {:stale, observed, field}
  defp local_name(name), do: name |> String.split(":") |> List.last()
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
