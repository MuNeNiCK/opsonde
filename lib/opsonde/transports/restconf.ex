defmodule Opsonde.Transports.RESTCONF do
  @moduledoc false
  alias Opsonde.Transports.HTTPS

  @configuration_keys ~w(ca_certificate api_root connect_timeout_ms request_timeout_ms max_body_bytes)
  @xrd_namespace "http://docs.oasis-open.org/ns/xri/xrd-1.0"

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :auth,
      :client_tls,
      :ca_certificate,
      :api_root,
      :connect_timeout,
      :request_timeout,
      :max_body_bytes
    ]
    @derive {Inspect, except: [:auth, :client_tls]}
    defstruct @enforce_keys
  end

  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with true <- Enum.all?(Map.keys(configuration), &(&1 in @configuration_keys)),
         true <-
           Enum.all?(
             Map.keys(credentials),
             &(&1 in ~w(username password bearer_token client_certificate client_private_key))
           ),
         {:ok, client_tls} <- client_tls(credentials),
         http_credentials <- Map.take(credentials, ~w(username password bearer_token)),
         {:ok, auth} <-
           if(http_credentials == %{} and client_tls != [],
             do: {:ok, nil},
             else: auth(http_credentials)
           ),
         :ok <- HTTPS.validate_ca_certificate(configuration["ca_certificate"]),
         root <- configuration["api_root"],
         true <- is_nil(root) or (path?(root) and root != "/"),
         {:ok, connect_timeout} <- timeout(configuration, "connect_timeout_ms", 10_000),
         {:ok, request_timeout} <- timeout(configuration, "request_timeout_ms", 30_000),
         limit when is_integer(limit) and limit in 1..60_000 <-
           Map.get(configuration, "max_body_bytes", 60_000) do
      {:ok,
       %State{
         auth: auth,
         client_tls: client_tls,
         ca_certificate: configuration["ca_certificate"],
         api_root: root,
         connect_timeout: connect_timeout,
         request_timeout: request_timeout,
         max_body_bytes: limit
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  defp auth(%{"username" => username, "password" => password} = credentials)
       when map_size(credentials) == 2 and is_binary(username) and byte_size(username) in 1..255 and
              is_binary(password) and byte_size(password) in 1..4096 do
    if String.contains?(username, ":"),
      do: {:error, :invalid_credentials},
      else: {:ok, "Basic " <> Base.encode64(username <> ":" <> password)}
  end

  defp auth(%{"bearer_token" => token} = credentials)
       when map_size(credentials) == 1 and is_binary(token) and byte_size(token) in 1..4096 do
    if Regex.match?(~r/^[A-Za-z0-9._~+\/-]+=*$/, token),
      do: {:ok, "Bearer " <> token},
      else: {:error, :invalid_credentials}
  end

  defp auth(_credentials), do: {:error, :invalid_credentials}

  defp client_tls(credentials) do
    case {credentials["client_certificate"], credentials["client_private_key"]} do
      {nil, nil} ->
        {:ok, []}

      {certificate, private_key}
      when is_binary(certificate) and is_binary(private_key) and
             byte_size(certificate) in 1..65_536 and byte_size(private_key) in 1..65_536 ->
        entries = :public_key.pem_decode(certificate)
        certificates = for {:Certificate, der, :not_encrypted} <- entries, do: der

        with true <- certificates != [] and length(certificates) == length(entries),
             [{type, der, :not_encrypted}] <- :public_key.pem_decode(private_key),
             true <- type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] do
          {:ok, [certs_keys: [%{cert: certificates, key: {type, der}}]]}
        else
          _ -> {:error, :invalid_client_certificate}
        end

      _ ->
        {:error, :invalid_client_certificate}
    end
  rescue
    _ -> {:error, :invalid_client_certificate}
  end

  def endpoint(value) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, path: path, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and path in [nil, ""] and uri.port in 1..65_535 ->
        {:ok, URI.to_string(%{uri | path: nil})}

      _ ->
        {:error, :failed, "RESTCONF endpoint is invalid"}
    end
  end

  def endpoint(_value), do: {:error, :failed, "RESTCONF endpoint is invalid"}

  def path?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    uri = URI.parse(value)
    decoded = URI.decode(value)

    String.valid?(value) and String.starts_with?(value, "/") and
      not String.starts_with?(value, "//") and
      is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.query) and is_nil(uri.fragment) and
      not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value) and
      not Regex.match?(~r/[\x00-\x20\x7f\\]/, decoded) and
      not Regex.match?(~r/%[0-9a-fA-F]{2}/, decoded) and
      not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."]))
  rescue
    _ -> false
  end

  def path?(_value), do: false

  def check(state, endpoint) do
    case request(
           state,
           endpoint,
           %{
             method: :get,
             path: "/",
             query: %{},
             body: nil,
             accept: "application/yang-data+json",
             content_type: "application/yang-data+json"
           },
           fn -> false end,
           :read
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 401}} -> {:error, :authentication, "RESTCONF authentication failed"}
      {:ok, %{status: _status}} -> {:error, :capability, "RESTCONF root request was rejected"}
      {:error, _category, _message} = error -> error
    end
  end

  def request(state, value, operation, cancelled?, phase) do
    deadline = System.monotonic_time(:millisecond) + state.request_timeout

    with {:ok, endpoint} <- endpoint(value),
         true <- path?(operation.path),
         {:ok, root} <- root(state, endpoint, cancelled?, deadline) do
      path = if operation.path == "/", do: root, else: root <> operation.path
      run_http(state, endpoint, path, operation, cancelled?, phase, deadline)
    else
      false -> {:error, :failed, "RESTCONF resource path is invalid"}
      {:error, _category, _message} = error -> error
    end
  end

  defp root(%State{api_root: root}, _endpoint, _cancelled?, _deadline) when is_binary(root),
    do: {:ok, root}

  defp root(state, endpoint, cancelled?, deadline) do
    operation = %{
      method: :get,
      query: %{},
      body: nil,
      accept: "application/xrd+xml",
      content_type: "application/xrd+xml"
    }

    with {:ok, %{status: 200, body: body}} <-
           run_http(
             state,
             endpoint,
             "/.well-known/host-meta",
             operation,
             cancelled?,
             :read,
             deadline
           ),
         {:ok, {name, attributes, children}} <- Saxy.SimpleForm.parse_string(body),
         namespaces <- Map.new(attributes),
         true <- element?(name, namespaces, "XRD"),
         [href] <-
           for(
             {tag, attrs, _content} <- children,
             attrs = Map.new(attrs),
             element?(tag, Map.merge(namespaces, attrs), "Link"),
             attrs["rel"] == "restconf",
             do: attrs["href"]
           ),
         true <- is_binary(href),
         %URI{} = uri <- URI.merge(endpoint, href),
         true <- origin(uri) == origin(URI.parse(endpoint)),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- path?(uri.path) and uri.path != "/" do
      {:ok, String.trim_trailing(uri.path, "/")}
    else
      {:ok, %{status: 401}} -> {:error, :authentication, "RESTCONF authentication failed"}
      {:error, category, message} when is_atom(category) -> {:error, category, message}
      _ -> {:error, :failed, "RESTCONF root discovery is invalid"}
    end
  rescue
    _ -> {:error, :failed, "RESTCONF root discovery is invalid"}
  end

  defp element?(name, attributes, expected) do
    case String.split(name, ":", parts: 2) do
      [^expected] -> attributes["xmlns"] == @xrd_namespace
      [prefix, ^expected] -> attributes["xmlns:" <> prefix] == @xrd_namespace
      _ -> false
    end
  end

  defp origin(uri), do: {uri.scheme, uri.host, uri.port}

  defp run_http(state, endpoint, path, operation, cancelled?, phase, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      cancelled?.() ->
        {:error, :cancelled, "RESTCONF request was cancelled before dispatch"}

      remaining <= 0 ->
        {:error, :timeout, "RESTCONF request timed out before dispatch"}

      true ->
        state
        |> http(endpoint, path, operation, cancelled?, remaining)
        |> normalize(phase)
    end
  end

  defp http(state, endpoint, path, operation, cancelled?, remaining) do
    {:ok, tls} = HTTPS.transport_options(state.ca_certificate, URI.parse(endpoint).host)

    options = [
      method: operation.method,
      url: endpoint <> path,
      params: operation.query,
      headers:
        if(state.auth, do: [{"authorization", state.auth}], else: []) ++
          [
            {"accept", operation.accept},
            {"content-type", operation.content_type},
            {"accept-encoding", "identity"}
          ],
      connect_options: [
        timeout: min(state.connect_timeout, remaining),
        transport_opts: Keyword.merge(tls, state.client_tls)
      ],
      receive_timeout: remaining,
      retry: false,
      redirect: false,
      raw: true,
      into: fn {:data, data}, {request, response} ->
        body = if is_binary(response.body), do: response.body, else: ""

        if byte_size(body) + byte_size(data) <= state.max_body_bytes,
          do: {:cont, {request, %{response | body: body <> data}}},
          else: {:halt, {request, %{response | body: :too_large}}}
      end
    ]

    Opsonde.Transports.HTTP.request(options, operation.body, nil, %{cancelled?: cancelled?})
  end

  defp normalize({:ok, %Req.Response{status: status, headers: headers, body: body}}, phase)
       when is_binary(body) do
    if String.valid?(body),
      do: {:ok, %{status: status, headers: headers, body: body}},
      else: {:error, failure(phase, :failed), "RESTCONF response is not UTF-8"}
  end

  defp normalize({:ok, %Req.Response{}}, phase),
    do: {:error, failure(phase, :failed), "RESTCONF response exceeded its limit"}

  defp normalize({:error, :retryable, message}, phase),
    do: {:error, failure(phase, :unreachable), message}

  defp normalize({:error, category, message}, phase),
    do: {:error, failure(phase, category), message}

  defp failure(:effect, _category), do: :unknown_after_dispatch
  defp failure(_phase, category), do: category

  defp timeout(configuration, key, default) do
    case Map.get(configuration, key, default) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end
end
