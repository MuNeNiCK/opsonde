defmodule OpsondeWeb.API.V1.CLISessionController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Accounts
  alias Opsonde.Accounts.{OIDCRequest, User}
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.AccountJSON

  @request_lifetime_seconds 600

  def create(
        conn,
        %{
          "request" => %{
            "redirect_uri" => redirect_uri,
            "code_challenge" => code_challenge
          }
        }
      ) do
    start_token = OIDCRequest.random_secret()

    with :ok <- validate_loopback_redirect(redirect_uri),
         {:ok, verifier_digest} <- decode_challenge(code_challenge),
         {:ok, request} <-
           Accounts.create_cli_login(
             OIDCRequest.digest(start_token),
             verifier_digest,
             redirect_uri,
             expires_at(),
             authorize?: false
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(
        %{
          id: request.id,
          authorization_url:
            Opsonde.Secrets.public_url(
              "/cli-login/#{request.id}#token=#{URI.encode_www_form(start_token)}"
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

  def create(_conn, _params), do: {:error, :bad_request}

  def approve(
        conn,
        %{"id" => id, "request" => %{"start_token" => start_token}}
      ) do
    with %User{} = user <- conn.assigns.current_user,
         {:ok, %OIDCRequest{purpose: :cli_login} = request} <-
           Accounts.get_oidc_request(id, authorize?: false),
         {:ok, started} <-
           Accounts.start_oidc_request(
             request,
             request.revision,
             start_token,
             authorize?: false
           ),
         code <- OIDCRequest.random_secret(),
         {:ok, completed} <-
           Accounts.complete_oidc_request(
             started,
             started.revision,
             user.id,
             OIDCRequest.digest(code),
             authorize?: false
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri:
          append_query(completed.redirect_uri, %{request_id: completed.id, code: code}),
        account: AccountJSON.data(user)
      })
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def approve(_conn, _params), do: {:error, :bad_request}

  def deny(conn, %{"id" => id, "request" => %{"start_token" => start_token}}) do
    with {:ok, %OIDCRequest{purpose: :cli_login} = request} <-
           Accounts.get_oidc_request(id, authorize?: false),
         {:ok, started} <-
           Accounts.start_oidc_request(
             request,
             request.revision,
             start_token,
             authorize?: false
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri:
          append_query(started.redirect_uri, %{
            request_id: started.id,
            error: "access_denied"
          })
      })
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def deny(_conn, _params), do: {:error, :bad_request}

  def exchange(
        conn,
        %{"id" => id, "request" => %{"code" => code, "verifier" => verifier}}
      ) do
    with {:ok, %OIDCRequest{purpose: :cli_login} = request} <-
           Accounts.get_oidc_request(id, authorize?: false),
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

  def exchange(_conn, _params), do: {:error, :bad_request}

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

  defp append_query(uri, values) do
    parsed = URI.parse(uri)

    query =
      values
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> URI.encode_query()

    to_string(%URI{parsed | query: query})
  end
end
