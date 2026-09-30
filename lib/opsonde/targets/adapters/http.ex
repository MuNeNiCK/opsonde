defmodule Opsonde.Targets.Adapters.HTTP do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.HTTPS

  @observe "request.http.observe"
  @effect "request.http.effect"
  @read_methods %{"GET" => :get, "HEAD" => :head}
  @write_methods %{"POST" => :post, "PATCH" => :patch, "PUT" => :put, "DELETE" => :delete}
  @max_preview_bytes 8_192
  @max_body_bytes 65_536
  @max_path_bytes 2_048
  @max_endpoint_bytes 1_024
  @default_timeout_ms 5_000

  defmodule State do
    @moduledoc false
    @enforce_keys [:timeout_ms, :headers, :ca_certificate]
    defstruct @enforce_keys ++ [:endpoint, :connect_options]
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "http-api"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "http",
      capabilities: [@observe, @effect]
    }
  end

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials)
      when is_map(configuration) and is_map(credentials) do
    with true <-
           Enum.all?(Map.keys(configuration), &(&1 in ~w(timeout_ms ca_certificate))),
         timeout when is_integer(timeout) and timeout in 100..30_000 <-
           Map.get(configuration, "timeout_ms", @default_timeout_ms),
         {:ok, auth_headers} <- auth_headers(credentials),
         :ok <- HTTPS.validate_ca_certificate(configuration["ca_certificate"]) do
      {:ok,
       %State{
         timeout_ms: timeout,
         headers: [{"accept", "*/*"}, {"accept-encoding", "identity"}] ++ auth_headers,
         ca_certificate: configuration["ca_certificate"]
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with {:ok, state} <- bind_connection(state, %Target.Connection{endpoint: endpoint}) do
      check_connection(state)
    else
      _ -> {:error, :invalid_configuration, "HTTP Method endpoint is invalid"}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "HTTP check requires a Method endpoint"}

  @impl Opsonde.Providers.Target
  def bind_connection(%State{} = state, %Target.Connection{endpoint: value}) do
    with {:ok, endpoint, uri} <- endpoint(value),
         {:ok, options} <- connect_options(uri, state.ca_certificate, state.timeout_ms) do
      {:ok, %{state | endpoint: endpoint, connect_options: options}}
    else
      _ -> {:error, :failed, "HTTP Method endpoint or trust is invalid"}
    end
  end

  defp check_connection(state) do
    case request(state, :get, "/", %{}, nil, %{}) do
      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :authentication, "HTTP endpoint rejected the configured credentials"}

      {:ok, %Req.Response{status: status}} when status in 100..599 ->
        :ok

      {:error, _category, _message} ->
        {:error, :unreachable, "HTTP endpoint is unavailable"}

      _other ->
        {:error, :unreachable, "HTTP endpoint returned an invalid response"}
    end
  end

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @observe,
           operation: "request.observe",
           description: "Read one exact relative HTTP API path at the configured origin",
           input_schema: input_schema(Map.keys(@read_methods)),
           output_schema: output_schema(),
           verification_schema: output_schema()
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "request.execute",
           description: "Send one exact relative HTTP API write after authority review",
           input_schema: input_schema(Map.keys(@write_methods), true)
         }
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def classify_request(%State{} = state, request) do
    case method_request(state, request, :read) do
      {:ok, _method, _path, _headers, _body} ->
        {:ok, :observation}

      {:error, _category, _message} ->
        case method_request(state, request, :write) do
          {:ok, _method, _path, _headers, _body} -> {:ok, :effect}
          {:error, _category, _message} -> {:error, :failed, "HTTP request is invalid"}
        end
    end
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with {:ok, method, path, headers, body} <- method_request(state, request, :read),
         :ok <- not_cancelled(invocation),
         {:ok, %Req.Response{} = response} <-
           request(
             state,
             method,
             path,
             headers,
             body,
             invocation,
             request.parameters["response_file"]
           ),
         :ok <- not_cancelled(invocation) do
      {:ok, observation(state.endpoint <> path, response)}
    else
      {:error, _category, _message} = error -> error
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, target_request, invocation) do
    with {:ok, method, path, headers, body} <- method_request(state, target_request, :write),
         :ok <- not_cancelled(invocation) do
      case request(
             state,
             method,
             path,
             headers,
             body,
             invocation,
             target_request.parameters["response_file"]
           ) do
        {:ok, %Req.Response{status: status, body: response} = reply}
        when status in 200..299 ->
          details = %{"status" => status}

          details =
            if response in ["", nil],
              do: details,
              else: Map.put(details, "response_redacted", true)

          details = result_file(details, reply)

          {:ok,
           %Target.EffectResult{
             status: if(status == 202, do: :unknown, else: :applied),
             reference: target_request.operation,
             details: details
           }}

        {:ok, %Req.Response{status: status} = reply} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: target_request.operation,
             details: result_file(%{"status" => status}, reply)
           }}

        {:error, :retryable, message} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: target_request.operation,
             details: %{"reason" => message}
           }}

        {:error, :cancelled, _message} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: target_request.operation,
             details: %{"reason" => "HTTP effect outcome is unknown after cancellation"}
           }}

        {:error, :failed, _message} = error ->
          error
      end
    else
      {:error, :cancelled, _message} = error -> error
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, target_request, invocation) do
    with {:ok, method, path, headers, body} <- method_request(state, target_request, :read),
         :ok <- not_cancelled(invocation),
         {:ok, %Req.Response{} = response} <-
           request(
             state,
             method,
             path,
             headers,
             body,
             invocation,
             target_request.parameters["response_file"]
           ) do
      observation = observation(state.endpoint <> path, response)
      expected = target_request.expected

      status =
        case expected do
          %{"status" => value} when is_integer(value) and map_size(expected) == 1 ->
            if value == response.status, do: :verified, else: :not_verified

          %{} when map_size(expected) == 0 ->
            :unknown

          _ ->
            :unknown
        end

      {:ok,
       %Target.Verification{
         status: status,
         observed_at: DateTime.utc_now(),
         facts: observation.facts
       }}
    else
      {:error, _category, _message} = error -> error
    end
  end

  defp endpoint(value)
       when is_binary(value) and byte_size(value) in 10..@max_endpoint_bytes do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         uri.path in [nil, "", "/"] and is_nil(uri.userinfo) and is_nil(uri.query) and
         is_nil(uri.fragment) and
         not String.match?(value, ~r/[\s\x00-\x1f]/) do
      origin = URI.to_string(%{uri | path: nil})
      {:ok, origin, uri}
    else
      {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp auth_headers(credentials) when map_size(credentials) == 0, do: {:ok, []}

  defp auth_headers(%{"bearer_token" => token} = credentials)
       when map_size(credentials) == 1 and is_binary(token) and byte_size(token) in 1..4_096,
       do: {:ok, [{"authorization", "Bearer " <> token}]}

  defp auth_headers(_credentials), do: {:error, :invalid_credentials}

  defp connect_options(%URI{scheme: "http"}, nil, timeout), do: {:ok, [timeout: timeout]}

  defp connect_options(%URI{scheme: "https", host: host}, certificate, timeout) do
    with {:ok, tls} <- HTTPS.transport_options(certificate, host) do
      {:ok, [timeout: timeout, transport_opts: tls]}
    end
  end

  defp connect_options(_uri, _certificate, _timeout), do: {:error, :invalid_configuration}

  defp request(state, method, path, headers, body, invocation, output \\ nil) do
    options = [
      method: method,
      url: state.endpoint <> path,
      headers: merge_headers(state.headers, headers),
      connect_options: state.connect_options,
      receive_timeout: state.timeout_ms,
      retry: false,
      redirect: false,
      decode_body: false,
      raw: true,
      into: &collect/2
    ]

    Opsonde.Transports.HTTP.request(options, body, output, invocation)
  end

  defp result_file(details, response) do
    case response.private[:opsonde_file] do
      nil ->
        details

      reference ->
        details
        |> Map.put("file", reference)
        |> Map.put(
          "content_encoding",
          Enum.join(Req.Response.get_header(response, "content-encoding"), ",")
        )
    end
  end

  defp merge_headers(configured, requested) do
    configured
    |> Map.new()
    |> Map.merge(requested)
    |> Map.to_list()
  end

  defp method_request(state, request, kind) do
    methods = if kind == :read, do: @read_methods, else: @write_methods
    capability = if kind == :read, do: @observe, else: @effect
    operation = if kind == :read, do: "request.observe", else: "request.execute"
    parameters = request.parameters

    with true <- request.capability == capability and request.operation == operation,
         true <- same_endpoint?(state, request.connection),
         true <- request.selectors == %{},
         %{"method" => verb, "path" => path} <- parameters,
         true <- Enum.all?(Map.keys(parameters), &(&1 in allowed_keys(kind))),
         {:ok, method} <- Map.fetch(methods, verb),
         :ok <- relative_path(path),
         {:ok, headers} <- request_headers(Map.get(parameters, "headers", %{})),
         :ok <- response_file(parameters["response_file"]),
         {:ok, body} <- request_body(kind, method, parameters, request.files) do
      {:ok, method, path, headers, body}
    else
      _ -> {:error, :failed, "HTTP request is invalid"}
    end
  end

  defp same_endpoint?(state, %Target.Connection{endpoint: value}) do
    case endpoint(value) do
      {:ok, endpoint, _uri} -> endpoint == state.endpoint
      _ -> false
    end
  end

  defp same_endpoint?(_state, _connection), do: false

  defp allowed_keys(:read), do: ~w(method path headers response_file)
  defp allowed_keys(:write), do: ~w(method path headers body body_file response_file)

  defp response_file(nil), do: :ok

  defp response_file(%{"name" => name, "media_type" => media} = output) do
    if map_size(output) == 2 and is_binary(name) and String.valid?(name) and
         length(String.codepoints(name)) in 1..255 and is_binary(media) and String.valid?(media) and
         length(String.codepoints(media)) in 1..256 and not String.contains?(media, ["\r", "\n"]),
       do: :ok,
       else: {:error, :invalid_response_file}
  end

  defp response_file(_output), do: {:error, :invalid_response_file}

  defp relative_path(path) when is_binary(path) and byte_size(path) in 1..@max_path_bytes do
    uri = URI.parse(path)
    segments = String.split(uri.path || "", "/", trim: true)

    if is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.fragment) and is_binary(uri.path) and
         String.starts_with?(uri.path, "/") and not String.starts_with?(uri.path, "//") and
         not String.contains?(uri.path, ["\\", "//"]) and
         not Regex.match?(~r/%(?:25|2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f)/i, uri.path) and
         Enum.all?(segments, &(&1 not in [".", "..", ""])) and
         not String.match?(path, ~r/[\s\x00-\x1f]/) do
      :ok
    else
      {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  defp relative_path(_path), do: {:error, :invalid_path}

  defp request_headers(headers) when is_map(headers) and map_size(headers) <= 8 do
    normalized =
      Enum.map(headers, fn {name, value} -> {String.downcase(to_string(name)), value} end)

    if length(normalized) == map_size(headers) and
         length(Enum.uniq_by(normalized, &elem(&1, 0))) == length(normalized) and
         Enum.all?(normalized, fn {name, value} ->
           safe_header_name?(name) and is_binary(value) and byte_size(value) <= 1_024 and
             not String.match?(value, ~r/[\x00-\x1f\x7f]/)
         end) do
      {:ok, Map.new(normalized)}
    else
      {:error, :invalid_headers}
    end
  rescue
    _ -> {:error, :invalid_headers}
  end

  defp request_headers(_headers), do: {:error, :invalid_headers}

  defp safe_header_name?(name)
       when name in ["accept", "content-type", "if-match", "if-none-match"],
       do: true

  defp safe_header_name?("x-" <> name) do
    byte_size(name) in 1..64 and Regex.match?(~r/\A[a-z0-9-]+\z/, name) and
      not Enum.any?(~w(auth token secret key cookie credential), &String.contains?(name, &1))
  end

  defp safe_header_name?(_name), do: false

  defp request_body(:write, _method, %{"body_file" => label} = parameters, files) do
    with false <- Map.has_key?(parameters, "body"),
         true <- is_binary(label),
         {:ok, reference} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(reference) do
      {:ok, {:file, label, reference}}
    else
      _ -> {:error, :invalid_body_file}
    end
  end

  defp request_body(kind, method, parameters, _files),
    do: text_body(kind, method, Map.get(parameters, "body"))

  defp text_body(:read, _method, nil), do: {:ok, nil}
  defp text_body(:write, :delete, nil), do: {:ok, nil}

  defp text_body(:write, _method, body)
       when is_binary(body) and byte_size(body) <= @max_body_bytes,
       do: {:ok, body}

  defp text_body(_kind, _method, _body), do: {:error, :invalid_body}

  defp collect({:data, data}, {request, response}) do
    previous =
      case response.body do
        body when is_binary(body) -> body
        _other -> ""
      end

    combined = previous <> data

    if byte_size(combined) <= @max_preview_bytes do
      {:cont, {request, %{response | body: combined}}}
    else
      preview = binary_part(combined, 0, @max_preview_bytes)
      {:halt, {request, %{response | body: {:truncated, preview}}}}
    end
  end

  defp observation(endpoint, response) do
    {preview, truncated?} =
      case response.body do
        {:truncated, body} -> {body, true}
        body when is_binary(body) -> {body, false}
        _other -> {"", false}
      end

    {encoding, body} =
      if String.valid?(preview), do: {"utf-8", preview}, else: {"base64", Base.encode64(preview)}

    content_type =
      response
      |> Req.Response.get_header("content-type")
      |> List.first()
      |> then(&String.slice(&1 || "", 0, 256))

    %Target.Observation{
      facts:
        result_file(
          %{
            "url" => endpoint,
            "status" => response.status,
            "content_type" => content_type,
            "body_encoding" => encoding,
            "body" => body,
            "body_truncated" => truncated?
          },
          response
        ),
      observed_at: DateTime.utc_now()
    }
  end

  defp input_schema(methods, write? \\ false) do
    properties = %{
      "method" => %{"type" => "string", "enum" => methods},
      "path" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_path_bytes},
      "headers" => %{"type" => "object", "maxProperties" => 8},
      "response_file" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
          "media_type" => %{"type" => "string", "minLength" => 1, "maxLength" => 256}
        },
        "required" => ["name", "media_type"],
        "additionalProperties" => false
      }
    }

    properties =
      if write?,
        do:
          properties
          |> Map.put("body", %{"type" => "string", "maxLength" => @max_body_bytes})
          |> Map.put("body_file", %{"type" => "string", "minLength" => 1, "maxLength" => 120})
          |> Map.put("files", Target.FileReference.set_schema()),
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

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "maxLength" => @max_endpoint_bytes + @max_path_bytes},
        "status" => %{"type" => "integer", "minimum" => 100, "maximum" => 599},
        "content_type" => %{"type" => "string", "maxLength" => 256},
        "body_encoding" => %{"type" => "string", "enum" => ["utf-8", "base64"]},
        "body" => %{"type" => "string", "maxLength" => 11_000},
        "body_truncated" => %{"type" => "boolean"},
        "content_encoding" => %{"type" => "string"},
        "file" => Target.FileReference.schema()
      },
      "required" => ["url", "status", "content_type", "body_encoding", "body", "body_truncated"],
      "additionalProperties" => false
    }
  end

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "HTTP request was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok
end
