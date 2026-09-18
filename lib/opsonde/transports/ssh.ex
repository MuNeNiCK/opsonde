defmodule Opsonde.Transports.SSH do
  @moduledoc false

  @configuration_keys ~w(host_key_fingerprints connect_timeout_ms operation_timeout_ms max_output_bytes legacy_algorithms)
  @credential_keys ~w(username auth_method password private_key)
  @default_connect_timeout 10_000
  @default_operation_timeout 30_000
  @default_max_output_bytes 32_768
  @maximum_timeout 600_000
  @maximum_output_bytes 60_000
  @maximum_command_bytes 4_096
  @poll_interval 20

  defmodule Config do
    @moduledoc false
    @enforce_keys [
      :username,
      :authentication,
      :host_key_fingerprints,
      :legacy_algorithms,
      :connect_timeout,
      :operation_timeout,
      :max_output_bytes
    ]
    defstruct @enforce_keys
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [:stdout, :stderr, :exit_status]
    defstruct @enforce_keys
  end

  defmodule ShellResult do
    @moduledoc false
    @enforce_keys [:output]
    defstruct @enforce_keys
  end

  defmodule Channel do
    @moduledoc false
    @enforce_keys [:connection, :id, :deadline, :max_output_bytes, :reporter]
    defstruct @enforce_keys
  end

  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, username} <- required_string(credentials, "username", 255),
         {:ok, authentication} <- authentication(credentials),
         {:ok, fingerprints} <- fingerprints(configuration),
         {:ok, legacy_algorithms} <- legacy_algorithms(configuration),
         {:ok, connect_timeout} <-
           bounded_integer(configuration, "connect_timeout_ms", @default_connect_timeout, 100),
         {:ok, operation_timeout} <-
           bounded_integer(
             configuration,
             "operation_timeout_ms",
             @default_operation_timeout,
             100
           ),
         {:ok, max_output_bytes} <-
           bounded_integer(
             configuration,
             "max_output_bytes",
             @default_max_output_bytes,
             1,
             @maximum_output_bytes
           ) do
      {:ok,
       %Config{
         username: username,
         authentication: authentication,
         host_key_fingerprints: fingerprints,
         legacy_algorithms: legacy_algorithms,
         connect_timeout: connect_timeout,
         operation_timeout: operation_timeout,
         max_output_bytes: max_output_bytes
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  def check(%Config{} = config, endpoint, cancelled? \\ fn -> false end) do
    run(config, endpoint, cancelled?, fn _connection, _deadline, _parent, _reference -> :ok end)
  end

  def exec(%Config{} = config, endpoint, command, cancelled? \\ fn -> false end) do
    with :ok <- command(command) do
      run(config, endpoint, cancelled?, fn connection, deadline, parent, reference ->
        execute(connection, command, config.max_output_bytes, deadline, parent, reference)
      end)
    end
  end

  def shell(%Config{} = config, endpoint, script, cancelled? \\ fn -> false end) do
    with :ok <- command(script) do
      run(config, endpoint, cancelled?, fn connection, deadline, parent, reference ->
        execute_shell(connection, script, config.max_output_bytes, deadline, parent, reference)
      end)
    end
  end

  def subsystem(%Config{} = config, endpoint, name, exchange, cancelled? \\ fn -> false end)
      when is_function(exchange, 1) do
    with :ok <- subsystem_name(name) do
      run(config, endpoint, cancelled?, fn connection, deadline, parent, reference ->
        execute_subsystem(
          connection,
          name,
          config.max_output_bytes,
          deadline,
          parent,
          reference,
          exchange
        )
      end)
    end
  end

  def channel_send(channel, data), do: channel_send(channel, data, true)

  def channel_send(%Channel{} = channel, data, dispatched?)
      when is_binary(data) and is_boolean(dispatched?) do
    if byte_size(data) in 1..@maximum_output_bytes do
      case :ssh_connection.send(channel.connection, channel.id, data, remaining(channel.deadline)) do
        :ok ->
          if dispatched? do
            {parent, reference} = channel.reporter
            send(parent, {:opsonde_ssh_dispatched, reference, channel.connection})
          end

          :ok

        {:error, reason} ->
          transport_error_after_dispatch(reason)
      end
    else
      {:error, :failed, "SSH channel payload is invalid"}
    end
  end

  def channel_send(_channel, _data, _dispatched?),
    do: {:error, :failed, "SSH channel payload is invalid"}

  def channel_receive(%Channel{} = channel, buffer, complete?)
      when is_binary(buffer) and is_function(complete?, 1),
      do: receive_channel(channel, buffer, complete?)

  defp run(config, endpoint, cancelled?, operation) when is_function(cancelled?, 0) do
    with {:ok, host, port, fingerprint} <- endpoint(config, endpoint),
         {:ok, _started} <- Application.ensure_all_started(:ssh) do
      if cancelled?(cancelled?),
        do: {:error, :cancelled, "SSH operation was cancelled"},
        else: run_task(config, host, port, fingerprint, cancelled?, operation)
    else
      {:error, category, message} -> {:error, category, message}
      _error -> {:error, :failed, "SSH transport failed"}
    end
  rescue
    _error -> {:error, :failed, "SSH transport failed"}
  catch
    _kind, _reason -> {:error, :failed, "SSH transport failed"}
  end

  defp run_task(config, host, port, fingerprint, cancelled?, operation) do
    parent = self()
    reference = make_ref()
    deadline = System.monotonic_time(:millisecond) + config.operation_timeout

    task =
      Task.async(fn ->
        try do
          with {:ok, connection} <- connect(config, host, port, fingerprint) do
            send(parent, {:opsonde_ssh_connection, reference, connection})

            try do
              operation.(connection, deadline, parent, reference)
            after
              :ssh.close(connection)
            end
          end
        rescue
          _error -> {:error, :failed, "SSH transport failed"}
        catch
          _kind, _reason -> {:error, :failed, "SSH transport failed"}
        end
      end)

    await(task, reference, nil, :connecting, cancelled?, deadline)
  end

  defp connect(config, host, port, fingerprint) do
    host_key_reference = make_ref()

    options = [
      {:user, String.to_charlist(config.username)},
      {:user_interaction, false},
      {:quiet_mode, true},
      {:save_accepted_host, false},
      {:key_cb,
       {Opsonde.Transports.SSH.KeyCallback,
        [
          fingerprint: fingerprint,
          private_key: private_key(config.authentication),
          reporter: {self(), host_key_reference}
        ]}},
      {:auth_methods, auth_method(config.authentication)}
    ]

    options =
      options
      |> authentication_options(config.authentication)
      |> algorithm_options(config.legacy_algorithms)

    case :ssh.connect(String.to_charlist(host), port, options, config.connect_timeout) do
      {:ok, connection} ->
        {:ok, connection}

      {:error, reason} ->
        if host_key_rejected?(host_key_reference),
          do: {:error, :host_key, "SSH host key verification failed"},
          else: connect_error(reason)
    end
  end

  defp execute(connection, command, max_output_bytes, deadline, parent, reference) do
    timeout = remaining(deadline)

    with {:ok, channel} <- :ssh_connection.session_channel(connection, timeout) do
      send(parent, {:opsonde_ssh_dispatched, reference, connection})

      case :ssh_connection.exec(connection, channel, String.to_charlist(command), timeout) do
        :success -> collect(connection, channel, max_output_bytes, deadline, <<>>, <<>>, nil)
        {:error, reason} -> transport_error_after_dispatch(reason)
        :failure -> {:error, :disconnected_after_dispatch, "SSH command was rejected"}
        _other -> {:error, :disconnected_after_dispatch, "SSH command failed"}
      end
    else
      {:error, reason} -> transport_error(reason)
    end
  end

  defp execute_shell(connection, script, max_output_bytes, deadline, parent, reference) do
    timeout = remaining(deadline)

    with {:ok, channel} <- :ssh_connection.session_channel(connection, timeout),
         :success <- :ssh_connection.ptty_alloc(connection, channel, [], timeout),
         :ok <- :ssh_connection.shell(connection, channel),
         :ok <- :ssh_connection.send(connection, channel, script, timeout) do
      send(parent, {:opsonde_ssh_dispatched, reference, connection})
      collect_shell(connection, channel, max_output_bytes, deadline, <<>>)
    else
      {:error, reason} -> transport_error(reason)
      :failure -> {:error, :failed, "SSH shell was rejected"}
      _other -> {:error, :failed, "SSH shell failed"}
    end
  end

  defp execute_subsystem(
         connection,
         name,
         max_output_bytes,
         deadline,
         parent,
         reference,
         exchange
       ) do
    timeout = remaining(deadline)

    with {:ok, channel} <- :ssh_connection.session_channel(connection, timeout),
         :success <-
           :ssh_connection.subsystem(connection, channel, String.to_charlist(name), timeout) do
      exchange.(%Channel{
        connection: connection,
        id: channel,
        deadline: deadline,
        max_output_bytes: max_output_bytes,
        reporter: {parent, reference}
      })
    else
      {:error, reason} -> transport_error(reason)
      :failure -> {:error, :failed, "SSH subsystem is unavailable"}
      _other -> {:error, :failed, "SSH subsystem failed"}
    end
  end

  defp collect_shell(connection, channel, limit, deadline, output) do
    timeout = remaining(deadline)

    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _stream, data}} when is_binary(data) ->
        if byte_size(output) + byte_size(data) > limit do
          :ssh_connection.close(connection, channel)
          {:error, :output_limit_after_dispatch, "SSH shell output exceeded its limit"}
        else
          collect_shell(connection, channel, limit, deadline, output <> data)
        end

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        collect_shell(connection, channel, limit, deadline, output)

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:ok, %ShellResult{output: output}}

      {:ssh_cm, ^connection, {:exit_status, ^channel, _status}} ->
        collect_shell(connection, channel, limit, deadline, output)

      {:ssh_cm, ^connection, {:exit_signal, ^channel, _signal, _error, _language}} ->
        {:error, :disconnected_after_dispatch, "SSH shell exited unexpectedly"}
    after
      timeout ->
        :ssh_connection.close(connection, channel)
        {:error, :timeout_after_dispatch, "SSH shell timed out"}
    end
  end

  defp receive_channel(channel, buffer, complete?) do
    case complete?.(buffer) do
      {:ok, value, rest} ->
        {:ok, value, rest}

      :more ->
        timeout = remaining(channel.deadline)

        receive do
          {:ssh_cm, connection, {:data, id, _stream, data}}
          when connection == channel.connection and id == channel.id and is_binary(data) ->
            if byte_size(buffer) + byte_size(data) > channel.max_output_bytes do
              :ssh_connection.close(channel.connection, channel.id)
              {:error, :output_limit_after_dispatch, "SSH subsystem output exceeded its limit"}
            else
              receive_channel(channel, buffer <> data, complete?)
            end

          {:ssh_cm, connection, {:eof, id}}
          when connection == channel.connection and id == channel.id ->
            {:error, :disconnected_after_dispatch, "SSH subsystem closed before its reply"}

          {:ssh_cm, connection, {:closed, id}}
          when connection == channel.connection and id == channel.id ->
            {:error, :disconnected_after_dispatch, "SSH subsystem closed before its reply"}
        after
          timeout -> {:error, :timeout_after_dispatch, "SSH subsystem timed out"}
        end

      {:error, _category, _message} = error ->
        error

      _other ->
        {:error, :failed, "SSH subsystem response matcher is invalid"}
    end
  end

  defp collect(connection, channel, limit, deadline, stdout, stderr, exit_status) do
    timeout = remaining(deadline)

    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, data}} ->
        append(connection, channel, limit, deadline, stdout, stderr, exit_status, :stdout, data)

      {:ssh_cm, ^connection, {:data, ^channel, 1, data}} ->
        append(connection, channel, limit, deadline, stdout, stderr, exit_status, :stderr, data)

      {:ssh_cm, ^connection, {:exit_status, ^channel, status}}
      when is_integer(status) and status >= 0 ->
        collect(connection, channel, limit, deadline, stdout, stderr, status)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        collect(connection, channel, limit, deadline, stdout, stderr, exit_status)

      {:ssh_cm, ^connection, {:closed, ^channel}} when is_integer(exit_status) ->
        {:ok, %Result{stdout: stdout, stderr: stderr, exit_status: exit_status}}

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:error, :disconnected_after_dispatch, "SSH command closed without an exit status"}

      {:ssh_cm, ^connection, {:exit_signal, ^channel, _signal, _error, _language}} ->
        {:error, :disconnected_after_dispatch, "SSH command exited without a status"}
    after
      timeout ->
        :ssh_connection.close(connection, channel)
        {:error, :timeout_after_dispatch, "SSH command timed out"}
    end
  end

  defp append(connection, channel, limit, deadline, stdout, stderr, exit_status, stream, data)
       when is_binary(data) do
    if byte_size(stdout) + byte_size(stderr) + byte_size(data) > limit do
      :ssh_connection.close(connection, channel)
      {:error, :output_limit_after_dispatch, "SSH command output exceeded its limit"}
    else
      {stdout, stderr} =
        case stream do
          :stdout -> {stdout <> data, stderr}
          :stderr -> {stdout, stderr <> data}
        end

      collect(connection, channel, limit, deadline, stdout, stderr, exit_status)
    end
  end

  defp await(task, reference, connection, phase, cancelled?, deadline) do
    cond do
      cancelled?(cancelled?) ->
        phase = latest_phase(reference, connection, phase)
        close(connection)
        Task.shutdown(task, :brutal_kill)
        {:error, cancellation_category(phase), "SSH operation was cancelled"}

      System.monotonic_time(:millisecond) >= deadline ->
        phase = latest_phase(reference, connection, phase)
        close(connection)
        Task.shutdown(task, :brutal_kill)
        {:error, timeout_category(phase), "SSH operation timed out"}

      true ->
        receive do
          {:opsonde_ssh_connection, ^reference, connected} ->
            await(task, reference, connected, :connected, cancelled?, deadline)

          {:opsonde_ssh_dispatched, ^reference, ^connection} ->
            await(task, reference, connection, :dispatched, cancelled?, deadline)
        after
          @poll_interval ->
            case Task.yield(task, 0) do
              {:ok, result} -> result
              {:exit, _reason} -> {:error, :failed, "SSH transport failed"}
              nil -> await(task, reference, connection, phase, cancelled?, deadline)
            end
        end
    end
  end

  defp endpoint(config, value) when is_binary(value) do
    case {URI.parse(value), Map.fetch(config.host_key_fingerprints, value)} do
      {%URI{scheme: "ssh", host: host} = uri, {:ok, fingerprint}}
      when is_binary(host) and byte_size(host) > 0 ->
        if valid_uri?(uri), do: {:ok, host, uri.port || 22, fingerprint}, else: invalid_endpoint()

      _other ->
        invalid_endpoint()
    end
  end

  defp endpoint(_config, _value), do: invalid_endpoint()

  defp valid_uri?(uri) do
    is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and uri.path in [nil, ""] and
      (is_nil(uri.port) or uri.port in 1..65_535)
  end

  defp fingerprints(configuration) do
    case Map.get(configuration, "host_key_fingerprints") do
      fingerprints
      when is_map(fingerprints) and map_size(fingerprints) > 0 and
             map_size(fingerprints) <= 1_000 ->
        if Enum.all?(fingerprints, fn {endpoint, fingerprint} ->
             valid_endpoint_key?(endpoint) and valid_fingerprint?(fingerprint)
           end),
           do: {:ok, fingerprints},
           else: {:error, :invalid_fingerprints}

      _fingerprints ->
        {:error, :invalid_fingerprints}
    end
  end

  defp authentication(credentials) do
    case Map.get(credentials, "auth_method") do
      "password" ->
        with {:ok, password} <- required_string(credentials, "password", 4_096),
             nil <- Map.get(credentials, "private_key") do
          {:ok, {:password, password}}
        else
          _error -> {:error, :invalid_password_authentication}
        end

      "public_key" ->
        with {:ok, encoded} <- required_string(credentials, "private_key", 65_536),
             nil <- Map.get(credentials, "password"),
             {:ok, key} <- decode_private_key(encoded) do
          algorithms =
            :ssh.default_algorithms()
            |> Keyword.fetch!(:public_key)
            |> Enum.filter(&:ssh_transport.valid_key_sha_alg(:private, key, &1))

          if algorithms == [],
            do: {:error, :invalid_public_key_authentication},
            else: {:ok, {:public_key, key, algorithms}}
        else
          _error -> {:error, :invalid_public_key_authentication}
        end

      _method ->
        {:error, :invalid_authentication_method}
    end
  end

  defp decode_private_key(encoded) do
    keys =
      if String.contains?(encoded, "BEGIN OPENSSH PRIVATE KEY") do
        case :ssh_file.decode(encoded, :openssh_key_v1) do
          values when is_list(values) -> Enum.map(values, &elem(&1, 0))
          _error -> []
        end
      else
        encoded
        |> :public_key.pem_decode()
        |> Enum.map(&:public_key.pem_entry_decode/1)
      end

    case Enum.find(keys, &private_key?/1) do
      nil -> {:error, :invalid_private_key}
      key -> {:ok, key}
    end
  rescue
    _error -> {:error, :invalid_private_key}
  catch
    _kind, _reason -> {:error, :invalid_private_key}
  end

  defp private_key?(key) do
    :ssh_file.extract_public_key(key)
    true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp command(value) when is_binary(value) and byte_size(value) in 1..@maximum_command_bytes do
    if String.contains?(value, <<0>>),
      do: {:error, :failed, "SSH command is invalid"},
      else: :ok
  end

  defp command(_value), do: {:error, :failed, "SSH command is invalid"}

  defp subsystem_name(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.match?(value, ~r/^[A-Za-z0-9._-]+$/),
      do: :ok,
      else: {:error, :failed, "SSH subsystem name is invalid"}
  end

  defp subsystem_name(_value), do: {:error, :failed, "SSH subsystem name is invalid"}

  defp legacy_algorithms(configuration) do
    algorithms = Map.get(configuration, "legacy_algorithms", [])
    allowed = ~w(ssh-rsa diffie-hellman-group-exchange-sha1 diffie-hellman-group14-sha1)

    if is_list(algorithms) and length(algorithms) <= length(allowed) and
         Enum.all?(algorithms, &(&1 in allowed)) and
         length(Enum.uniq(algorithms)) == length(algorithms),
       do: {:ok, algorithms},
       else: {:error, :invalid_legacy_algorithms}
  end

  defp authentication_options(options, {:password, password}),
    do: [{:password, String.to_charlist(password)} | options]

  defp authentication_options(options, {:public_key, _key, algorithms}),
    do: [{:pref_public_key_algs, algorithms} | options]

  defp algorithm_options(options, []), do: options

  defp algorithm_options(options, algorithms) do
    kex =
      Enum.flat_map(algorithms, fn
        "diffie-hellman-group-exchange-sha1" -> [:"diffie-hellman-group-exchange-sha1"]
        "diffie-hellman-group14-sha1" -> [:"diffie-hellman-group14-sha1"]
        _algorithm -> []
      end)

    public_key = if "ssh-rsa" in algorithms, do: [:"ssh-rsa"], else: []

    additions =
      []
      |> maybe_add_algorithm(:kex, kex)
      |> maybe_add_algorithm(:public_key, public_key)

    [{:modify_algorithms, [{:append, additions}]} | options]
  end

  defp maybe_add_algorithm(values, _kind, []), do: values
  defp maybe_add_algorithm(values, kind, algorithms), do: [{kind, algorithms} | values]

  defp auth_method({:password, _password}), do: ~c"password"
  defp auth_method({:public_key, _key, _algorithms}), do: ~c"publickey"
  defp private_key({:public_key, key, _algorithms}), do: key
  defp private_key({:password, _password}), do: nil

  defp connect_error(reason) do
    message = reason |> inspect() |> String.downcase()

    cond do
      String.contains?(message, "host key") or String.contains?(message, "host_key") ->
        {:error, :host_key, "SSH host key verification failed"}

      String.contains?(message, "auth") or String.contains?(message, "password") ->
        {:error, :authentication, "SSH authentication failed"}

      String.contains?(message, "timeout") ->
        {:error, :timeout, "SSH connection timed out"}

      true ->
        {:error, :unreachable, "SSH endpoint is unreachable"}
    end
  end

  defp transport_error(:timeout), do: {:error, :timeout, "SSH transport timed out"}
  defp transport_error(:closed), do: {:error, :disconnected, "SSH connection closed"}
  defp transport_error(_reason), do: {:error, :failed, "SSH transport failed"}

  defp transport_error_after_dispatch(:timeout),
    do: {:error, :timeout_after_dispatch, "SSH transport timed out"}

  defp transport_error_after_dispatch(_reason),
    do: {:error, :disconnected_after_dispatch, "SSH connection closed after dispatch"}

  defp latest_phase(reference, connection, phase) do
    receive do
      {:opsonde_ssh_dispatched, ^reference, ^connection} -> :dispatched
    after
      0 -> phase
    end
  end

  defp host_key_rejected?(reference) do
    receive do
      {:opsonde_ssh_host_key_rejected, ^reference} -> true
    after
      @poll_interval -> false
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp cancelled?(callback) do
    callback.() == true
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  defp close(nil), do: :ok
  defp close(connection), do: :ssh.close(connection)
  defp cancellation_category(:dispatched), do: :cancelled_after_dispatch
  defp cancellation_category(_phase), do: :cancelled
  defp timeout_category(:dispatched), do: :timeout_after_dispatch
  defp timeout_category(_phase), do: :timeout

  defp exact_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(to_string(&1) in allowed)),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp required_string(map, key, maximum) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum ->
        {:ok, value}

      _value ->
        {:error, :invalid_string}
    end
  end

  defp bounded_integer(map, key, default, minimum, maximum \\ @maximum_timeout) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= minimum and value <= maximum -> {:ok, value}
      _value -> {:error, :invalid_integer}
    end
  end

  defp valid_endpoint_key?(value), do: is_binary(value) and byte_size(value) in 1..1_024

  defp valid_fingerprint?("SHA256:" <> digest),
    do: byte_size(digest) in 20..100 and String.match?(digest, ~r/^[A-Za-z0-9+\/_-]+={0,2}$/)

  defp valid_fingerprint?(_fingerprint), do: false
  defp invalid_endpoint, do: {:error, :failed, "SSH endpoint or host key is invalid"}
end

defmodule Opsonde.Transports.SSH.KeyCallback do
  @moduledoc false
  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, _host, _port, _algorithm, options) do
    expected = private_option(options, :fingerprint)
    actual = :ssh.hostkey_fingerprint(:sha256, key) |> to_string()

    if is_binary(expected) and byte_size(actual) == byte_size(expected) and
         :crypto.hash_equals(actual, expected) do
      true
    else
      report_rejected_host_key(options)
      {:error, :opsonde_host_key_mismatch}
    end
  end

  @impl true
  def user_key(_algorithm, options) do
    case private_option(options, :private_key) do
      nil -> {:error, ~c"public key authentication is disabled"}
      key -> {:ok, key}
    end
  end

  @impl true
  def add_host_key(_host, _port, _key, _options), do: {:error, :host_key_not_persisted}

  defp private_option(options, key) do
    private = :proplists.get_value(:key_cb_private, options, [])
    Keyword.get(private, key)
  end

  defp report_rejected_host_key(options) do
    case private_option(options, :reporter) do
      {pid, reference} when is_pid(pid) ->
        send(pid, {:opsonde_ssh_host_key_rejected, reference})

      _reporter ->
        :ok
    end
  end
end
