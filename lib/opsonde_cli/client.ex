defmodule OpsondeCLI.Client do
  @moduledoc false

  defstruct [:server, :token, request_options: []]

  def new(server, token, request_options \\ []) do
    with {:ok, normalized} <- normalize_server(server) do
      {:ok, %__MODULE__{server: normalized, token: token, request_options: request_options}}
    end
  end

  def request(%__MODULE__{} = client, method, path, body \\ nil, query \\ []) do
    options = [
      method: method,
      url: client.server <> "/api/v1" <> path,
      headers: headers(client.token),
      params: query,
      receive_timeout: 30_000,
      retry: false
    ]

    options = if is_nil(body), do: options, else: Keyword.put(options, :json, body)

    case Req.request(Keyword.merge(options, client.request_options)) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, status, normalize_body(response)}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, :http, status, normalize_body(response)}

      {:error, error} ->
        {:error, :transport, Exception.message(error)}
    end
  end

  defp normalize_server(server) when is_binary(server) do
    uri = URI.parse(server)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil and
         uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, String.trim_trailing(server, "/")}
    else
      {:error, "Server must be an HTTP or HTTPS origin without a path, query, or credentials"}
    end
  end

  defp normalize_server(_server), do: {:error, "Server is not configured"}

  defp headers(nil), do: [{"accept", "application/json"}]

  defp headers(token) do
    [{"accept", "application/json"}, {"authorization", "Bearer #{token}"}]
  end

  defp normalize_body(body) when is_map(body) or is_list(body), do: body
  defp normalize_body(""), do: %{}
  defp normalize_body(body) when is_binary(body), do: %{"message" => body}
  defp normalize_body(body), do: %{"message" => inspect(body)}
end
