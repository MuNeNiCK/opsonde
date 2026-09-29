defmodule Opsonde.Targets.Adapters.Kubernetes do
  @moduledoc false
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target
  alias Opsonde.Providers.Target
  alias Opsonde.Transports.Kubernetes, as: Client
  alias Opsonde.Transports.Kubernetes.State

  @method_observation "request.kubernetes.observe"
  @method_effect "request.kubernetes.effect"
  @method_observation_query_keys %{
    "continue" => :continue,
    "fieldSelector" => :fieldSelector,
    "limit" => :limit,
    "pretty" => :pretty,
    "resourceVersion" => :resourceVersion,
    "resourceVersionMatch" => :resourceVersionMatch,
    "timeoutSeconds" => :timeoutSeconds
  }

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
  def build(configuration, credentials), do: Client.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(state, input), do: Client.check(state, input)

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    {observation, effect} = method_operations()
    {:ok, %Target.Capabilities{observations: [observation], effects: [effect]}}
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, %{capability: @method_observation} = request, invocation) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         {:ok, operation} <- method_observation_operation(state, request),
         {:ok, response} <- Client.run(state, operation, cancelled?(invocation), :read) do
      {:ok,
       %Target.Observation{
         facts: %{"response" => response},
         observed_at: DateTime.utc_now()
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  def observe(_state, _request, _invocation), do: invalid_request()

  @impl Opsonde.Providers.Target
  def classify_request(%State{} = state, request) do
    with :ok <- Client.endpoint(state, request.connection.endpoint) do
      case request.capability do
        @method_observation ->
          classify_kubernetes(method_observation_operation(state, request), :observation)

        @method_effect ->
          classify_kubernetes(method_effect_operation(state, request), :effect)

        _other ->
          invalid_request()
      end
    else
      _ -> {:error, :failed, "Kubernetes request is invalid"}
    end
  end

  defp classify_kubernetes({:ok, _operation}, kind), do: {:ok, kind}

  defp classify_kubernetes(_invalid, _kind),
    do: {:error, :failed, "Kubernetes request is invalid"}

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, %{capability: @method_effect} = request, invocation) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         {:ok, operation} <- method_effect_operation(state, request),
         result <- Client.run(state, operation, cancelled?(invocation), :effect) do
      effect_result(result)
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  def effect(_state, _request, _invocation), do: invalid_request()

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, %{capability: @method_observation} = request, invocation) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         {:ok, operation} <- method_observation_operation(state, request),
         {:ok, response} <- Client.run(state, operation, cancelled?(invocation), :read) do
      facts = %{"response" => response}

      {:ok,
       %Target.Verification{
         status: expected_status(facts, request.expected),
         observed_at: DateTime.utc_now(),
         facts: facts
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  def verify(_state, _request, _invocation), do: invalid_request()

  defp expected_status(_facts, expected) when expected == %{}, do: :unknown

  defp expected_status(facts, expected) when is_map(expected) do
    if Enum.all?(expected, fn {key, value} -> facts[key] == value end),
      do: :verified,
      else: :not_verified
  end

  defp method_observation_operation(state, request) do
    with {:ok, action, api_version, kind, name, query, body} <-
           method_request(request, "request.observe"),
         true <- is_nil(body),
         true <- action in ["get", "list"],
         {:ok, operation} <- method_read_operation(state, action, api_version, kind, name) do
      {:ok, add_query(operation, query)}
    else
      false -> invalid_request()
      {:error, _category, _message} = error -> error
    end
  rescue
    _error -> invalid_request()
  end

  defp method_effect_operation(state, request) do
    with {:ok, action, api_version, kind, name, _query, body} <-
           method_request(request, "request.execute"),
         :ok <- validate_effect_body(state, action, api_version, kind, name, body) do
      path = [namespace: state.namespace, name: name]

      case action do
        "create" when is_map(body) ->
          {:ok, K8s.Client.create(api_version, kind, [namespace: state.namespace], body)}

        "update" when is_binary(name) and is_map(body) ->
          {:ok, K8s.Client.update(api_version, kind, path, body)}

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

  defp validate_effect_body(_state, "delete", _version, _kind, _name, nil), do: :ok

  defp validate_effect_body(state, action, version, kind, name, body)
       when action in ["create", "update", "patch"] and is_map(body) do
    metadata = Map.get(body, "metadata", %{})

    if is_map(metadata) and
         Map.get(metadata, "namespace", state.namespace) == state.namespace and
         (is_nil(name) or Map.get(metadata, "name", name) == name) and
         Map.get(body, "apiVersion", version) == version and
         Map.get(body, "kind", kind) == kind do
      :ok
    else
      invalid_request()
    end
  end

  defp validate_effect_body(_state, _action, _version, _kind, _name, _body),
    do: invalid_request()

  defp method_read_operation(state, "get", api_version, kind, name) when is_binary(name),
    do: {:ok, K8s.Client.get(api_version, kind, namespace: state.namespace, name: name)}

  defp method_read_operation(state, "list", api_version, kind, nil),
    do: {:ok, K8s.Client.list(api_version, kind, namespace: state.namespace)}

  defp method_read_operation(_state, _action, _api_version, _kind, _name), do: invalid_request()

  defp add_query(operation, query) when is_list(query) do
    Enum.reduce(query, operation, fn {key, value}, current ->
      K8s.Operation.put_query_param(current, key, value)
    end)
  end

  defp method_request(request, operation) do
    expected_capability =
      if(operation == "request.observe", do: @method_observation, else: @method_effect)

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

        with true <-
               Enum.all?(
                 Map.keys(parameters),
                 &(&1 in ~w(action api_version kind name query body))
               ),
             true <- byte_size(api_version) in 1..120,
             true <- byte_size(kind) in 1..120,
             true <- is_nil(name) or (is_binary(name) and Client.valid_name?(name)),
             {:ok, query} <- method_query(operation, query),
             true <- is_nil(body) or is_map(body) do
          {:ok, action, api_version, kind, name, query, body}
        else
          _invalid -> invalid_request()
        end

      _request ->
        invalid_request()
    end
  end

  defp method_operations do
    output = %{
      "type" => "object",
      "properties" => %{"response" => %{"type" => "object"}},
      "required" => ["response"],
      "additionalProperties" => false
    }

    observation = %Target.Operation{
      capability: @method_observation,
      operation: "request.observe",
      description: "Run one exact Kubernetes get or list request",
      input_schema: method_schema(["get", "list"], @method_observation_query_keys),
      output_schema: output,
      verification_schema: Map.put(output, "minProperties", 1)
    }

    effect = %Target.Operation{
      capability: @method_effect,
      operation: "request.execute",
      description:
        "Run one exact Kubernetes create, update, patch, or delete request after review",
      input_schema: method_schema(["create", "update", "patch", "delete"], %{})
    }

    {observation, effect}
  end

  defp method_schema(actions, query_keys) do
    parameter_properties = %{
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
      }
    }

    parameter_properties =
      if Enum.any?(actions, &(&1 in ["create", "update", "patch"])),
        do: Map.put(parameter_properties, "body", %{"type" => ["object", "null"]}),
        else: parameter_properties

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => parameter_properties,
          "required" => ["action", "api_version", "kind"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp method_query("request.observe", query) when is_map(query) do
    Enum.reduce_while(query, {:ok, []}, fn {key, value}, {:ok, normalized} ->
      case {@method_observation_query_keys[key], value} do
        {atom, value}
        when not is_nil(atom) and is_atom(atom) and is_binary(value) and
               byte_size(value) <= 2_048 ->
          {:cont, {:ok, [{atom, value} | normalized]}}

        _unsupported ->
          {:halt, invalid_request()}
      end
    end)
  end

  defp method_query("request.execute", query) when query == %{}, do: {:ok, []}
  defp method_query(_operation, _query), do: invalid_request()

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

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(:timeout, message), do: {:error, :timeout, message}

  defp read_error(category, message) when category in [:unreachable, :not_found],
    do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp invalid_request, do: {:error, :failed, "Kubernetes API request is invalid"}
end
