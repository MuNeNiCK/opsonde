defmodule Opsonde.Transports.SSH.SFTP.Session do
  @moduledoc false
  alias Opsonde.Transports.SSH
  alias Opsonde.Transports.SSH.SFTP
  require Record
  Record.defrecordp(:xfer, :ssh_xfer, Record.extract(:ssh_xfer, from_lib: "ssh/src/ssh_xfer.hrl"))

  Record.defrecordp(
    :attr,
    :ssh_xfer_attr,
    Record.extract(:ssh_xfer_attr, from_lib: "ssh/src/ssh_xfer.hrl")
  )

  @chunk_bytes 24_000

  def request(operation, invocation, runner) do
    with :ok <- SFTP.active(invocation),
         {:ok, readers} <- inputs(operation.steps, invocation),
         {:ok, writers} <- captures(operation.steps, invocation) do
      case runner.(fn channel -> run(channel, operation, writers, readers) end) do
        {:ok, results} ->
          complete(operation, results, writers, invocation)

        {:error, category, message, progress} ->
          interrupted(operation, category, message, progress)

        error ->
          error
      end
    end
  end

  defp complete(operation, %{steps: results, protocol: protocol} = native, writers, invocation) do
    with :ok <- SFTP.active(invocation),
         {:ok, published} <- publish_results(results, writers),
         do:
           {:ok,
            %{
              "steps" => published,
              "protocol" => protocol,
              "completion_reason" => "sequence_complete"
            }},
         else: (error -> publication_failure(operation, native, error))
  rescue
    _ -> publication_failure(operation, native, failure("SFTP file publication failed"))
  catch
    _, _ -> publication_failure(operation, native, failure("SFTP file publication failed"))
  end

  defp publication_failure(
         %{kind: :session_read},
         _results,
         {:publication_error, category, message, _}
       ),
       do: {:error, category, message}

  defp publication_failure(%{kind: :session_read}, _results, error), do: error

  defp publication_failure(%{kind: :session_write}, %{steps: results, protocol: protocol}, error) do
    {message, published} =
      case error do
        {:publication_error, _, message, published} ->
          {message, Map.new(published, &{&1["index"], &1})}

        {:error, _, message} ->
          {message, %{}}
      end

    {:session_result, :unknown,
     %{
       "completed_steps" => Enum.map(results, &Map.get(published, &1["index"], &1)),
       "protocol" => protocol,
       "error" => message,
       "completion_reason" => "publication_failed"
     }}
  end

  defp interrupted(%{kind: :session_read}, category, message, _progress),
    do: {:error, category, message}

  defp interrupted(%{kind: :session_write}, category, message, progress) do
    status =
      if category in [:native_rejected, :invalid_position],
        do: if(progress["mutation_acknowledged"], do: :partial, else: :failed),
        else: :unknown

    current = Map.put(progress["current_step"], "error", message)

    current =
      if category == :native_rejected,
        do: Map.put(current, "server_status", message),
        else: current

    {:session_result, status,
     %{
       "completed_steps" => progress["completed_steps"],
       "protocol" => progress["protocol"],
       "failed_step" => current,
       "completion_reason" => "sequence_interrupted"
     }}
  end

  defp inputs(steps, invocation) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{"op" => op} = step, index}, {:ok, readers} when op in ["pwrite", "write"] ->
        case SFTP.admit_input(step, invocation) do
          {:ok, reader} ->
            {:cont, {:ok, Map.put(readers, index, reader)}}

          error ->
            {:halt, error}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp captures(steps, invocation) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn
      {%{"op" => op, "response_file" => output}, index}, {:ok, writers}
      when op in ["pread", "read"] ->
        case SFTP.capture(output, invocation) do
          {:ok, writer} -> {:cont, {:ok, Map.put(writers, index, writer)}}
          error -> {:halt, error}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp run(channel, operation, writers, readers) do
    xf = xfer(vsn: 3, ext: [], cm: channel.connection, channel: channel.id)

    with :ok <- :ssh_xfer.protocol_version_request(xf, 3),
         {:ok, <<2, 3::32, extensions::binary>>, rest} when byte_size(extensions) <= 4096 <-
           packet(channel, <<>>) do
      state = %{
        channel: channel,
        xf: xfer(xf, ext: :ssh_xfer.decode_ext(extensions)),
        buffer: rest,
        id: 0,
        handles: %{},
        results: [],
        mutated?: false,
        current_step: nil,
        protocol: %{
          "version" => 3,
          "extensions" => %{"encoding" => "base64", "data" => Base.encode64(extensions)}
        }
      }

      Enum.with_index(operation.steps)
      |> Enum.reduce_while({:ok, state}, fn {step, index}, {:ok, state} ->
        current = %{"index" => index, "op" => step["op"]}

        current =
          case step["op"] do
            op when op in ["pwrite", "write"] -> Map.put(current, "bytes_written", 0)
            op when op in ["pread", "read"] -> Map.put(current, "bytes_read", 0)
            _ -> current
          end

        state = %{state | current_step: current}
        report(state)

        case step(state, step, writers[index] || readers[index]) do
          {:ok, result, next} ->
            next = %{
              next
              | results: [Map.put(result, "index", index) | next.results],
                mutated?: state.mutated? or mutating?(step)
            }

            report(next)
            {:cont, {:ok, next}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, final} -> {:ok, %{steps: Enum.reverse(final.results), protocol: final.protocol}}
        error -> error
      end
    else
      {:error, _, _} = error ->
        error

      {:ok, <<2, version::32, _::binary>>, _} ->
        failure(
          "SFTP session requires version 3 and extension advertisements within 4096 bytes; peer version #{version} was unsupported"
        )

      _ ->
        failure("SFTP peer did not negotiate the requested native session version")
    end
  end

  defp report(state) do
    SSH.channel_progress(state.channel, %{
      "completed_steps" => Enum.reverse(state.results),
      "current_step" => state.current_step,
      "mutation_acknowledged" => state.mutated?,
      "protocol" => state.protocol
    })
  end

  defp mutating?(%{"op" => op}) when op in ["pwrite", "write"], do: true
  defp mutating?(%{"op" => "open", :flags => flags}), do: flags != [:read]
  defp mutating?(_step), do: false

  defp step(state, %{"op" => "open", "handle" => label, "path" => path, :flags => flags}, _port) do
    if flags != [:read] do
      {parent, reference} = state.channel.reporter
      send(parent, {:opsonde_ssh_dispatched, reference, state.channel.connection})
    end

    with {:ok, {:handle, _, handle}, next} <-
           wire(state, :open, [path, [], flags, attr(type: :regular)]) do
      {:ok, %{"op" => "open", "handle" => label, "acknowledged" => true},
       %{next | handles: Map.put(next.handles, label, %{native: handle, position: 0})}}
    else
      {:error, _, _} = error -> error
      _ -> failure("SFTP open did not return a native handle")
    end
  end

  defp step(
         state,
         %{"op" => "pwrite", "handle" => label, "offset" => offset, :file => file},
         reader
       ) do
    with {:ok, count, next} <-
           write_file(state, state.handles[label].native, offset, file, reader) do
      {:ok, %{"op" => "pwrite", "bytes_written" => count, "acknowledged" => true}, next}
    end
  end

  defp step(state, %{"op" => "write", "handle" => label} = input, reader) do
    position = state.handles[label].position

    with {:ok, result, next} <-
           step(state, Map.merge(input, %{"op" => "pwrite", "offset" => position}), reader) do
      {:ok, Map.put(result, "op", "write"),
       put_in(next.handles[label].position, position + result["bytes_written"])}
    end
  end

  defp step(state, %{"op" => "read", "handle" => label} = input, writer) do
    position = state.handles[label].position

    with {:ok, result, next} <-
           step(state, Map.merge(input, %{"op" => "pread", "offset" => position}), writer) do
      {:ok, Map.put(result, "op", "read"),
       put_in(next.handles[label].position, position + result["bytes_read"])}
    end
  end

  defp step(
         state,
         %{"op" => "position", "handle" => label, "origin" => origin, "offset" => offset},
         _port
       ) do
    with {:ok, base, next} <- position_base(state, label, origin),
         position = base + offset,
         true <- position >= 0 and position <= 18_446_744_073_709_551_615 do
      {:ok, %{"op" => "position", "position" => position},
       put_in(next.handles[label].position, position)}
    else
      {:error, _, _} = error ->
        error

      _ ->
        {:error, :invalid_position,
         "SFTP logical handle position is outside the native offset range"}
    end
  end

  defp step(state, %{"op" => "fstat", "handle" => label}, _port) do
    with {:ok, info, next} <- file_info(state, label),
         do:
           {:ok,
            %{"op" => "fstat", "attributes" => SFTP.attributes(:ssh_sftp.attr_to_info(info))},
            next}
  end

  defp step(
         state,
         %{"op" => "pread", "handle" => label, "offset" => offset, "length" => length},
         writer
       ) do
    with {:ok, count, reason, next} <-
           read(state, state.handles[label].native, offset, length, writer, 0) do
      {:ok,
       %{"op" => "pread", "bytes_read" => count, "completion_reason" => Atom.to_string(reason)},
       next}
    end
  end

  defp step(state, %{"op" => "close", "handle" => label}, _writer) do
    with {:ok, {:status, _, {:ok, _, _, _}}, next} <-
           wire(state, :close, [state.handles[label].native]) do
      {:ok, %{"op" => "close", "handle" => label, "acknowledged" => true},
       %{next | handles: Map.delete(next.handles, label)}}
    else
      {:error, _, _} = error -> error
      _ -> failure("SFTP close was not acknowledged")
    end
  end

  defp write_file(state, handle, offset, file, reader) do
    Opsonde.Providers.Target.FileWriter.stream(file, reader)
    |> Enum.reduce_while({:ok, 0, state}, fn bytes, {:ok, count, state} ->
      case write_chunks(state, handle, offset + count, bytes) do
        {:ok, next} -> {:cont, {:ok, count + byte_size(bytes), next}}
        error -> {:halt, error}
      end
    end)
  catch
    {:file_read_error, _} ->
      {:error, :disconnected_after_dispatch,
       "SFTP input file became unavailable; remote bytes may be partial"}
  end

  defp write_chunks(state, _handle, _offset, <<>>), do: {:ok, state}

  defp write_chunks(state, handle, offset, bytes) do
    count = min(byte_size(bytes), @chunk_bytes)
    <<chunk::binary-size(^count), tail::binary>> = bytes

    with {:ok, {:status, _, {:ok, _, _, _}}, next} <- wire(state, :write, [handle, offset, chunk]) do
      next = %{
        next
        | current_step: Map.update!(next.current_step, "bytes_written", &(&1 + count)),
          mutated?: true
      }

      report(next)
      write_chunks(next, handle, offset + count, tail)
    else
      {:error, _, _} = error -> error
      _ -> failure("SFTP write was not acknowledged")
    end
  end

  defp position_base(state, _label, "bof"), do: {:ok, 0, state}
  defp position_base(state, label, "cur"), do: {:ok, state.handles[label].position, state}

  defp position_base(state, label, "eof") do
    with {:ok, info, next} <- file_info(state, label),
         size when is_integer(size) <- attr(info, :size),
         do: {:ok, size, next},
         else: (
           {:error, _, _} = error -> error
           _ -> failure("SFTP peer did not report a file size for EOF positioning")
         )
  end

  defp file_info(state, label) do
    with {:ok, {:attrs, _, info}, next} <-
           wire(state, :fstat, [
             state.handles[label].native,
             [:size, :permissions, :uidgid, :acmodtime]
           ]),
         do: {:ok, info, next},
         else: (
           {:error, _, _} = error -> error
           _ -> failure("SFTP fstat response was invalid")
         )
  end

  defp read(state, _handle, _offset, 0, _writer, count), do: {:ok, count, :byte_limit, state}

  defp read(state, handle, offset, length, writer, count) do
    requested = min(length, @chunk_bytes)

    case wire(state, :read, [handle, offset, requested]) do
      {:ok, {:data, _, bytes}, next}
      when byte_size(bytes) > 0 and byte_size(bytes) <= requested ->
        with :ok <- SFTP.append_receipt(writer, bytes, count) do
          next = %{
            next
            | current_step: Map.put(next.current_step, "bytes_read", count + byte_size(bytes))
          }

          report(next)

          read(
            next,
            handle,
            offset + byte_size(bytes),
            length - byte_size(bytes),
            writer,
            count + byte_size(bytes)
          )
        end

      {:ok, {:status, _, {:eof, _, _, _}}, next} ->
        {:ok, count, :eof, next}

      {:error, _, _} = error ->
        error

      _ ->
        failure("SFTP read response was invalid")
    end
  end

  defp wire(state, method, arguments) do
    id = state.id + 1

    if method == :write do
      {parent, reference} = state.channel.reporter
      send(parent, {:opsonde_ssh_dispatched, reference, state.channel.connection})
    end

    with :ok <- apply(:ssh_xfer, method, [state.xf, id] ++ arguments),
         {:ok, bytes, rest} <- packet(state.channel, state.buffer) do
      reply = :ssh_xfer.xf_reply(state.xf, bytes)

      if elem(reply, 1) == id do
        case reply do
          {:status, _, {status, _, _, _}} when status not in [:ok, :eof] ->
            {:error, :native_rejected, Atom.to_string(status)}

          _ ->
            {:ok, reply, %{state | id: id, buffer: rest}}
        end
      else
        failure("SFTP reply did not match the session request")
      end
    end
  end

  defp packet(channel, buffer) do
    SSH.channel_receive(channel, buffer, fn
      <<size::32, data::binary>> when size >= 1 and size <= @chunk_bytes + 1_024 ->
        if byte_size(data) >= size do
          <<bytes::binary-size(^size), tail::binary>> = data
          {:ok, bytes, tail}
        else
          :more
        end

      bytes when byte_size(bytes) < 4 ->
        :more

      _ ->
        failure("SFTP session packet exceeded its declared bound")
    end)
  end

  defp publish_results(results, writers) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      if result["op"] in ["pread", "read"] do
        reason = if result["completion_reason"] == "eof", do: :eof, else: :byte_limit

        case SFTP.publish(writers[result["index"]], result["bytes_read"], reason) do
          {:ok, file} ->
            {:cont, {:ok, [Map.put(result, "file", file) | acc]}}

          {:error, category, message} ->
            {:halt, {:publication_error, category, message, Enum.reverse(acc)}}
        end
      else
        {:cont, {:ok, [result | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp failure(message), do: {:error, :failed, message}
end
