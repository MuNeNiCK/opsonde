defmodule Opsonde.Transports.NETCONF do
  @moduledoc false

  alias Opsonde.Transports.SSH

  @delimiter "]]>]]>"
  @base_1_1 "urn:ietf:params:netconf:base:1.1"
  @base_namespace "urn:ietf:params:xml:ns:netconf:base:1.0"
  @message_id "opsonde-1"
  @max_message_bytes 60_000
  @max_sequence_replies_bytes 50_000
  @hello """
  <?xml version="1.0" encoding="UTF-8"?>
  <hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"><capabilities><capability>urn:ietf:params:netconf:base:1.0</capability><capability>urn:ietf:params:netconf:base:1.1</capability></capabilities></hello>
  """

  defmodule Session do
    @moduledoc false
    @enforce_keys [:capabilities, :framing]
    defstruct @enforce_keys
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [:capabilities, :reply, :root]
    defstruct @enforce_keys
  end

  def max_body_bytes, do: @max_message_bytes - byte_size(envelope("")) - 16

  def classify_body(body) when is_binary(body) do
    with true <- byte_size(body) in 1..max_body_bytes(),
         true <- String.valid?(body),
         {:ok, {"rpc", _attributes, children}} <- parse(envelope(body)),
         [{name, attributes, _children}] <- Enum.reject(children, &is_binary/1),
         true <- Enum.all?(children, &(not is_binary(&1) or String.trim(&1) == "")),
         {:ok, namespace, local} <- qualified_name(name, attributes, %{"" => @base_namespace}) do
      if namespace == @base_namespace and local in ["get", "get-config"],
        do: {:ok, :observation},
        else: {:ok, :effect}
    else
      _invalid -> {:error, :failed, "NETCONF RPC body is invalid"}
    end
  end

  def classify_body(_body), do: {:error, :failed, "NETCONF RPC body is invalid"}

  def execute(%SSH.Config{} = config, endpoint, body, cancelled? \\ fn -> false end) do
    with {:ok, _kind} <- classify_body(body),
         {:ok, %Result{} = result} <- request(config, endpoint, envelope(body), cancelled?) do
      case parse(result.reply) do
        {:ok, root} ->
          case valid_reply(root, @message_id) do
            :ok -> {:ok, %Result{result | root: root}}
            {:error, :failed, message} -> {:error, :unknown_after_dispatch, message}
            error -> error
          end

        {:error, :failed, message} ->
          {:error, :unknown_after_dispatch, message}
      end
    end
  end

  def execute_many(config, endpoint, bodies, cancelled? \\ fn -> false end)

  def execute_many(%SSH.Config{} = config, endpoint, bodies, cancelled?)
      when is_list(bodies) and length(bodies) in 1..8 do
    if Enum.all?(bodies, &match?({:ok, _kind}, classify_body(&1))) do
      owner = self()
      reference = make_ref()

      result =
        SSH.subsystem(
          config,
          endpoint,
          "netconf",
          fn channel ->
            with {:ok, session} <- open_session(channel) do
              exchange_many(channel, session.framing, bodies, 1, <<>>, [], {owner, reference})
            end
          end,
          cancelled?
        )

      progress = latest_progress(reference, [])

      case result do
        {:ok, replies} -> {:ok, replies}
        {:error, category, message, replies} -> {:error, category, message, replies}
        {:error, category, message} -> {:error, category, message, progress}
      end
    else
      {:error, :failed, "NETCONF sequence is invalid", []}
    end
  end

  def execute_many(_config, _endpoint, _bodies, _cancelled?),
    do: {:error, :failed, "NETCONF sequence is invalid", []}

  defp exchange_many(_channel, _framing, [], _index, _buffer, replies, _reporter),
    do: {:ok, Enum.reverse(replies)}

  defp exchange_many(channel, framing, [body | rest], index, buffer, replies, reporter) do
    message_id = "opsonde-#{index}"

    with :ok <- SSH.channel_send(channel, frame(envelope(body, message_id), framing)),
         {:ok, reply, remaining} <- SSH.channel_receive(channel, buffer, decoder(framing)),
         {:ok, root} <- parse(reply),
         :ok <- valid_reply(root, message_id),
         true <- bounded_replies?([reply | replies]) do
      {owner, reference} = reporter
      send(owner, {:opsonde_netconf_progress, reference, Enum.reverse([reply | replies])})
      exchange_many(channel, framing, rest, index + 1, remaining, [reply | replies], reporter)
    else
      {:error, :rejected, message} ->
        {:error, :rejected, message, Enum.reverse(replies)}

      {:error, category, message} ->
        {:error, after_sequence_dispatch(category), message, Enum.reverse(replies)}

      false ->
        {:error, :unknown_after_dispatch, "NETCONF sequence replies exceeded their limit",
         Enum.reverse(replies)}
    end
  end

  defp after_sequence_dispatch(category) when category in [:cancelled, :failed],
    do: :unknown_after_dispatch

  defp after_sequence_dispatch(category), do: category

  defp bounded_replies?(replies) do
    case Jason.encode(replies) do
      {:ok, encoded} -> byte_size(encoded) <= @max_sequence_replies_bytes
      {:error, _reason} -> false
    end
  end

  defp latest_progress(reference, known) do
    receive do
      {:opsonde_netconf_progress, ^reference, replies} -> latest_progress(reference, replies)
    after
      0 -> known
    end
  end

  def check(%SSH.Config{} = config, endpoint, cancelled? \\ fn -> false end) do
    SSH.subsystem(config, endpoint, "netconf", &open_session/1, cancelled?)
  end

  defp request(config, endpoint, rpc, cancelled?)

  defp request(%SSH.Config{} = config, endpoint, rpc, cancelled?)
       when is_binary(rpc) and byte_size(rpc) in 1..60_000 do
    SSH.subsystem(
      config,
      endpoint,
      "netconf",
      fn channel ->
        with {:ok, %Session{} = session} <- open_session(channel),
             :ok <- SSH.channel_send(channel, frame(rpc, session.framing)),
             {:ok, reply, _rest} <- SSH.channel_receive(channel, <<>>, decoder(session.framing)) do
          {:ok, %Result{capabilities: session.capabilities, reply: reply, root: nil}}
        end
      end,
      cancelled?
    )
  end

  defp request(_config, _endpoint, _rpc, _cancelled?),
    do: {:error, :failed, "NETCONF request is invalid"}

  defp valid_reply({name, attributes, children}, message_id) do
    with {:ok, @base_namespace, "rpc-reply"} <- qualified_name(name, attributes, %{}),
         true <- List.keyfind(attributes, "message-id", 0) == {"message-id", message_id},
         false <- Enum.any?(children, &rpc_error?(&1, namespace_bindings(attributes, %{}))) do
      :ok
    else
      true -> {:error, :rejected, "NETCONF RPC was rejected"}
      _invalid -> {:error, :failed, "NETCONF reply is invalid or mismatched"}
    end
  end

  defp rpc_error?({name, attributes, _children}, inherited),
    do: qualified_name(name, attributes, inherited) == {:ok, @base_namespace, "rpc-error"}

  defp rpc_error?(_other, _inherited), do: false

  defp qualified_name(name, attributes, inherited) when is_binary(name) do
    namespaces = namespace_bindings(attributes, inherited)

    case String.split(name, ":") do
      [local] ->
        namespace_result(Map.get(namespaces, ""), local)

      [prefix, local] ->
        namespace_result(Map.get(namespaces, prefix), local)

      _invalid ->
        :error
    end
  end

  defp namespace_result(namespace, local)
       when is_binary(namespace) and namespace != "" and is_binary(local) and local != "",
       do: {:ok, namespace, local}

  defp namespace_result(_namespace, _local), do: :error

  defp namespace_bindings(attributes, inherited) do
    Enum.reduce(attributes, inherited, fn
      {"xmlns", value}, bindings -> Map.put(bindings, "", value)
      {"xmlns:" <> prefix, value}, bindings -> Map.put(bindings, prefix, value)
      _attribute, bindings -> bindings
    end)
  end

  defp parse(xml) do
    case Saxy.SimpleForm.parse_string(xml, expand_entity: :keep) do
      {:ok, root} -> {:ok, root}
      {:error, _reason} -> {:error, :failed, "NETCONF XML is invalid"}
    end
  end

  defp envelope(body), do: envelope(body, @message_id)

  defp envelope(body, message_id),
    do: "<rpc xmlns=\"#{@base_namespace}\" message-id=\"#{message_id}\">#{body}</rpc>"

  defp open_session(channel) do
    with :ok <- SSH.channel_send(channel, @hello <> @delimiter, false),
         {:ok, hello, _rest} <- SSH.channel_receive(channel, <<>>, &delimiter_message/1),
         {:ok, capabilities} <- capabilities(hello) do
      framing = if @base_1_1 in capabilities, do: :chunked, else: :delimiter
      {:ok, %Session{capabilities: capabilities, framing: framing}}
    end
  end

  defp capabilities(xml) do
    with {:ok, root} <- Saxy.SimpleForm.parse_string(xml, expand_entity: :keep),
         "hello" <- local_name(elem(root, 0)) do
      values =
        root
        |> descendants("capability")
        |> Enum.map(&text/1)
        |> Enum.reject(&(&1 == ""))

      if values == [],
        do: {:error, :failed, "NETCONF hello has no capabilities"},
        else: {:ok, values}
    else
      _error -> {:error, :failed, "NETCONF hello is invalid"}
    end
  end

  defp frame(xml, :delimiter), do: xml <> @delimiter
  defp frame(xml, :chunked), do: "\n##{byte_size(xml)}\n#{xml}\n##\n"
  defp decoder(:delimiter), do: &delimiter_message/1
  defp decoder(:chunked), do: &chunked_message/1

  defp delimiter_message(buffer) do
    case :binary.match(buffer, @delimiter) do
      {position, length} ->
        message = binary_part(buffer, 0, position)
        rest = binary_part(buffer, position + length, byte_size(buffer) - position - length)
        {:ok, message, rest}

      :nomatch ->
        :more
    end
  end

  defp chunked_message(buffer) do
    case parse_chunks(buffer, []) do
      {:ok, chunks, rest} -> {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), rest}
      :more -> :more
      :error -> {:error, :failed, "NETCONF chunked response is invalid"}
    end
  end

  defp parse_chunks("\n##\n" <> rest, chunks) when chunks != [], do: {:ok, chunks, rest}

  defp parse_chunks("\n#" <> buffer, chunks) do
    case :binary.match(buffer, "\n") do
      {position, 1} ->
        length_text = binary_part(buffer, 0, position)
        payload = binary_part(buffer, position + 1, byte_size(buffer) - position - 1)

        with {length, ""} when length > 0 and length <= 60_000 <- Integer.parse(length_text),
             true <- byte_size(payload) >= length do
          chunk = binary_part(payload, 0, length)
          rest = binary_part(payload, length, byte_size(payload) - length)
          parse_chunks(rest, [chunk | chunks])
        else
          false -> :more
          _error -> :error
        end

      :nomatch ->
        :more
    end
  end

  defp parse_chunks(buffer, _chunks) when byte_size(buffer) < 4, do: :more
  defp parse_chunks(_buffer, _chunks), do: :error

  defp descendants({name, _attributes, children} = element, wanted) when is_list(children) do
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

  defp local_name(name), do: name |> String.split(":") |> List.last()
end
