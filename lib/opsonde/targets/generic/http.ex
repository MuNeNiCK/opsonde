defmodule Opsonde.Targets.Generic.HTTP do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.HTTPS

  @capability "observe.http"
  @operation "http.get"
  @max_preview_bytes 8_192
  @max_endpoint_bytes 1_024
  @default_timeout_ms 5_000

  defmodule State do
    @moduledoc false
    @enforce_keys [:endpoint, :timeout_ms, :headers, :connect_options]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "generic-http"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      platform: "generic",
      method: "http_get",
      configuration_endpoint?: true,
      capabilities: [@capability]
    }
  end

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials)
      when is_map(configuration) and is_map(credentials) do
    with true <-
           Enum.all?(Map.keys(configuration), &(&1 in ~w(endpoint timeout_ms ca_certificate))),
         {:ok, endpoint, uri} <- endpoint(configuration["endpoint"]),
         timeout when is_integer(timeout) and timeout in 100..30_000 <-
           Map.get(configuration, "timeout_ms", @default_timeout_ms),
         {:ok, auth_headers} <- auth_headers(credentials),
         {:ok, connect_options} <- connect_options(uri, configuration["ca_certificate"], timeout) do
      {:ok,
       %State{
         endpoint: endpoint,
         timeout_ms: timeout,
         headers: [{"accept", "*/*"}, {"accept-encoding", "identity"}] ++ auth_headers,
         connect_options: connect_options
       }}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{} = state, %{"endpoint" => endpoint}) when endpoint == state.endpoint do
    case get(state, %{}) do
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

  def check(_state, _input),
    do: {:error, :invalid_configuration, "HTTP check endpoint must match Provider configuration"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @capability,
           operation: @operation,
           description:
             "GET the operator-configured HTTP endpoint and inspect the actual status and response. " <>
               "The URL is fixed by this Access Method; no request URL or method is accepted from AI.",
           input_schema: input_schema(),
           output_schema: output_schema(),
           verification_schema: output_schema()
         }
       ],
       effects: []
     }}
  end

  @impl Opsonde.Providers.Target
  def preflight(_state, request), do: valid_request(request)

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with :ok <- valid_request(request),
         true <- request.connection.endpoint == state.endpoint,
         :ok <- not_cancelled(invocation),
         {:ok, %Req.Response{} = response} <- get(state, invocation),
         :ok <- not_cancelled(invocation) do
      {:ok, observation(state.endpoint, response)}
    else
      false -> {:error, :failed, "HTTP observation endpoint changed"}
      {:error, _category, _message} = error -> error
    end
  end

  @impl Opsonde.Providers.Target
  def effect(_state, _request, _invocation),
    do: {:error, :failed, "HTTP Access Method has no effect operations"}

  @impl Opsonde.Providers.Target
  def verify(_state, _request, _invocation),
    do: {:error, :failed, "HTTP Access Method has no effect verification"}

  defp valid_request(%{
         capability: @capability,
         operation: @operation,
         selectors: selectors,
         parameters: parameters
       })
       when selectors == %{} and parameters == %{},
       do: :ok

  defp valid_request(_request),
    do: {:error, :failed, "HTTP observation takes no URL or method input"}

  defp endpoint(value)
       when is_binary(value) and byte_size(value) in 10..@max_endpoint_bytes do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
         not String.match?(value, ~r/[\s\x00-\x1f]/) do
      {:ok, value, uri}
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

  defp get(state, invocation) do
    with :ok <- not_cancelled(invocation) do
      case Req.request(
             method: :get,
             url: state.endpoint,
             headers: state.headers,
             connect_options: state.connect_options,
             receive_timeout: state.timeout_ms,
             retry: false,
             redirect: false,
             decode_body: false,
             into: &collect/2
           ) do
        {:ok, %Req.Response{status: status} = response} when status in 100..599 ->
          {:ok, response}

        {:error, _error} ->
          {:error, :retryable, "HTTP endpoint request failed"}

        _other ->
          {:error, :failed, "HTTP endpoint returned an invalid response"}
      end
    end
  rescue
    _error -> {:error, :failed, "HTTP endpoint request failed"}
  end

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
      facts: %{
        "url" => endpoint,
        "status" => response.status,
        "content_type" => content_type,
        "body_encoding" => encoding,
        "body" => body,
        "body_truncated" => truncated?
      },
      observed_at: DateTime.utc_now()
    }
  end

  defp input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{"type" => "object", "maxProperties" => 0}
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "maxLength" => @max_endpoint_bytes},
        "status" => %{"type" => "integer", "minimum" => 100, "maximum" => 599},
        "content_type" => %{"type" => "string", "maxLength" => 256},
        "body_encoding" => %{"type" => "string", "enum" => ["utf-8", "base64"]},
        "body" => %{"type" => "string", "maxLength" => 11_000},
        "body_truncated" => %{"type" => "boolean"}
      },
      "required" => ["url", "status", "content_type", "body_encoding", "body", "body_truncated"],
      "additionalProperties" => false
    }
  end

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "HTTP observation was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok
end
