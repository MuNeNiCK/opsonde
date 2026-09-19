defmodule Opsonde.Targets.Kubernetes.API do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target

  @configuration_keys ~w(namespace request_timeout_ms)
  @credential_keys ~w(kubeconfig)
  @name_pattern ~r/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/

  defmodule State do
    @moduledoc false
    @enforce_keys [:connection, :namespace, :endpoint, :request_timeout]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "kubernetes-api"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

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
  def capabilities(_state, _invocation) do
    {:ok,
     %Target.Capabilities{
       observations: [
         operation(
           "observe.workloads",
           "kubernetes.pods.list",
           "List bounded Pods",
           pods_schema(),
           pods_output_schema()
         ),
         operation(
           "observe.workload",
           "kubernetes.deployment.inspect",
           "Inspect one Deployment",
           name_schema(),
           deployment_output_schema(),
           deployment_verification_schema()
         ),
         operation(
           "observe.logs",
           "kubernetes.pod.logs",
           "Read bounded logs from one Pod container",
           logs_schema(),
           logs_output_schema()
         ),
         operation(
           "observe.events",
           "kubernetes.events.list",
           "List bounded namespace events",
           events_schema(),
           events_output_schema()
         ),
         operation(
           "observe.workloads",
           "kubernetes.pods.watch",
           "Watch bounded Pod changes from a resource version",
           watch_schema(),
           watch_output_schema()
         )
       ],
       effects: [
         %{
           operation(
             "effect.workload",
             "kubernetes.deployment.scale",
             "Scale one Deployment with UID and resourceVersion preconditions",
             scale_schema()
           )
           | evidence_requirements: [
               %Target.EvidenceRequirement{
                 parameter: "expected_uid",
                 fact: "uid",
                 observation: "kubernetes.deployment.inspect"
               },
               %Target.EvidenceRequirement{
                 parameter: "expected_resource_version",
                 fact: "resource_version",
                 observation: "kubernetes.deployment.inspect"
               }
             ]
         }
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation, decoder} <- observation_operation(state, request),
         {:ok, result} <- run_observation(state, operation, decoder, cancelled?(invocation)),
         {:ok, facts} <- decode(decoder, result) do
      {:ok, %Target.Observation{facts: facts, observed_at: DateTime.utc_now()}}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation} <- effect_operation(state, request),
         result <- run(state, operation, cancelled?(invocation), :effect) do
      effect_result(result)
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with :ok <- endpoint(state, request.connection.endpoint),
         {:ok, operation, :deployment} <- observation_operation(state, request),
         {:ok, expected} <- verification_expected(request.expected),
         {:ok, result} <- run(state, operation, cancelled?(invocation), :read),
         {:ok, facts} <- decode(:deployment, result) do
      status =
        cond do
          map_size(expected) == 0 -> :unknown
          Enum.all?(expected, fn {key, value} -> facts[key] == value end) -> :verified
          true -> :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         observed_at: DateTime.utc_now(),
         facts: facts
       }}
    else
      {:error, category, message} -> read_error(category, message)
      _error -> {:error, :failed, "Kubernetes verification request is invalid"}
    end
  end

  defp observation_operation(state, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {"observe.workloads", "kubernetes.pods.list", selectors, parameters}
      when selectors == %{} ->
        with {:ok, limit, selector} <- list_parameters(parameters) do
          operation =
            K8s.Client.list("v1", "Pod", namespace: state.namespace)
            |> K8s.Operation.put_query_param(:limit, Integer.to_string(limit))
            |> put_selector(selector)

          {:ok, operation, :pods}
        end

      {"observe.workload", "kubernetes.deployment.inspect", %{"name" => name} = selectors,
       parameters}
      when map_size(selectors) == 1 and parameters == %{} ->
        if valid_name?(name),
          do:
            {:ok, K8s.Client.get("apps/v1", "Deployment", namespace: state.namespace, name: name),
             :deployment},
          else: invalid_request()

      {"observe.logs", "kubernetes.pod.logs",
       %{"name" => name, "container" => container} = selectors,
       %{"tail_lines" => lines, "limit_bytes" => bytes} = parameters}
      when map_size(selectors) == 2 and map_size(parameters) == 2 ->
        if valid_name?(name) and valid_name?(container) and is_integer(lines) and
             lines in 1..500 and is_integer(bytes) and bytes in 1..60_000 do
          operation =
            K8s.Client.get("v1", "pods/log", namespace: state.namespace, name: name)
            |> K8s.Operation.put_query_param(
              container: container,
              tailLines: Integer.to_string(lines),
              limitBytes: Integer.to_string(bytes)
            )

          {:ok, operation, {:logs, name, container, bytes}}
        else
          invalid_request()
        end

      {"observe.events", "kubernetes.events.list", selectors, %{"limit" => limit} = parameters}
      when selectors == %{} and map_size(parameters) == 1 and is_integer(limit) and
             limit in 1..200 ->
        operation =
          K8s.Client.list("v1", "Event", namespace: state.namespace)
          |> K8s.Operation.put_query_param(:limit, Integer.to_string(limit))

        {:ok, operation, :events}

      {"observe.workloads", "kubernetes.pods.watch", selectors, parameters}
      when selectors == %{} ->
        with {:ok, version, seconds, max_events, selector} <- watch_parameters(parameters) do
          operation =
            K8s.Client.watch("v1", "Pod", namespace: state.namespace)
            |> K8s.Operation.put_query_param(
              resourceVersion: version,
              timeoutSeconds: Integer.to_string(seconds)
            )
            |> put_selector(selector)

          {:ok, operation, {:watch, max_events}}
        end

      _request ->
        invalid_request()
    end
  end

  defp effect_operation(state, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {"effect.workload", "kubernetes.deployment.scale", %{"name" => name} = selectors,
       %{
         "replicas" => replicas,
         "expected_uid" => uid,
         "expected_resource_version" => version
       } = parameters}
      when map_size(selectors) == 1 and map_size(parameters) == 3 and is_integer(replicas) and
             replicas in 0..100 ->
        if valid_name?(name) and valid_identity?(uid) and valid_identity?(version) do
          resource = %{
            "apiVersion" => "apps/v1",
            "kind" => "Deployment",
            "metadata" => %{
              "name" => name,
              "namespace" => state.namespace,
              "uid" => uid,
              "resourceVersion" => version
            },
            "spec" => %{"replicas" => replicas}
          }

          {:ok, K8s.Client.patch(resource)}
        else
          invalid_request()
        end

      _request ->
        invalid_request()
    end
  end

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

  defp decode(:pods, %{"metadata" => metadata, "items" => items}) when is_list(items),
    do:
      {:ok,
       %{"resource_version" => metadata["resourceVersion"], "pods" => Enum.map(items, &pod/1)}}

  defp decode(:deployment, %{"metadata" => metadata, "spec" => spec} = deployment) do
    status = Map.get(deployment, "status", %{})

    {:ok,
     %{
       "name" => metadata["name"],
       "uid" => metadata["uid"],
       "resource_version" => metadata["resourceVersion"],
       "generation" => metadata["generation"],
       "replicas" => spec["replicas"],
       "ready_replicas" => Map.get(status, "readyReplicas", 0),
       "available_replicas" => Map.get(status, "availableReplicas", 0),
       "observed_generation" => status["observedGeneration"]
     }}
  end

  defp decode({:logs, pod, container, limit}, logs)
       when is_binary(logs) and byte_size(logs) <= limit,
       do: {:ok, %{"pod" => pod, "container" => container, "logs" => logs}}

  defp decode(:events, %{"metadata" => metadata, "items" => items}) when is_list(items),
    do:
      {:ok,
       %{"resource_version" => metadata["resourceVersion"], "events" => Enum.map(items, &event/1)}}

  defp decode({:watch, _max}, items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, events} ->
      case watch_event(item) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        :error -> {:halt, {:error, :failed, "Kubernetes watch response is invalid"}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, %{"events" => Enum.reverse(events)}}
      error -> error
    end
  end

  defp decode(_decoder, _result), do: {:error, :failed, "Kubernetes API response is invalid"}

  defp pod(resource) do
    metadata = resource["metadata"] || %{}
    status = resource["status"] || %{}

    %{
      "name" => metadata["name"],
      "uid" => metadata["uid"],
      "resource_version" => metadata["resourceVersion"],
      "phase" => status["phase"],
      "node" => status["nodeName"]
    }
  end

  defp event(resource) do
    regarding = resource["regarding"] || resource["involvedObject"] || %{}

    %{
      "type" => resource["type"],
      "reason" => resource["reason"],
      "note" => resource["note"] || resource["message"],
      "regarding_kind" => regarding["kind"],
      "regarding_name" => regarding["name"],
      "regarding_uid" => regarding["uid"]
    }
  end

  defp watch_event(%{"type" => type, "object" => %{} = object})
       when type in ["ADDED", "MODIFIED", "DELETED"],
       do: {:ok, %{"type" => type, "object" => pod(object)}}

  defp watch_event(_other), do: :error

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

  defp verification_expected(expected) when is_map(expected) do
    allowed =
      ~w(uid resource_version generation replicas ready_replicas available_replicas observed_generation)

    if Enum.all?(Map.keys(expected), &(&1 in allowed)),
      do: {:ok, expected},
      else: {:error, :failed, "Kubernetes verification expectation is invalid"}
  end

  defp verification_expected(_expected),
    do: {:error, :failed, "Kubernetes verification expectation is invalid"}

  defp list_parameters(%{"limit" => limit} = parameters)
       when is_integer(limit) and limit in 1..100 and map_size(parameters) in 1..2 do
    labels = Map.get(parameters, "labels", %{})

    if exact_keys?(parameters, ~w(limit labels)) and valid_labels?(labels),
      do: {:ok, limit, labels},
      else: invalid_request()
  end

  defp list_parameters(_parameters), do: invalid_request()

  defp watch_parameters(
         %{
           "resource_version" => version,
           "timeout_seconds" => seconds,
           "max_events" => max_events
         } = parameters
       )
       when is_integer(seconds) and seconds in 1..30 and is_integer(max_events) and
              max_events in 1..100 and map_size(parameters) in 3..4 do
    labels = Map.get(parameters, "labels", %{})

    if exact_keys?(parameters, ~w(resource_version timeout_seconds max_events labels)) and
         valid_identity?(version) and valid_labels?(labels),
       do: {:ok, version, seconds, max_events, labels},
       else: invalid_request()
  end

  defp watch_parameters(_parameters), do: invalid_request()

  defp put_selector(operation, labels) when map_size(labels) == 0, do: operation

  defp put_selector(operation, labels) do
    selector = K8s.Selector.parse(%{"matchLabels" => labels})
    K8s.Operation.put_selector(operation, selector)
  end

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
        if valid_name?(value), do: {:ok, value}, else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..253 and Regex.match?(@name_pattern, value)

  defp valid_identity?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and
        not String.contains?(value, ["\n", "\r", <<0>>])

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_labels?(labels) when is_map(labels) and map_size(labels) <= 20 do
    Enum.all?(labels, fn {key, value} -> valid_identity?(key) and valid_identity?(value) end)
  end

  defp valid_labels?(_labels), do: false

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

  defp operation(
         capability,
         operation,
         description,
         schema,
         output_schema \\ nil,
         verification_schema \\ nil
       ),
       do: %Target.Operation{
         capability: capability,
         operation: operation,
         description: description,
         input_schema: schema,
         output_schema: output_schema,
         verification_schema: verification_schema
       }

  defp pods_output_schema,
    do:
      facts_schema(%{
        "resource_version" => nullable("string"),
        "pods" => %{"type" => "array", "maxItems" => 100, "items" => pod_output_schema()}
      })

  defp deployment_output_schema,
    do:
      facts_schema(%{
        "name" => nullable("string"),
        "uid" => nullable("string"),
        "resource_version" => nullable("string"),
        "generation" => nullable("integer"),
        "replicas" => nullable("integer"),
        "ready_replicas" => %{"type" => "integer"},
        "available_replicas" => %{"type" => "integer"},
        "observed_generation" => nullable("integer")
      })

  defp deployment_verification_schema do
    deployment_output_schema()
    |> Map.put("properties", Map.drop(deployment_output_schema()["properties"], ["name"]))
    |> Map.put("minProperties", 1)
  end

  defp logs_output_schema,
    do:
      facts_schema(%{
        "pod" => %{"type" => "string"},
        "container" => %{"type" => "string"},
        "logs" => %{"type" => "string", "maxLength" => 60_000}
      })

  defp events_output_schema,
    do:
      facts_schema(%{
        "resource_version" => nullable("string"),
        "events" => %{
          "type" => "array",
          "maxItems" => 200,
          "items" =>
            facts_schema(%{
              "type" => nullable("string"),
              "reason" => nullable("string"),
              "note" => nullable("string"),
              "regarding_kind" => nullable("string"),
              "regarding_name" => nullable("string"),
              "regarding_uid" => nullable("string")
            })
        }
      })

  defp watch_output_schema,
    do:
      facts_schema(%{
        "events" => %{
          "type" => "array",
          "maxItems" => 100,
          "items" =>
            facts_schema(%{
              "type" => %{"type" => "string", "enum" => ~w(ADDED MODIFIED DELETED)},
              "object" => pod_output_schema()
            })
        }
      })

  defp pod_output_schema,
    do:
      facts_schema(%{
        "name" => nullable("string"),
        "uid" => nullable("string"),
        "resource_version" => nullable("string"),
        "phase" => nullable("string"),
        "node" => nullable("string")
      })

  defp facts_schema(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

  defp nullable(type), do: %{"type" => [type, "null"]}

  defp pods_schema,
    do: schema(%{}, [], %{"limit" => integer(1, 100), "labels" => labels()}, ["limit"])

  defp name_schema, do: schema(%{"name" => name()}, ["name"], %{}, [])

  defp logs_schema,
    do:
      schema(
        %{"name" => name(), "container" => name()},
        ["name", "container"],
        %{"tail_lines" => integer(1, 500), "limit_bytes" => integer(1, 60_000)},
        ["tail_lines", "limit_bytes"]
      )

  defp events_schema, do: schema(%{}, [], %{"limit" => integer(1, 200)}, ["limit"])

  defp watch_schema do
    schema(
      %{},
      [],
      %{
        "resource_version" => string(255),
        "timeout_seconds" => integer(1, 30),
        "max_events" => integer(1, 100),
        "labels" => labels()
      },
      ["resource_version", "timeout_seconds", "max_events"]
    )
  end

  defp scale_schema do
    schema(
      %{"name" => name()},
      ["name"],
      %{
        "replicas" => integer(0, 100),
        "expected_uid" => string(255),
        "expected_resource_version" => string(255)
      },
      ["replicas", "expected_uid", "expected_resource_version"]
    )
  end

  defp schema(selectors, selector_required, parameters, parameter_required) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => object(selectors, selector_required),
        "parameters" => object(parameters, parameter_required)
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp name,
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 253,
      "pattern" => "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"
    }

  defp string(maximum), do: %{"type" => "string", "minLength" => 1, "maxLength" => maximum}

  defp labels,
    do: %{"type" => "object", "maxProperties" => 20, "additionalProperties" => string(255)}

  defp integer(minimum, maximum),
    do: %{"type" => "integer", "minimum" => minimum, "maximum" => maximum}

  defp invalid_request, do: {:error, :failed, "Kubernetes API request is invalid"}
end
