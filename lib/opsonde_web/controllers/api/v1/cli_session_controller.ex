defmodule OpsondeWeb.API.V1.CLISessionController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Accounts
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.AccountJSON

  def create(
        conn,
        %{
          "request" => %{
            "redirect_uri" => redirect_uri,
            "code_challenge" => code_challenge
          }
        }
      ) do
    with {:ok, %{request: request, start_token: start_token}} <-
           Accounts.request_cli_login(redirect_uri, code_challenge) do
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
      _error -> {:error, :bad_request}
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def approve(
        conn,
        %{"id" => id, "request" => %{"start_token" => start_token}}
      ) do
    with {:ok, %{request: request, code: code, user: user}} <-
           Accounts.approve_cli_login(id, start_token, actor: conn.assigns.current_user) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri: append_query(request.redirect_uri, %{request_id: request.id, code: code}),
        account: AccountJSON.data(user)
      })
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def approve(_conn, _params), do: {:error, :bad_request}

  def deny(conn, %{"id" => id, "request" => %{"start_token" => start_token}}) do
    with {:ok, request} <-
           Accounts.deny_cli_login(id, start_token, actor: conn.assigns.current_user) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri:
          append_query(request.redirect_uri, %{
            request_id: request.id,
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
    with {:ok, %{token: token, user: user}} <-
           Accounts.exchange_cli_login(id, code, verifier) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{token: token, account: AccountJSON.data(user)}, :created)
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def exchange(_conn, _params), do: {:error, :bad_request}

  defp append_query(uri, values) do
    parsed = URI.parse(uri)

    query =
      values
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> URI.encode_query()

    to_string(%URI{parsed | query: query})
  end
end
