defmodule OpsondeWeb.OIDCStartController do
  use OpsondeWeb, :controller

  alias Opsonde.Accounts
  alias Opsonde.Accounts.OIDCRequest

  def start(conn, %{"id" => id, "token" => token}) do
    with {:ok, %OIDCRequest{} = request} <- Accounts.get_oidc_request(id, authorize?: false),
         {:ok, _started} <-
           Accounts.start_oidc_request(
             request,
             request.revision,
             token,
             authorize?: false
           ) do
      conn
      |> protect_response()
      |> put_session(:opsonde_oidc_request_id, request.id)
      |> redirect(to: "/auth/user/oidc")
    else
      _error ->
        conn
        |> protect_response()
        |> send_resp(:unauthorized, "OIDC request is invalid or expired")
    end
  end

  def start(conn, _params) do
    conn
    |> protect_response()
    |> send_resp(:bad_request, "OIDC request token is required")
  end

  defp protect_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
