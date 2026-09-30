defmodule Opsonde.Transports.Kubernetes do
  @moduledoc false

  @configuration_keys ~w(namespace request_timeout_ms)
  @credential_keys ~w(kubeconfig)
  @name_pattern ~r/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/

  defmodule State do
    @moduledoc false
    @enforce_keys [:connection, :namespace, :endpoint, :request_timeout]
    defstruct @enforce_keys
  end

  def build(configuration, credentials)
      when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, namespace} <- namespace(configuration),
         {:ok, timeout} <- timeout(configuration),
         kubeconfig when is_binary(kubeconfig) <- Map.get(credentials, "kubeconfig"),
         true <- byte_size(kubeconfig) in 1..65_536,
         :ok <- static_kubeconfig(kubeconfig),
         {:ok, connection} <- K8s.Conn.from_string(kubeconfig),
         endpoint when is_binary(endpoint) <- connection.url do
      {:ok,
       %State{
         connection: connection,
         namespace: namespace,
         endpoint: String.trim_trailing(endpoint, "/"),
         request_timeout: timeout
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  rescue
    _error -> {:error, :invalid_configuration}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with :ok <- endpoint(state, endpoint),
         operation <- %{
           method: :get,
           path: "/api",
           query: [],
           body: nil,
           headers: [{"accept", "application/json"}]
         },
         {:ok, %{status: status}} <- run(state, operation, %{}, :read) do
      case status do
        status when status in 200..299 -> :ok
        401 -> {:error, :authentication, "Kubernetes authentication failed"}
        403 -> {:error, :capability, "Kubernetes API discovery is forbidden"}
        _ -> {:error, :capability, "Kubernetes API rejected the connection check"}
      end
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :forbidden, message} -> {:error, :capability, message}
      {:error, :invalid_configuration, message} -> {:error, :invalid_configuration, message}
      {:error, _category, message} -> {:error, :unreachable, message}
      _ -> {:error, :capability, "Kubernetes API rejected the connection check"}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Kubernetes check requires an endpoint"}

  defp request(state, operation, invocation) do
    with {:ok, options} <- K8s.Conn.RequestOptions.generate(state.connection) do
      host = URI.parse(state.endpoint).host

      tls =
        if state.connection.ca_cert,
          do: Opsonde.Transports.HTTPS.custom_trust_options([state.connection.ca_cert], host),
          else: [
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]

      headers =
        Enum.map(options.headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)

      request_options = [
        method: operation.method,
        url: state.endpoint <> operation.path,
        params: operation.query,
        headers: headers ++ operation.headers ++ [{"accept-encoding", "identity"}],
        connect_options: [
          timeout: state.request_timeout,
          transport_opts: Keyword.merge(options.ssl_options, tls)
        ],
        receive_timeout: state.request_timeout,
        retry: false,
        redirect: false,
        raw: true,
        into: &collect/2
      ]

      Opsonde.Transports.HTTP.request(
        request_options,
        operation.body,
        Map.get(operation, :response_file),
        invocation
      )
    end
  end

  defp collect({:data, data}, {request, response}) do
    accumulated = if is_binary(response.body), do: response.body, else: ""

    if byte_size(accumulated) + byte_size(data) <= 65_536,
      do: {:cont, {request, %{response | body: accumulated <> data}}},
      else: {:halt, {request, %{response | body: :too_large}}}
  end

  def run(state, operation, invocation, phase) when is_map(operation) and is_map(invocation),
    do:
      run_request(
        state,
        fn -> request(state, operation, invocation) end,
        cancelled?(invocation),
        phase
      )

  defp run_request(state, operation, cancelled?, phase) do
    if cancelled?.() do
      {:error, :cancelled, "Kubernetes operation was cancelled"}
    else
      task = Task.async(fn -> safely(operation) end)
      await(task, cancelled?, System.monotonic_time(:millisecond) + state.request_timeout, phase)
    end
  rescue
    _error -> {:error, :failed, "Kubernetes operation failed"}
  end

  defp await(task, cancelled?, deadline, phase) do
    cond do
      cancelled?.() ->
        Task.shutdown(task, :brutal_kill)
        {:error, after_dispatch(phase, :cancelled), "Kubernetes operation was cancelled"}

      System.monotonic_time(:millisecond) >= deadline ->
        Task.shutdown(task, :brutal_kill)
        {:error, after_dispatch(phase, :timeout), "Kubernetes operation timed out"}

      true ->
        case Task.yield(task, 20) do
          {:ok, result} -> normalize(result, phase)
          {:exit, _reason} -> operation_failure(phase)
          nil -> await(task, cancelled?, deadline, phase)
        end
    end
  end

  defp safely(operation) do
    operation.()
  rescue
    error -> {:error, error}
  catch
    _kind, reason -> {:error, reason}
  end

  defp normalize({:ok, %Req.Response{body: :too_large}}, :effect),
    do:
      {:error, :unknown_after_dispatch,
       "Kubernetes response exceeded the inline size limit after dispatch"}

  defp normalize({:ok, %Req.Response{body: :too_large}}, _phase),
    do: {:error, :failed, "Kubernetes response exceeded the inline size limit"}

  defp normalize({:ok, %Req.Response{private: %{opsonde_file: file}} = response}, _phase) do
    {:ok,
     %{
       status: response.status,
       content_type: List.first(Req.Response.get_header(response, "content-type")) || "",
       body: "",
       file: file,
       content_encoding: Enum.join(Req.Response.get_header(response, "content-encoding"), ",")
     }}
  end

  defp normalize({:ok, %Req.Response{} = response}, phase) do
    raw = response.body || ""
    content_type = response |> Req.Response.get_header("content-type") |> List.first() || ""
    content_type = content_type |> String.split(";") |> hd()

    encoding = Req.Response.get_header(response, "content-encoding")
    json? = String.ends_with?(String.downcase(content_type), ["/json", "+json"])
    body = if json? and raw != "", do: Jason.decode(raw), else: {:ok, raw}

    if String.valid?(raw) and encoding in [[], ["identity"]] and match?({:ok, _}, body) do
      {:ok, %{status: response.status, content_type: content_type, body: elem(body, 1)}}
    else
      invalid_inline_response(phase)
    end
  end

  defp normalize({:error, _category, message}, :effect),
    do: {:error, :unknown_after_dispatch, message}

  defp normalize({:error, category, message}, _phase), do: {:error, category, message}

  defp normalize({:error, _error}, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize({:error, _error}, _phase),
    do: {:error, :unreachable, "Kubernetes API request failed"}

  defp normalize(_result, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize(_result, _phase),
    do: {:error, :failed, "Kubernetes API response is invalid"}

  defp invalid_inline_response(:effect),
    do:
      {:error, :unknown_after_dispatch,
       "Kubernetes did not return a valid UTF-8 inline response after dispatch"}

  defp invalid_inline_response(_phase),
    do: {:error, :failed, "Kubernetes did not return a valid UTF-8 inline response"}

  defp operation_failure(:effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp operation_failure(_phase), do: {:error, :failed, "Kubernetes operation failed"}

  def endpoint(state, endpoint) when is_binary(endpoint) do
    if String.trim_trailing(endpoint, "/") == state.endpoint,
      do: :ok,
      else: {:error, :invalid_configuration, "Kubernetes endpoint does not match kubeconfig"}
  end

  def endpoint(_state, _endpoint),
    do: {:error, :invalid_configuration, "Kubernetes endpoint is invalid"}

  defp timeout(configuration) do
    case Map.get(configuration, "request_timeout_ms", 30_000) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp static_kubeconfig(kubeconfig) do
    with {:ok, document} <- YamlElixir.read_from_string(kubeconfig),
         true <- static_users?(document["users"]),
         true <- static_clusters?(document["clusters"]) do
      :ok
    else
      _error -> {:error, :unsafe_kubeconfig}
    end
  end

  defp static_users?(users) when is_list(users) and users != [] do
    Enum.all?(users, fn
      %{"user" => user} when is_map(user) ->
        static_user?(user)

      _user ->
        false
    end)
  end

  defp static_users?(_users), do: false

  defp static_user?(%{"token" => token} = user),
    do: map_size(user) == 1 and nonempty?(token)

  defp static_user?(
         %{
           "client-certificate-data" => certificate,
           "client-key-data" => private_key
         } = user
       ),
       do: map_size(user) == 2 and nonempty?(certificate) and nonempty?(private_key)

  defp static_user?(_user), do: false

  defp static_clusters?(clusters) when is_list(clusters) and clusters != [] do
    Enum.all?(clusters, fn
      %{"cluster" => cluster} when is_map(cluster) ->
        is_binary(cluster["server"]) and
          cluster["insecure-skip-tls-verify"] != true and
          not Map.has_key?(cluster, "certificate-authority")

      _cluster ->
        false
    end)
  end

  defp static_clusters?(_clusters), do: false

  defp exact_keys(map, allowed) do
    if exact_keys?(map, allowed),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp exact_keys?(map, allowed),
    do: Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed))

  defp namespace(configuration) do
    case Map.get(configuration, "namespace") do
      value when value in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        if valid_name?(value), do: {:ok, value}, else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end

  defp after_dispatch(:effect, :cancelled), do: :cancelled_after_dispatch
  defp after_dispatch(:effect, :timeout), do: :timeout_after_dispatch
  defp after_dispatch(_phase, category), do: category

  def valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..253 and Regex.match?(@name_pattern, value)
end
