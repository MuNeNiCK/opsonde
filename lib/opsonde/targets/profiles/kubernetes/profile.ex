defmodule Opsonde.Targets.Profiles.Kubernetes do
  @moduledoc false
  alias Opsonde.Providers.Target

  @name_pattern ~r/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/

  def capabilities({native_observation, native_effect}) do
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
        ),
        native_observation
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
        },
        native_effect
      ]
    }
  end

  def observation_operation(namespace, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {"observe.workloads", "kubernetes.pods.list", selectors, parameters}
      when selectors == %{} ->
        with {:ok, limit, selector} <- list_parameters(parameters) do
          operation =
            K8s.Client.list("v1", "Pod", namespace: namespace)
            |> K8s.Operation.put_query_param(:limit, Integer.to_string(limit))
            |> put_selector(selector)

          {:ok, operation, :pods}
        end

      {"observe.workload", "kubernetes.deployment.inspect", %{"name" => name} = selectors,
       parameters}
      when map_size(selectors) == 1 and parameters == %{} ->
        if valid_name?(name),
          do:
            {:ok, K8s.Client.get("apps/v1", "Deployment", namespace: namespace, name: name),
             :deployment},
          else: invalid_request()

      {"observe.logs", "kubernetes.pod.logs",
       %{"name" => name, "container" => container} = selectors,
       %{"tail_lines" => lines, "limit_bytes" => bytes} = parameters}
      when map_size(selectors) == 2 and map_size(parameters) == 2 ->
        if valid_name?(name) and valid_name?(container) and is_integer(lines) and
             lines in 1..500 and is_integer(bytes) and bytes in 1..60_000 do
          operation =
            K8s.Client.get("v1", "pods/log", namespace: namespace, name: name)
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
          K8s.Client.list("v1", "Event", namespace: namespace)
          |> K8s.Operation.put_query_param(:limit, Integer.to_string(limit))

        {:ok, operation, :events}

      {"observe.workloads", "kubernetes.pods.watch", selectors, parameters}
      when selectors == %{} ->
        with {:ok, version, seconds, max_events, selector} <- watch_parameters(parameters) do
          operation =
            K8s.Client.watch("v1", "Pod", namespace: namespace)
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

  def expected_status(_facts, expected) when expected == %{}, do: :unknown

  def expected_status(facts, expected) when is_map(expected) do
    if Enum.all?(expected, fn {key, value} -> facts[key] == value end),
      do: :verified,
      else: :not_verified
  end

  def effect_operation(namespace, request) do
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
              "namespace" => namespace,
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

  def decode(:pods, %{"metadata" => metadata, "items" => items}) when is_list(items),
    do:
      {:ok,
       %{"resource_version" => metadata["resourceVersion"], "pods" => Enum.map(items, &pod/1)}}

  def decode(:deployment, %{"metadata" => metadata, "spec" => spec} = deployment) do
    status = Map.get(deployment, "status", %{})

    {:ok,
     %{
       "name" => metadata["name"],
       "namespace" => metadata["namespace"],
       "uid" => metadata["uid"],
       "resource_version" => metadata["resourceVersion"],
       "generation" => metadata["generation"],
       "replicas" => spec["replicas"],
       "ready_replicas" => Map.get(status, "readyReplicas", 0),
       "available_replicas" => Map.get(status, "availableReplicas", 0),
       "observed_generation" => status["observedGeneration"]
     }}
  end

  def decode({:logs, pod, container, limit}, logs)
      when is_binary(logs) and byte_size(logs) <= limit,
      do: {:ok, %{"pod" => pod, "container" => container, "logs" => logs}}

  def decode(:events, %{"metadata" => metadata, "items" => items}) when is_list(items),
    do:
      {:ok,
       %{"resource_version" => metadata["resourceVersion"], "events" => Enum.map(items, &event/1)}}

  def decode({:watch, _max}, items) when is_list(items) do
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

  def decode(_decoder, _result), do: {:error, :failed, "Kubernetes API response is invalid"}

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

  def verification_expected(expected) when is_map(expected) do
    case expected do
      %{"replicas" => replicas}
      when map_size(expected) == 1 and is_integer(replicas) and replicas in 0..100 ->
        {:ok, expected}

      _invalid ->
        {:error, :failed, "Kubernetes verification expectation is invalid"}
    end
  end

  def verification_expected(_expected),
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

  defp exact_keys?(map, allowed),
    do: Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed))

  def valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..253 and Regex.match?(@name_pattern, value)

  defp valid_identity?(value),
    do:
      is_binary(value) and byte_size(value) in 1..255 and
        not String.contains?(value, ["\n", "\r", <<0>>])

  defp valid_labels?(labels) when is_map(labels) and map_size(labels) <= 20 do
    Enum.all?(labels, fn {key, value} -> valid_identity?(key) and valid_identity?(value) end)
  end

  defp valid_labels?(_labels), do: false

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
        "namespace" => nullable("string"),
        "uid" => nullable("string"),
        "resource_version" => nullable("string"),
        "generation" => nullable("integer"),
        "replicas" => nullable("integer"),
        "ready_replicas" => %{"type" => "integer"},
        "available_replicas" => %{"type" => "integer"},
        "observed_generation" => nullable("integer")
      })

  defp deployment_verification_schema do
    %{
      "type" => "object",
      "properties" => %{"replicas" => integer(0, 100)},
      "required" => ["replicas"],
      "additionalProperties" => false
    }
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
