defmodule Opsonde.Targets.Adapters.RESTCONF do
  @moduledoc false
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target
  alias Opsonde.Providers.Target
  alias Opsonde.Transports.RESTCONF, as: Transport
  @read "request.restconf.observe"
  @effect "request.restconf.effect"
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @media ~w(application/yang-data+json application/yang-data+xml application/yang-patch+json application/yang-patch+xml)
  @impl Opsonde.Providers.Adapter
  def type, do: "restconf"
  @impl Opsonde.Providers.Adapter
  def kind, do: :target
  @impl Opsonde.Providers.Adapter
  defdelegate build(configuration, credentials), to: Transport

  @impl Opsonde.Providers.Target
  def bind_connection(state, %Target.Connection{endpoint: endpoint}) do
    with {:ok, _endpoint} <- Transport.endpoint(endpoint), do: {:ok, state}
  end

  @impl Opsonde.Providers.Target
  def access_method_profile,
    do: %Target.AccessMethodProfile{method: "restconf", capabilities: [@read, @effect]}

  @impl Opsonde.Providers.Adapter
  def check(state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :capability, message} -> {:error, :capability, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "RESTCONF check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    output = %{
      "type" => "object",
      "properties" => %{
        "http_status" => %{"type" => "integer"},
        "content_type" => %{"type" => "string"},
        "body" => %{"type" => "string"}
      },
      "required" => ["http_status", "content_type", "body"],
      "additionalProperties" => false
    }

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @read,
           operation: "request.observe",
           description:
             "Read an exact RESTCONF resource under the discovered or configured service root; path is relative to that root",
           input_schema: schema(~w(GET HEAD)),
           output_schema: output,
           verification_schema: output
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "request.execute",
           description:
             "Send an exact RESTCONF resource request after authority review; path is relative to the service root",
           input_schema: schema(~w(POST PUT PATCH DELETE))
         }
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def classify_request(state, request) do
    with {:ok, operation} <- operation(state, request) do
      {:ok, if(operation.method in [:get, :head], do: :observation, else: :effect)}
    end
  end

  @impl Opsonde.Providers.Target
  def observe(state, request, invocation) do
    with {:ok, operation} <- operation(state, request),
         true <- operation.method in [:get, :head],
         {:ok, response} <-
           Transport.request(
             state,
             request.connection.endpoint,
             operation,
             cancelled(invocation),
             :read
           ),
         :ok <- accepted(response) do
      {:ok,
       %Target.Observation{
         facts: facts(response),
         observed_at: DateTime.utc_now(),
         evidence: [%{"source" => "restconf", "path" => operation.path}]
       }}
    else
      false -> {:error, :failed, "RESTCONF observation request is invalid"}
      {:error, _category, _message} = error -> read_error(error)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, operation} <- operation(state, request),
         true <- operation.method in [:post, :put, :patch, :delete] do
      case Transport.request(
             state,
             request.connection.endpoint,
             operation,
             cancelled(invocation),
             :effect
           ) do
        {:ok, response} ->
          status =
            cond do
              response.status == 202 -> :unknown
              response.status in 200..299 -> :applied
              response.status in 400..599 -> :failed
              true -> :unknown
            end

          {:ok,
           %Target.EffectResult{
             status: status,
             reference: request.operation,
             details: facts(response)
           }}

        {:error, :unknown_after_dispatch, message} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: request.operation,
             details: %{"reason" => message}
           }}

        {:error, :cancelled, _message} = error ->
          error

        {:error, _category, message} ->
          {:error, :failed, message}
      end
    else
      _ -> {:error, :failed, "RESTCONF effect request is invalid"}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(state, request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation) do
      status =
        cond do
          map_size(request.expected) == 0 ->
            :unknown

          Enum.all?(request.expected, fn {key, value} ->
            Map.fetch(observation.facts, key) == {:ok, value}
          end) ->
            :verified

          true ->
            :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         facts: observation.facts,
         observed_at: observation.observed_at,
         evidence: observation.evidence
       }}
    end
  end

  defp operation(state, request) do
    parameters = request.parameters
    read? = request.capability == @read and request.operation == "request.observe"
    write? = request.capability == @effect and request.operation == "request.execute"

    with true <- request.selectors == %{} and (read? or write?),
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method path query body accept content_type))
           ),
         {:ok, _endpoint} <- Transport.endpoint(request.connection.endpoint),
         {:ok, method} <- Map.fetch(@methods, parameters["method"]),
         true <-
           (read? and method in [:get, :head]) or
             (write? and method in [:post, :put, :patch, :delete]),
         true <- Transport.path?(parameters["path"]),
         body <- parameters["body"],
         true <-
           is_nil(body) or
             (is_binary(body) and String.valid?(body) and byte_size(body) <= state.max_body_bytes),
         true <- not read? or is_nil(body),
         query <- Map.get(parameters, "query", %{}),
         true <- is_map(query) and map_size(query) <= 100,
         true <-
           Enum.all?(query, fn {key, value} ->
             is_binary(key) and is_binary(value) and byte_size(key) <= 255 and
               byte_size(value) <= 2048
           end),
         accept <- Map.get(parameters, "accept", "application/yang-data+json"),
         content_type <- Map.get(parameters, "content_type", "application/yang-data+json"),
         true <- accept in @media and content_type in @media do
      {:ok,
       %{
         method: method,
         path: parameters["path"],
         body: body,
         query: query,
         accept: accept,
         content_type: content_type
       }}
    else
      _ -> {:error, :failed, "RESTCONF request is invalid"}
    end
  rescue
    _ -> {:error, :failed, "RESTCONF request is invalid"}
  end

  defp facts(response),
    do: %{
      "http_status" => response.status,
      "content_type" => response.headers |> Map.get("content-type", [""]) |> List.first(),
      "body" => response.body
    }

  defp accepted(%{status: status}) when status in 200..299, do: :ok

  defp accepted(%{status: status}),
    do: {:error, :failed, "RESTCONF request rejected (HTTP #{status})"}

  defp read_error({:error, category, message}) when category in [:timeout, :cancelled, :failed],
    do: {:error, category, message}

  defp read_error({:error, _category, message}), do: {:error, :retryable, message}
  defp cancelled(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled(_invocation), do: fn -> false end

  defp schema(methods) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "additionalProperties" => false},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "method" => %{"type" => "string", "enum" => methods},
            "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
            "body" => %{"type" => ["string", "null"], "maxLength" => 60_000},
            "query" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
            "accept" => %{"type" => "string", "enum" => @media},
            "content_type" => %{"type" => "string", "enum" => @media}
          },
          "required" => ["method", "path"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end
end
