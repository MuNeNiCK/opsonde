defmodule Opsonde.Targets.Adapters.Kubernetes.API do
  @moduledoc false
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target
  alias Opsonde.Providers.Target
  alias Opsonde.Targets.Profiles.Kubernetes, as: Profile

  @configuration_keys ~w(namespace request_timeout_ms)
  @credential_keys ~w(kubeconfig)

  @native_observation "native.kubernetes_api.observe"
  @native_effect "native.kubernetes_api.effect"
  @native_observation_query_keys %{
    "continue" => :continue,
    "fieldSelector" => :fieldSelector,
    "limit" => :limit,
    "pretty" => :pretty,
    "resourceVersion" => :resourceVersion,
    "resourceVersionMatch" => :resourceVersionMatch,
    "timeoutSeconds" => :timeoutSeconds
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [:connection, :namespace, :endpoint, :request_timeout]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "kubernetes-api"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    {:ok, operations} = capabilities(nil, %{})

    %Target.AccessMethodProfile{
      method: "api",
      capabilities: Target.capability_names(operations)
    }
  end

  @impl Opsonde.Providers.Adapter
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

  @impl Opsonde.Providers.Adapter
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

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation), do: {:ok, Profile.capabilities(native_operations())}

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, %{capability: @native_observation} = request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation} <- native_observation_operation(state, request),
         {:ok, response} <- run(state, operation, cancelled?(invocation), :read) do
      {:ok,
       %Target.Observation{
         facts: %{"response" => response},
         observed_at: DateTime.utc_now()
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  def observe(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation, decoder} <- Profile.observation_operation(state.namespace, request),
         {:ok, result} <- run_observation(state, operation, decoder, cancelled?(invocation)),
         {:ok, facts} <- Profile.decode(decoder, result) do
      {:ok, %Target.Observation{facts: facts, observed_at: DateTime.utc_now()}}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def preflight(%State{} = state, %{capability: @native_observation} = request) do
    case native_observation_operation(state, request) do
      {:ok, _operation} -> :ok
      {:error, _category, _message} = error -> error
    end
  end

  def preflight(%State{} = state, request) do
    case Profile.observation_operation(state.namespace, request) do
      {:ok, _operation, _decoder} -> :ok
      {:error, _category, _message} = error -> error
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, %{capability: @native_effect} = request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation} <- native_effect_operation(state, request),
         result <- run(state, operation, cancelled?(invocation), :effect) do
      effect_result(result)
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  def effect(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation} <- Profile.effect_operation(state.namespace, request),
         result <- run(state, operation, cancelled?(invocation), :effect) do
      effect_result(result)
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, %{capability: @native_observation} = request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation} <- native_observation_operation(state, request),
         {:ok, response} <- run(state, operation, cancelled?(invocation), :read) do
      facts = %{"response" => response}

      {:ok,
       %Target.Verification{
         status: Profile.expected_status(facts, request.expected),
         observed_at: DateTime.utc_now(),
         facts: facts
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  def verify(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation, :deployment} <- Profile.observation_operation(state.namespace, request),
         {:ok, expected} <- Profile.verification_expected(request.expected),
         {:ok, result} <- run(state, operation, cancelled?(invocation), :read),
         {:ok, facts} <- Profile.decode(:deployment, result) do
      {:ok,
       %Target.Verification{
         status: Profile.expected_status(facts, expected),
         observed_at: DateTime.utc_now(),
         facts: facts
       }}
    else
      {:error, category, message} -> read_error(category, message)
      _error -> {:error, :failed, "Kubernetes verification request is invalid"}
    end
  end

  defp native_observation_operation(state, request) do
    with {:ok, action, api_version, kind, name, query, _body} <-
           native_request(request, "request.observe"),
         true <- action in ["get", "list"],
         {:ok, operation} <- native_read_operation(state, action, api_version, kind, name) do
      {:ok, add_query(operation, query)}
    else
      false -> invalid_request()
      {:error, _category, _message} = error -> error
    end
  rescue
    _error -> invalid_request()
  end

  defp native_effect_operation(state, request) do
    with {:ok, action, api_version, kind, name, _query, body} <-
           native_request(request, "request.execute") do
      path = [namespace: state.namespace, name: name]

      case action do
        "create" when is_map(body) ->
          {:ok, K8s.Client.create(body)}

        "update" when is_map(body) ->
          {:ok, K8s.Client.update(body)}

        "patch" when is_binary(name) and is_map(body) ->
          {:ok, K8s.Client.patch(api_version, kind, path, body, :merge)}

        "delete" when is_binary(name) ->
          {:ok, K8s.Client.delete(api_version, kind, path)}

        _invalid ->
          invalid_request()
      end
    end
  rescue
    _error -> invalid_request()
  end

  defp native_read_operation(state, "get", api_version, kind, name) when is_binary(name),
    do: {:ok, K8s.Client.get(api_version, kind, namespace: state.namespace, name: name)}

  defp native_read_operation(state, "list", api_version, kind, nil),
    do: {:ok, K8s.Client.list(api_version, kind, namespace: state.namespace)}

  defp native_read_operation(_state, _action, _api_version, _kind, _name), do: invalid_request()

  defp add_query(operation, query) when is_list(query) do
    Enum.reduce(query, operation, fn {key, value}, current ->
      K8s.Operation.put_query_param(current, key, value)
    end)
  end

  defp native_request(request, operation) do
    expected_capability =
      if(operation == "request.observe", do: @native_observation, else: @native_effect)

    case request do
      %{
        capability: ^expected_capability,
        operation: ^operation,
        selectors: selectors,
        parameters:
          %{
            "action" => action,
            "api_version" => api_version,
            "kind" => kind
          } = parameters
      }
      when selectors == %{} and is_binary(action) and is_binary(api_version) and is_binary(kind) ->
        name = Map.get(parameters, "name")
        query = Map.get(parameters, "query", %{})
        body = Map.get(parameters, "body")

        with true <- byte_size(api_version) in 1..120,
             true <- byte_size(kind) in 1..120,
             true <- is_nil(name) or (is_binary(name) and Profile.valid_name?(name)),
             {:ok, query} <- native_query(operation, query),
             true <- is_nil(body) or is_map(body) do
          {:ok, action, api_version, kind, name, query, body}
        else
          _invalid -> invalid_request()
        end

      _request ->
        invalid_request()
    end
  end

  defp native_operations do
    output = %{
      "type" => "object",
      "properties" => %{"response" => %{"type" => "object"}},
      "required" => ["response"],
      "additionalProperties" => false
    }

    observation = %Target.Operation{
      capability: @native_observation,
      operation: "request.observe",
      description: "Run one exact Kubernetes get or list request",
      input_schema: native_schema(["get", "list"], @native_observation_query_keys),
      output_schema: output,
      verification_schema: Map.put(output, "minProperties", 1),
      native?: true
    }

    effect = %Target.Operation{
      capability: @native_effect,
      operation: "request.execute",
      description:
        "Run one exact Kubernetes create, update, patch, or delete request after review",
      input_schema: native_schema(["create", "update", "patch", "delete"], %{}),
      native?: true
    }

    {observation, effect}
  end

  defp native_schema(actions, query_keys) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "action" => %{"type" => "string", "enum" => actions},
            "api_version" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
            "kind" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
            "name" => %{"type" => ["string", "null"], "maxLength" => 253},
            "query" => %{
              "type" => "object",
              "description" =>
                "Optional Kubernetes query parameters; namespace is fixed by the Access Method",
              "properties" =>
                Map.new(query_keys, fn {key, _atom} ->
                  {key, %{"type" => "string", "maxLength" => 2_048}}
                end),
              "additionalProperties" => false
            },
            "body" => %{"type" => ["object", "null"]}
          },
          "required" => ["action", "api_version", "kind"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp native_query("request.observe", query) when is_map(query) do
    Enum.reduce_while(query, {:ok, []}, fn {key, value}, {:ok, normalized} ->
      case {@native_observation_query_keys[key], value} do
        {atom, value}
        when not is_nil(atom) and is_atom(atom) and is_binary(value) and
               byte_size(value) <= 2_048 ->
          {:cont, {:ok, [{atom, value} | normalized]}}

        _unsupported ->
          {:halt, invalid_request()}
      end
    end)
  end

  defp native_query("request.execute", query) when query == %{}, do: {:ok, []}
  defp native_query(_operation, _query), do: invalid_request()

  defp run_observation(state, operation, {:watch, max_events}, cancelled?) do
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

  defp run_observation(state, operation, _decoder, cancelled?),
    do: run(state, operation, cancelled?, :read)

  defp run(state, %K8s.Operation{} = operation, cancelled?, phase),
    do: run(state, fn -> K8s.Client.run(state.connection, operation) end, cancelled?, phase)

  defp run(state, operation, cancelled?, phase) when is_function(operation, 0) do
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

  defp effect_result({:ok, result}) when is_map(result) do
    {:ok,
     %Target.EffectResult{
       status: :applied,
       reference: get_in(result, ["metadata", "resourceVersion"]),
       details: %{
         "uid" => get_in(result, ["metadata", "uid"]),
         "resource_version" => get_in(result, ["metadata", "resourceVersion"]),
         "generation" => get_in(result, ["metadata", "generation"])
       }
     }}
  end

  defp effect_result({:error, category, message})
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :unknown_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_result({:error, :cancelled, message}), do: {:error, :cancelled, message}

  defp effect_result({:error, category, message})
       when category in [:conflict, :forbidden, :not_found, :authentication, :api_rejected],
       do:
         {:ok,
          %Target.EffectResult{
            status: :failed,
            details: %{"error" => message, "category" => to_string(category)}
          }}

  defp effect_result({:error, _category, message}), do: {:error, :failed, message}

  defp endpoint(state, endpoint) when is_binary(endpoint) do
    if String.trim_trailing(endpoint, "/") == state.endpoint,
      do: :ok,
      else: {:error, :invalid_configuration, "Kubernetes endpoint does not match kubeconfig"}
  end

  defp endpoint(_state, _endpoint),
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
        if Profile.valid_name?(value), do: {:ok, value}, else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp after_dispatch(:effect, :cancelled), do: :cancelled_after_dispatch
  defp after_dispatch(:effect, :timeout), do: :timeout_after_dispatch
  defp after_dispatch(_phase, category), do: category
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(:timeout, message), do: {:error, :timeout, message}

  defp read_error(category, message) when category in [:unreachable, :not_found],
    do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp invalid_request, do: {:error, :failed, "Kubernetes API request is invalid"}
end
