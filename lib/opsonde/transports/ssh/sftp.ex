defmodule Opsonde.Transports.SSH.SFTP do
  @moduledoc false
  alias Opsonde.Providers.Target
  @chunk_bytes 32_768
  require Record
  @file_info Record.extract(:file_info, from_lib: "kernel/include/file.hrl")
  @attributes ~w(size type atime mtime ctime mode uid gid)a
  Record.defrecordp(:file_info, @file_info)

  # The supplied runner owns the pinned connection, task, deadline and disposal.
  # Supplied file ports own authorization and storage; publication is caller-side.
  def request(%{kind: :directory} = operation, invocation, runner) do
    with :ok <- active(invocation),
         {:ok, writer} <- writer(operation.output, invocation),
         {:ok, result} <-
           runner.(fn connection, deadline, _parent, _reference ->
             channel(connection, deadline, fn pid -> metadata_read(pid, operation, deadline) end)
           end),
         :ok <- active(invocation),
         bytes <- Jason.encode!(result["entries"]),
         :ok <- append_receipt(writer, bytes, 0),
         reason <-
           Map.fetch!(
             %{"eof" => :eof, "entry_limit" => :entry_limit, "byte_limit" => :byte_limit},
             result["completion_reason"]
           ),
         {:ok, file} <- publish(writer, byte_size(bytes), reason),
         do:
           {:ok,
            %{
              "file" => file,
              "entry_count" => length(result["entries"]),
              "entries_bytes" => result["entries_bytes"],
              "completion_reason" => result["completion_reason"]
            }}
  end

  def request(%{kind: :metadata_read} = operation, invocation, runner) do
    with :ok <- active(invocation),
         do:
           runner.(fn connection, deadline, _parent, _reference ->
             channel(connection, deadline, fn pid ->
               metadata_read(pid, operation, deadline)
             end)
           end)
  end

  def request(%{kind: :metadata_write} = operation, invocation, runner) do
    with :ok <- active(invocation),
         do:
           runner.(fn connection, deadline, parent, reference ->
             channel(connection, deadline, fn pid ->
               args = native_args(operation, connection)
               send(parent, {:opsonde_ssh_dispatched, reference, connection})

               with :ok <-
                      native(
                        apply(
                          :ssh_sftp,
                          operation.method,
                          [pid] ++ args ++ [remaining(deadline)]
                        ),
                        if(operation.method == :write_file_info, do: :write, else: :mutation)
                      ),
                    do: {:ok, %{"acknowledged" => true}}
             end)
           end)
  end

  def request(%{kind: :read} = operation, invocation, runner) do
    with :ok <- active(invocation),
         {:ok, writer} <- writer(operation.output, invocation),
         {:ok, size} <-
           runner.(fn connection, deadline, _parent, _reference ->
             channel(connection, deadline, fn pid ->
               with {:ok, handle} <-
                      native(
                        :ssh_sftp.open(
                          pid,
                          operation.path,
                          [:read, :binary],
                          remaining(deadline)
                        ),
                        :read
                      ) do
                 with {:ok, size} <- download(pid, handle, writer, deadline, 0),
                      :ok <- native(:ssh_sftp.close(pid, handle, remaining(deadline)), :read),
                      do: {:ok, size}
               end
             end)
           end),
         :ok <- active(invocation),
         {:ok, file} <- publish(writer, size, :eof),
         do: {:ok, %{"file" => file, "completion_reason" => "eof"}}
  end

  def request(%{kind: :write} = operation, invocation, runner) do
    with :ok <- active(invocation),
         {:ok, reader} <- reader(operation, invocation),
         :ok <- preflight(operation.file, reader),
         do:
           runner.(fn connection, deadline, parent, reference ->
             channel(connection, deadline, fn pid ->
               send(parent, {:opsonde_ssh_dispatched, reference, connection})

               with {:ok, handle} <-
                      native(
                        :ssh_sftp.open(
                          pid,
                          operation.path,
                          [:write, :binary],
                          remaining(deadline)
                        ),
                        :write_open
                      ) do
                 with :ok <- upload(pid, handle, operation.file, reader, deadline),
                      :ok <- native(:ssh_sftp.close(pid, handle, remaining(deadline)), :write),
                      do: {:ok, %{"bytes_written" => operation.file["size_bytes"]}}
               end
             end)
           end)
  end

  defp channel(connection, deadline, callback) do
    with {:ok, pid} <-
           native(:ssh_sftp.start_channel(connection, timeout: remaining(deadline)), :read) do
      try do
        callback.(pid)
      after
        :ssh_sftp.stop_channel(pid)
      end
    end
  end

  defp metadata_read(pid, %{method: :list_dir, args: [path, max_entries, max_bytes]}, deadline) do
    with {:ok, handle} <- native(:ssh_sftp.opendir(pid, path, remaining(deadline)), :read),
         {:ok, result} <- directory(pid, handle, deadline, max_entries, max_bytes, {[], 0, 2}),
         :ok <- native(:ssh_sftp.close(pid, handle, remaining(deadline)), :read),
         do: {:ok, result}
  end

  defp metadata_read(pid, operation, deadline) do
    with {:ok, info} <-
           native(
             apply(:ssh_sftp, operation.method, [pid] ++ operation.args ++ [remaining(deadline)]),
             :read
           ),
         do: {:ok, metadata_result(operation.method, info)}
  end

  defp directory(pid, handle, deadline, max_entries, max_bytes, state) do
    case native(:ssh_sftp.readdir(pid, handle, remaining(deadline)), :read) do
      :eof ->
        {:ok, directory_result(state, "eof")}

      {:ok, entries} when is_list(entries) and entries != [] ->
        case collect_entries(entries, state, max_entries, max_bytes) do
          {:continue, next} -> directory(pid, handle, deadline, max_entries, max_bytes, next)
          {:stop, result} -> {:ok, result}
        end

      {:error, _, _} = error ->
        error

      _ ->
        {:error, :failed, "SFTP directory response was invalid"}
    end
  end

  defp collect_entries(_entries, {_, count, _} = state, max_entries, _max_bytes)
       when count == max_entries,
       do: {:stop, directory_result(state, "entry_limit")}

  defp collect_entries([], state, _max_entries, _max_bytes), do: {:continue, state}

  defp collect_entries(
         [{name, info} | tail],
         {entries, count, size} = state,
         max_entries,
         max_bytes
       ) do
    entry = %{
      "name" => :unicode.characters_to_binary(name),
      "attributes" => attributes(:ssh_sftp.attr_to_info(info))
    }

    next_size = size + byte_size(Jason.encode!(entry)) + if(count == 0, do: 0, else: 1)

    if next_size > max_bytes,
      do: {:stop, directory_result(state, "byte_limit")},
      else:
        collect_entries(tail, {[entry | entries], count + 1, next_size}, max_entries, max_bytes)
  end

  defp directory_result({entries, _count, bytes}, reason),
    do: %{
      "entries" => Enum.reverse(entries),
      "entries_bytes" => bytes,
      "completion_reason" => reason
    }

  defp native_args(%{method: :make_symlink, args: [path, target]}, connection) do
    # OpenSSH v3 consumes target,link, unlike OTP's link,target codec. Select
    # the dialect on this pinned connection before dispatch; never retry a write.
    case :ssh.connection_info(connection, :server_version) do
      {:server_version, {_version, banner}} ->
        if String.starts_with?(to_string(banner), ["SSH-2.0-OpenSSH_", "OpenSSH_"]),
          do: [target, path],
          else: [path, target]

      _ ->
        [path, target]
    end
  end

  defp native_args(%{method: :write_file_info, args: [path, values]}, _connection) do
    fields =
      Enum.map(@file_info, fn {field, default} ->
        case Map.fetch(values, Atom.to_string(field)) do
          {:ok, value} -> native_value(value)
          :error -> default
        end
      end)

    [path, List.to_tuple([:file_info | fields])]
  end

  defp native_args(operation, _connection), do: operation.args

  defp native_value([[year, month, day], [hour, minute, second]]),
    do: {{year, month, day}, {hour, minute, second}}

  defp native_value(value) when is_binary(value),
    do:
      Map.fetch!(
        %{
          "regular" => :regular,
          "directory" => :directory,
          "symlink" => :symlink,
          "device" => :device,
          "other" => :other
        },
        value
      )

  defp native_value(value), do: value

  defp metadata_result(method, info) when method in [:read_file_info, :read_link_info],
    do: %{"attributes" => attributes(info)}

  defp metadata_result(:read_link, target),
    do: %{"target" => :unicode.characters_to_binary(target)}

  defp metadata_result(:real_path, names),
    do: %{
      "paths" =>
        Enum.map(names, fn {name, _attributes} -> :unicode.characters_to_binary(name) end)
    }

  # These are the attributes carried by OTP's native SFTP codec. Do not present
  # its synthetic inode/device/link defaults as observations from the server.
  defp attributes(file_info() = info) do
    @file_info
    |> Keyword.keys()
    |> Enum.zip(Tuple.to_list(info) |> tl())
    |> Enum.filter(fn {key, _} -> key in @attributes end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_value(value)} end)
  end

  defp json_value(:undefined), do: nil
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_value/1)

  defp json_value(value), do: value

  defp download(pid, handle, writer, deadline, offset) do
    case native(
           :ssh_sftp.read(
             pid,
             handle,
             min(@chunk_bytes, writer.chunk_bytes),
             remaining(deadline)
           ),
           :read
         ) do
      :eof ->
        {:ok, offset}

      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        with {:ok, next} <- writer.append.(offset, bytes),
             true <- next == offset + byte_size(bytes),
             do: download(pid, handle, writer, deadline, next),
             else: (_ -> file_error())

      {:error, _, _} = error ->
        error

      _ ->
        file_error()
    end
  end

  defp upload(pid, handle, file, reader, deadline) do
    with {:ok, {_window, packet_bytes}} <-
           native(:ssh_sftp.send_window(pid, remaining(deadline)), :write) do
      Target.FileWriter.stream(file, reader)
      |> Enum.reduce_while(:ok, fn bytes, :ok ->
        case write_chunks(pid, handle, bytes, min(@chunk_bytes, packet_bytes), deadline) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  catch
    {:file_read_error, _} ->
      {:error, :disconnected_after_dispatch,
       "SFTP input file became unavailable; the remote file may be partial"}
  end

  defp write_chunks(_pid, _handle, <<>>, _limit, _deadline), do: :ok

  defp write_chunks(pid, handle, bytes, limit, deadline) do
    count = min(byte_size(bytes), limit)
    <<chunk::binary-size(^count), tail::binary>> = bytes

    with :ok <- native(:ssh_sftp.write(pid, handle, chunk, remaining(deadline)), :write),
         do: write_chunks(pid, handle, tail, limit, deadline)
  end

  defp preflight(%{"size_bytes" => size}, reader) do
    case reader.(0) do
      {:ok, bytes}
      when is_binary(bytes) and byte_size(bytes) <= size and (size == 0 or byte_size(bytes) > 0) ->
        :ok

      _ ->
        file_error()
    end
  end

  defp reader(%{label: label}, %{file_reader: callback}) when is_function(callback, 2),
    do: {:ok, fn offset -> callback.(label, offset) end}

  defp reader(_operation, _invocation), do: file_error()

  defp writer(%{"name" => name, "media_type" => media}, %{file_writer: callback})
       when is_function(callback, 3) do
    case callback.(Ecto.UUID.generate(), name, media) do
      {:ok, %Target.FileWriter{status: :receiving, offset: 0} = writer} -> {:ok, writer}
      _ -> file_error()
    end
  end

  defp writer(_output, _invocation), do: file_error()
  defp file_error, do: {:error, :failed, "SFTP file transfer could not be saved or read"}

  defp append_receipt(_writer, <<>>, _offset), do: :ok

  defp append_receipt(writer, bytes, offset) do
    count = min(writer.chunk_bytes, byte_size(bytes))
    <<chunk::binary-size(^count), tail::binary>> = bytes

    with {:ok, next} <- writer.append.(offset, chunk),
         true <- next == offset + count,
         do: append_receipt(writer, tail, next),
         else: (_ -> file_error())
  end

  defp publish(writer, size, reason) do
    case writer.complete.(size, nil, reason) do
      {:ok, file} -> {:ok, file}
      {:error, %{category: :cancelled}} -> {:error, :cancelled, "SFTP transfer was cancelled"}
      _ -> file_error()
    end
  end

  defp native({:error, reason}, phase)
       when reason in [:timeout, :closed, :no_connection, :connection_lost] do
    category =
      if phase in [:write, :write_open, :mutation],
        do: :disconnected_after_dispatch,
        else: :disconnected

    {:error, category, "SFTP connection interrupted"}
  end

  defp native({:error, _reason}, :write),
    do:
      {:error, :disconnected_after_dispatch, "SFTP write stopped; the remote file may be partial"}

  defp native({:error, _reason}, _phase),
    do: {:error, :failed, "SFTP server rejected the file request"}

  defp native(result, _phase), do: result
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp active(%{cancelled?: callback}) when is_function(callback, 0),
    do: if(callback.(), do: {:error, :cancelled, "SFTP transfer was cancelled"}, else: :ok)

  defp active(_invocation), do: :ok
end
