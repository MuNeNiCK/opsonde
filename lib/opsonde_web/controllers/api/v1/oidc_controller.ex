defmodule OpsondeWeb.API.V1.OIDCController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Accounts
  alias Opsonde.Accounts.{OIDCProvider, OIDCRequest, User}
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.AccountJSON

  @request_lifetime_seconds 600

  def status(conn, _params) do
    enabled =
      match?(
        {:ok, %OIDCProvider{enabled: true}},
        Accounts.current_oidc_provider(authorize?: false)
      )

    Response.data(conn, %{
      enabled: enabled,
      authorization_url:
        if(enabled, do: Opsonde.Secrets.oidc_authorization_url("/auth/user/oidc")),
      callback_uri: Opsonde.Secrets.oidc_callback_uri()
    })
  end

  def show_provider(conn, _params) do
    case Accounts.current_oidc_provider(actor: conn.assigns.current_user) do
      {:ok, %OIDCProvider{} = provider} ->
        Response.data(conn, provider_data(provider))

      {:ok, nil} ->
        Response.data(conn, %{
          enabled: false,
          callback_uri: Opsonde.Secrets.oidc_callback_uri()
        })

      {:error,
       %Ash.Error.Invalid{
         errors: [%Ash.Error.Query.NotFound{resource: OIDCProvider}]
       }} ->
        Response.data(conn, %{
          enabled: false,
          callback_uri: Opsonde.Secrets.oidc_callback_uri()
        })

      {:error, error} ->
        {:error, error}
    end
  end

  def configure_provider(
        conn,
        %{
          "oidc_provider" =>
            %{
              "issuer" => issuer,
              "client_id" => client_id,
              "client_secret" => client_secret
            } = input
        }
      ) do
    with {:ok, provider} <-
           Accounts.configure_oidc(
             %{
               issuer: issuer,
               client_id: client_id,
               client_secret: client_secret,
               enabled: Map.get(input, "enabled", true)
             },
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, provider_data(provider))
    end
  end

  def configure_provider(_conn, _params), do: {:error, :bad_request}

  def create_link_request(conn, _params) do
    start_token = OIDCRequest.random_secret()

    with :ok <- require_provider(),
         {:ok, request} <-
           Accounts.create_oidc_link(
             conn.assigns.current_user.id,
             OIDCRequest.digest(start_token),
             expires_at(),
             authorize?: false
           ) do
      Response.data(
        conn,
        %{
          authorization_url:
            Opsonde.Secrets.oidc_authorization_url(
              "/auth/oidc/start/#{request.id}?token=#{URI.encode_www_form(start_token)}"
            ),
          expires_at: request.expires_at
        },
        :created
      )
    end
  end

  def create_cli_request(
        conn,
        %{
          "request" => %{
            "redirect_uri" => redirect_uri,
            "code_challenge" => code_challenge
          }
        }
      ) do
    start_token = OIDCRequest.random_secret()

    with :ok <- require_provider(),
         :ok <- validate_loopback_redirect(redirect_uri),
         {:ok, verifier_digest} <- decode_challenge(code_challenge),
         {:ok, request} <-
           Accounts.create_oidc_cli_login(
             OIDCRequest.digest(start_token),
             verifier_digest,
             redirect_uri,
             expires_at(),
             authorize?: false
           ) do
      Response.data(
        conn,
        %{
          id: request.id,
          authorization_url:
            Opsonde.Secrets.oidc_authorization_url(
              "/auth/oidc/start/#{request.id}?token=#{URI.encode_www_form(start_token)}"
            ),
          expires_at: request.expires_at
        },
        :created
      )
    else
      {:error, :invalid_redirect} -> {:error, :bad_request}
      {:error, :invalid_challenge} -> {:error, :bad_request}
      error -> error
    end
  end

  def create_cli_request(_conn, _params), do: {:error, :bad_request}

  def exchange_cli_request(
        conn,
        %{"id" => id, "request" => %{"code" => code, "verifier" => verifier}}
      ) do
    with {:ok, %OIDCRequest{} = request} <- Accounts.get_oidc_request(id, authorize?: false),
         {:ok, consumed} <-
           Accounts.consume_oidc_request(
             request,
             request.revision,
             code,
             verifier,
             authorize?: false
           ),
         {:ok, token} <- Accounts.issue_session(consumed.user_id, authorize?: false),
         {:ok, %User{} = user} <- Accounts.get_user(consumed.user_id, authorize?: false) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{token: token, account: AccountJSON.data(user)}, :created)
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def exchange_cli_request(_conn, _params), do: {:error, :bad_request}

  defp require_provider do
    case Accounts.current_oidc_provider(authorize?: false) do
      {:ok, %OIDCProvider{enabled: true}} -> :ok
      _other -> {:error, :not_found}
    end
  end

  defp expires_at do
    DateTime.utc_now()
    |> DateTime.add(@request_lifetime_seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp decode_challenge(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _other -> {:error, :invalid_challenge}
    end
  end

  defp decode_challenge(_value), do: {:error, :invalid_challenge}

  defp validate_loopback_redirect(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and uri.port > 0 and uri.path == "/callback" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      {:error, :invalid_redirect}
    end
  end

  defp validate_loopback_redirect(_value), do: {:error, :invalid_redirect}

  defp provider_data(provider) do
    %{
      id: provider.id,
      issuer: provider.issuer,
      client_id: provider.client_id,
      enabled: provider.enabled,
      revision: provider.revision,
      callback_uri: Opsonde.Secrets.oidc_callback_uri(),
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end
end
