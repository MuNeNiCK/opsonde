defmodule Opsonde.Transports.SSH.SFTP do
  @moduledoc false
  alias Opsonde.Providers.Target
  @chunk_bytes 32_768

  # The supplied runner owns the pinned connection, task, deadline and disposal.
  # Supplied file ports own authorization and storage; publication is caller-side.
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
         {:ok, file} <- publish(writer, size),
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

  defp publish(writer, size) do
    case writer.complete.(size, nil, :eof) do
      {:ok, file} -> {:ok, file}
      {:error, %{category: :cancelled}} -> {:error, :cancelled, "SFTP transfer was cancelled"}
      _ -> file_error()
    end
  end

  defp native({:error, reason}, phase) when reason in [:timeout, :closed] do
    category =
      if phase in [:write, :write_open], do: :disconnected_after_dispatch, else: :disconnected

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
