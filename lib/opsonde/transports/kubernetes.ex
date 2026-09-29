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
         {:ok, namespace} <- required_name(configuration, "namespace"),
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
         operation <-
           K8s.Client.list("v1", "Pod", namespace: state.namespace)
           |> K8s.Operation.put_query_param(:limit, "1"),
         {:ok, _result} <- run(state, operation, fn -> false end, :read) do
      :ok
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :forbidden, message} -> {:error, :capability, message}
      {:error, :invalid_configuration, message} -> {:error, :invalid_configuration, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Kubernetes check requires an endpoint"}

  def run_observation(state, operation, {:watch, max_events}, cancelled?) do
    run(
      state,
      fn ->
        with {:ok, stream} <- K8s.Client.stream(state.connection, operation) do
          {:ok, Enum.take(stream, max_events)}
        end
      end,
      cancelled?,
      :read
    )
  end

  def run_observation(state, operation, _decoder, cancelled?),
    do: run(state, operation, cancelled?, :read)

  def run(state, %K8s.Operation{} = operation, cancelled?, phase),
    do: run(state, fn -> K8s.Client.run(state.connection, operation) end, cancelled?, phase)

  def run(state, operation, cancelled?, phase) when is_function(operation, 0) do
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

  defp normalize({:ok, result}, _phase), do: {:ok, result}

  defp normalize({:error, %K8s.Client.APIError{reason: "Conflict"}}, _phase),
    do: {:error, :conflict, "Kubernetes resource changed"}

  defp normalize({:error, %K8s.Client.APIError{reason: "Forbidden"}}, _phase),
    do: {:error, :forbidden, "Kubernetes request is forbidden"}

  defp normalize({:error, %K8s.Client.APIError{reason: "Unauthorized"}}, _phase),
    do: {:error, :authentication, "Kubernetes authentication failed"}

  defp normalize({:error, %K8s.Client.APIError{reason: "NotFound"}}, _phase),
    do: {:error, :not_found, "Kubernetes resource was not found"}

  defp normalize({:error, %K8s.Client.APIError{}}, _phase),
    do: {:error, :api_rejected, "Kubernetes request was rejected"}

  defp normalize({:error, _error}, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize({:error, _error}, _phase),
    do: {:error, :unreachable, "Kubernetes API request failed"}

  defp normalize(_result, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize(_result, _phase),
    do: {:error, :failed, "Kubernetes API response is invalid"}

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

  defp required_name(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if valid_name?(value), do: {:ok, value}, else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp after_dispatch(:effect, :cancelled), do: :cancelled_after_dispatch
  defp after_dispatch(:effect, :timeout), do: :timeout_after_dispatch
  defp after_dispatch(_phase, category), do: category

  def valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..253 and Regex.match?(@name_pattern, value)
end
