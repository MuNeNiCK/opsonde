defmodule Opsonde.Targets.Adapters.Kubernetes do
  @moduledoc false
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.Kubernetes, as: Client
  alias Opsonde.Transports.Kubernetes.State

  @observe "request.kubernetes.observe"
  @effect "request.kubernetes.effect"
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @max_body_bytes 65_536

  def type, do: "kubernetes-api"
  def kind, do: :target
  def build(configuration, credentials), do: Client.build(configuration, credentials)
  def check(state, input), do: Client.check(state, input)

  def access_method_profile do
    %Target.AccessMethodProfile{method: "api", capabilities: [@observe, @effect]}
  end

  def capabilities(state, _invocation) do
    scope = if state, do: " Namespace: #{state.namespace}.", else: ""

    output = %{
      "type" => "object",
      "properties" => %{
        "response" => %{},
        "http_status" => %{"type" => "integer"},
        "content_type" => %{"type" => "string"}
      },
      "required" => ["response", "http_status", "content_type"],
      "additionalProperties" => false
    }

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @observe,
           operation: "request.observe",
           description:
             "Read an exact Kubernetes API path, including discovery and subresources." <> scope,
           input_schema: schema(["GET", "HEAD"]),
           output_schema: output,
           verification_schema: %{output | "required" => []}
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "request.execute",
           description:
             "Send an exact Kubernetes API HTTP request after review. JSON, YAML, patch and DELETE bodies are literal UTF-8 strings." <>
               scope,
           input_schema: schema(["POST", "PUT", "PATCH", "DELETE"])
         }
       ]
     }}
  end

  def classify_request(%State{} = state, request) do
    with {:ok, operation} <- exact_request(state, request), do: {:ok, operation.kind}
  end

  def classify_request(_state, _request), do: invalid()

  def observe(%State{} = state, request, invocation) do
    with {:ok, %{kind: :observation} = operation} <- exact_request(state, request),
         {:ok, response} <- Client.run(state, operation, cancelled?(invocation), :read),
         :ok <- read_status(response) do
      {:ok, %Target.Observation{facts: facts(response), observed_at: DateTime.utc_now()}}
    else
      {:ok, _effect} -> invalid()
      error -> error
    end
  end

  def observe(_state, _request, _invocation), do: invalid()

  def effect(%State{} = state, request, invocation) do
    with {:ok, %{kind: :effect} = operation} <- exact_request(state, request) do
      case Client.run(state, operation, cancelled?(invocation), :effect) do
        {:ok, response} ->
          body = response.body
          reference = if is_map(body), do: get_in(body, ["metadata", "resourceVersion"])

          {:ok,
           %Target.EffectResult{
             status: if(response.status in 200..299, do: :applied, else: :failed),
             reference: reference,
             details:
               Map.put(facts(response), "category", to_string(status_category(response.status)))
           }}

        {:error, category, message}
        when category in [
               :unknown_after_dispatch,
               :cancelled_after_dispatch,
               :timeout_after_dispatch
             ] ->
          {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

        error ->
          error
      end
    else
      {:ok, _observation} -> invalid()
      error -> error
    end
  end

  def effect(_state, _request, _invocation), do: invalid()

  def verify(%State{} = state, request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation) do
      status =
        cond do
          request.expected == %{} ->
            :unknown

          Enum.all?(request.expected, fn {key, value} -> observation.facts[key] == value end) ->
            :verified

          true ->
            :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         facts: observation.facts,
         observed_at: observation.observed_at
       }}
    end
  end

  def verify(_state, _request, _invocation), do: invalid()

  defp exact_request(state, request) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         true <- request.selectors == %{},
         %{"method" => verb, "path" => path} = parameters <- request.parameters,
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method path query body content_type accept))
           ),
         {:ok, method} <- Map.fetch(@methods, verb),
         {:ok, kind} <- request_kind(request, method),
         :ok <- path_scope(path, state.namespace, kind),
         {:ok, query} <- query(Map.get(parameters, "query", %{})),
         {:ok, content_type} <-
           media_type(Map.get(parameters, "content_type", "application/json")),
         {:ok, accept} <- media_type(Map.get(parameters, "accept", "application/json")),
         {:ok, body} <- body(kind, Map.get(parameters, "body"), content_type) do
      {:ok,
       %{
         kind: kind,
         method: method,
         path: path,
         query: query,
         body: body,
         headers: [{"content-type", content_type}, {"accept", accept}]
       }}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp request_kind(%{capability: @observe, operation: "request.observe"}, method)
       when method in [:get, :head], do: {:ok, :observation}

  defp request_kind(%{capability: @effect, operation: "request.execute"}, method)
       when method in [:post, :put, :patch, :delete], do: {:ok, :effect}

  defp request_kind(_request, _method), do: invalid()

  defp path_scope(path, namespace, kind) when is_binary(path) and byte_size(path) in 1..2_048 do
    uri = URI.parse(path)
    parts = String.split(path, "/", trim: true)

    canonical? =
      String.starts_with?(path, "/") and not String.contains?(path, ["//", "\\"]) and
        not Regex.match?(~r/[\s\x00-\x1f\x7f]|%(?:25|2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f)/i, path) and
        Enum.all?(parts, &(&1 not in [".", ".."])) and
        Enum.all?([uri.scheme, uri.host, uri.userinfo, uri.fragment, uri.query], &is_nil/1)

    supported? =
      case parts do
        ["api", _version, "namespaces", ^namespace | rest] -> resource_path?(rest)
        ["apis", _group, _version, "namespaces", ^namespace | rest] -> resource_path?(rest)
        ["api"] -> kind == :observation
        ["api", _version] -> kind == :observation
        ["apis"] -> kind == :observation
        ["apis", _group] -> kind == :observation
        ["apis", _group, _version] -> kind == :observation
        ["version"] -> kind == :observation
        ["openapi" | _rest] -> kind == :observation
        _ -> false
      end

    if canonical? and supported?, do: :ok, else: invalid()
  end

  defp path_scope(_path, _namespace, _kind), do: invalid()

  # These Kubernetes protocol subresources require a maintained connection;
  # they cannot be admitted as an ordinary bounded HTTP observation.
  defp resource_path?([_resource, _name, subresource | _rest])
       when subresource in ["exec", "attach", "portforward", "proxy"], do: false

  defp resource_path?(parts), do: parts != []

  defp query(query) when is_map(query) and map_size(query) <= 32 do
    if Enum.all?(query, fn {key, value} ->
         is_binary(key) and byte_size(key) in 1..120 and is_binary(value) and
           byte_size(value) <= 2_048 and String.valid?(value) and
           not Regex.match?(~r/[\x00-\x1f\x7f]/, key <> value)
       end) and String.downcase(Map.get(query, "watch", "false")) not in ["true", "t", "1"] do
      {:ok, Map.to_list(query)}
    else
      invalid()
    end
  end

  defp query(_query), do: invalid()

  defp media_type(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.contains?(value, "/") and Regex.match?(~r/\A[\x20-\x7e]+\z/, value),
      do: {:ok, value},
      else: invalid()
  end

  defp media_type(_value), do: invalid()

  defp body(_kind, nil, _type), do: {:ok, nil}

  defp body(:effect, body, type) when is_binary(body) and byte_size(body) <= @max_body_bytes do
    json? =
      type
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()
      |> String.ends_with?(["/json", "+json"])

    if String.valid?(body) and (not json? or match?({:ok, _}, Jason.decode(body))),
      do: {:ok, body},
      else: invalid()
  end

  defp body(_kind, _body, _type), do: invalid()

  defp schema(methods) do
    properties = %{
      "method" => %{"type" => "string", "enum" => methods},
      "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
      "query" => %{
        "type" => "object",
        "maxProperties" => 32,
        "additionalProperties" => %{"type" => "string", "maxLength" => 2_048}
      },
      "content_type" => %{"type" => "string", "maxLength" => 256},
      "accept" => %{"type" => "string", "maxLength" => 256}
    }

    properties =
      if "PATCH" in methods,
        do:
          Map.put(properties, "body", %{
            "type" => ["string", "null"],
            "maxLength" => @max_body_bytes
          }),
        else: properties

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => ["method", "path"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp facts(response),
    do: %{
      "response" => response.body,
      "http_status" => response.status,
      "content_type" => response.content_type
    }

  defp read_status(%{status: status}) when status in 200..299, do: :ok

  defp read_status(%{status: status}),
    do:
      {:error, read_category(status_category(status)),
       "Kubernetes API rejected request (HTTP #{status})"}

  defp read_category(:not_found), do: :retryable
  defp read_category(_category), do: :failed
  defp status_category(409), do: :conflict
  defp status_category(401), do: :authentication
  defp status_category(403), do: :forbidden
  defp status_category(404), do: :not_found
  defp status_category(status) when status in 200..299, do: :applied
  defp status_category(_status), do: :api_rejected
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
  defp invalid, do: {:error, :failed, "Kubernetes API request is invalid"}
end
