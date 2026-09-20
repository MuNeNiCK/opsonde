defmodule Opsonde.Transports.NETCONF do
  @moduledoc false

  alias Opsonde.Transports.SSH

  @delimiter "]]>]]>"
  @base_1_1 "urn:ietf:params:netconf:base:1.1"
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
    @enforce_keys [:capabilities, :reply]
    defstruct @enforce_keys
  end

  def check(%SSH.Config{} = config, endpoint, cancelled? \\ fn -> false end) do
    SSH.subsystem(config, endpoint, "netconf", &open_session/1, cancelled?)
  end

  def request(config, endpoint, rpc, cancelled? \\ fn -> false end)

  def request(%SSH.Config{} = config, endpoint, rpc, cancelled?)
      when is_binary(rpc) and byte_size(rpc) in 1..60_000 do
    SSH.subsystem(
      config,
      endpoint,
      "netconf",
      fn channel ->
        with {:ok, %Session{} = session} <- open_session(channel),
             :ok <- SSH.channel_send(channel, frame(rpc, session.framing)),
             {:ok, reply, _rest} <- SSH.channel_receive(channel, <<>>, decoder(session.framing)) do
          {:ok, %Result{capabilities: session.capabilities, reply: reply}}
        end
      end,
      cancelled?
    )
  end

  def request(_config, _endpoint, _rpc, _cancelled?),
    do: {:error, :failed, "NETCONF request is invalid"}

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
