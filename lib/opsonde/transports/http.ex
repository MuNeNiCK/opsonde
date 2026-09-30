defmodule Opsonde.Transports.HTTP do
  @moduledoc false

  alias Opsonde.Providers.Target
  @poll_interval 20

  # Wire I/O only. Storage and authorization remain in the supplied file ports.
  def request(options, body, output, invocation) do
    with :ok <- not_cancelled(invocation),
         {:ok, body, headers} <- wire_body(body, Map.new(options[:headers] || []), invocation),
         {:ok, writer} <- response_writer(output, invocation) do
      collector =
        if is_nil(writer),
          do: Keyword.fetch!(options, :into),
          else: fn event, acc -> collect_response(event, acc, writer, invocation) end

      options =
        options |> Keyword.put(:headers, Map.to_list(headers)) |> Keyword.put(:into, collector)

      options = if is_nil(body), do: options, else: Keyword.put(options, :body, body)

      case exchange(options, writer, invocation) do
        {:ok, %Req.Response{status: status} = response} when status in 100..599 ->
          complete_response(response, writer, invocation, options[:method])

        {:error, _category, _message} = error ->
          error

        _other ->
          response_failure(writer)
      end
    end
  rescue
    _error -> {:error, :retryable, "HTTP endpoint request failed"}
  end

  defp exchange(options, writer, invocation) do
    deadline = System.monotonic_time(:millisecond) + Keyword.fetch!(options, :receive_timeout)
    task = Task.async(fn -> wire_request(options, writer) end)

    try do
      await_wire(task, deadline, writer, invocation)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp wire_request(options, writer) do
    case Req.request(options) do
      {:error, %Req.TransportError{reason: :timeout}} -> timeout_failure(writer)
      result -> result
    end
  rescue
    _error -> response_failure(writer)
  catch
    {:http_file_failure, _message} -> response_failure(writer)
    :http_cancelled -> {:error, :cancelled, "HTTP request was cancelled"}
    _kind, _reason -> response_failure(writer)
  end

  defp await_wire(task, deadline, writer, invocation) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      not_cancelled(invocation) != :ok ->
        {:error, :cancelled, "HTTP request was cancelled"}

      remaining <= 0 ->
        timeout_failure(writer)

      true ->
        case Task.yield(task, min(@poll_interval, remaining)) do
          {:ok, result} -> result
          {:exit, _reason} -> response_failure(writer)
          nil -> await_wire(task, deadline, writer, invocation)
        end
    end
  end

  defp wire_body({:file, label, reference}, headers, %{file_reader: reader} = invocation)
       when is_function(reader, 2) do
    case reader.(label, 0) do
      {:ok, first} when is_binary(first) ->
        size = reference["size_bytes"]

        stream =
          Stream.unfold({0, first}, fn
            {^size, _chunk} ->
              nil

            {offset, chunk} ->
              if not_cancelled(invocation) != :ok, do: throw(:http_cancelled)
              chunk = if is_nil(chunk), do: read_file_chunk(reader, label, offset), else: chunk

              if byte_size(chunk) == 0 or offset + byte_size(chunk) > size,
                do: throw({:http_file_failure, "HTTP input file could not be read"})

              {chunk, {offset + byte_size(chunk), nil}}
          end)

        headers =
          headers
          |> Map.put("content-length", Integer.to_string(size))
          |> Map.put_new("content-type", reference["media_type"])

        {:ok, stream, headers}

      _ ->
        {:error, :failed, "HTTP input file could not be read"}
    end
  end

  defp wire_body({:file, _label, _reference}, _headers, _invocation),
    do: {:error, :failed, "HTTP input file reader is unavailable"}

  defp wire_body(body, headers, _invocation), do: {:ok, body, headers}

  defp read_file_chunk(reader, label, offset) do
    case reader.(label, offset) do
      {:ok, chunk} when is_binary(chunk) -> chunk
      _ -> throw({:http_file_failure, "HTTP input file could not be read"})
    end
  end

  defp response_writer(nil, _invocation), do: {:ok, nil}

  defp response_writer(%{"name" => name, "media_type" => media}, %{file_writer: callback})
       when is_function(callback, 3) do
    case callback.(Ecto.UUID.generate(), name, media) do
      {:ok, %Target.FileWriter{status: :receiving, offset: 0} = writer} -> {:ok, writer}
      _ -> {:error, :failed, "HTTP response file could not be opened"}
    end
  end

  defp response_writer(_output, _invocation),
    do: {:error, :failed, "HTTP response file writer is unavailable"}

  defp collect_response({:data, bytes}, {request, response}, writer, invocation) do
    if not_cancelled(invocation) != :ok, do: throw(:http_cancelled)
    offset = Map.get(response.private, :opsonde_received_bytes, 0)
    offset = append_response(writer, offset, bytes)

    response = %{
      response
      | body: "",
        private: Map.put(response.private, :opsonde_received_bytes, offset)
    }

    {:cont, {request, response}}
  end

  defp append_response(_writer, offset, <<>>), do: offset

  defp append_response(writer, offset, bytes) do
    size = min(byte_size(bytes), writer.chunk_bytes)
    <<chunk::binary-size(^size), rest::binary>> = bytes

    case writer.append.(offset, chunk) do
      {:ok, next} when next == offset + size -> append_response(writer, next, rest)
      _ -> throw({:http_file_failure, file_failure_message(writer)})
    end
  end

  defp complete_response(response, nil, _invocation, _method), do: {:ok, response}

  defp complete_response(response, writer, invocation, method) do
    with :ok <- not_cancelled(invocation),
         {:ok, size} <- if(method == :head, do: {:ok, 0}, else: content_length(response)),
         {:ok, hash} <- if(method == :head, do: {:ok, nil}, else: content_digest(response)),
         {:ok, reference} <- writer.complete.(size, hash) do
      {:ok, %{response | private: Map.put(response.private, :opsonde_file, reference)}}
    else
      {:error, :cancelled, _} = error -> error
      _ -> response_failure(writer)
    end
  end

  # RFC 9530 Content-Digest covers message content, including Content-Encoding.
  # Repr-Digest can describe different bytes (HEAD/range), so it is not used here.
  defp content_digest(response) do
    value =
      Enum.join(
        Req.Response.get_header(response, "content-digest") ++
          Map.get(response.trailers, "content-digest", []),
        ","
      )

    matches =
      Regex.scan(
        ~r/(?:^|,)\s*sha-256\s*=\s*:([A-Za-z0-9+\/=]*):(?:\s*;[^,]*)?(?=\s*(?:,|$))/,
        value
      )

    case matches do
      [[_field, encoded]] ->
        case Base.decode64(encoded) do
          {:ok, hash} when byte_size(hash) == 32 -> {:ok, Base.encode16(hash, case: :lower)}
          _ -> {:error, :invalid_content_digest}
        end

      [] ->
        if String.contains?(value, "sha-256"),
          do: {:error, :invalid_content_digest},
          else: {:ok, nil}

      _ ->
        {:error, :invalid_content_digest}
    end
  end

  defp content_length(%Req.Response{status: status}) when status in [204, 304], do: {:ok, 0}

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        {:ok, nil}

      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> {:ok, size}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end

  defp response_failure(nil), do: {:error, :retryable, "HTTP response was lost after dispatch"}
  defp response_failure(writer), do: {:error, :retryable, file_failure_message(writer)}

  defp timeout_failure(nil), do: {:error, :retryable, "HTTP request reached its time limit"}

  defp timeout_failure(writer),
    do: {:error, :retryable, "HTTP request reached its time limit (file " <> writer.id <> ")"}

  defp file_failure_message(writer),
    do: "HTTP response file is incomplete (file " <> writer.id <> ")"

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "HTTP request was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok
end
