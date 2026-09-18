defmodule OpsondeWeb.API.V1.SessionController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias AshAuthentication.Plug.Helpers
  alias Opsonde.Accounts
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.AccountJSON

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Accounts.sign_in(email, password, authorize?: true) do
      {:ok, user} ->
        token = Ash.Resource.get_metadata(user, :token)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> Response.data(%{token: token, account: AccountJSON.data(user)}, :created)

      {:error, _error} ->
        {:error, :invalid_credentials}
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def show(conn, _params) do
    Response.data(conn, %{account: AccountJSON.data(conn.assigns.current_user)})
  end

  def delete(conn, _params) do
    conn
    |> Helpers.revoke_bearer_tokens(:opsonde)
    |> send_resp(:no_content, "")
  end
end
