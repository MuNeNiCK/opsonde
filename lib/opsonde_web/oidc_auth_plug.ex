defmodule OpsondeWeb.OIDCAuthPlug do
  @moduledoc false

  use AshAuthentication.Plug, otp_app: :opsonde

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Opsonde.Accounts
  alias Opsonde.Accounts.OIDCRequest
  alias OpsondeWeb.API.V1.AccountJSON

  @impl true
  def handle_success(conn, _activity, user, token) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case current_request(conn) do
      {:ok, %OIDCRequest{purpose: :cli_login} = request} ->
        complete_cli(conn, request, user)

      {:ok, %OIDCRequest{purpose: :link} = request} ->
        complete_link(conn, request, user, token)

      _other ->
        conn
        |> delete_session(:opsonde_oidc_request_id)
        |> browser_result(%{
          type: "opsonde:oidc-session",
          token: token,
          account: AccountJSON.data(user)
        })
    end
  end

  @impl true
  def handle_failure(conn, _activity, _reason) do
    request = current_request(conn)

    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> delete_session(:opsonde_oidc_request_id)

    case request do
      {:ok, %OIDCRequest{purpose: :cli_login} = request} ->
        redirect(conn,
          external: append_query(request.redirect_uri, %{error: "authentication_failed"})
        )

      _other ->
        browser_result(conn, %{type: "opsonde:oidc-error"})
    end
  end

  defp complete_cli(conn, request, user) do
    code = OIDCRequest.random_secret()

    case Accounts.complete_oidc_request(
           request,
           request.revision,
           user.id,
           OIDCRequest.digest(code),
           authorize?: false
         ) do
      {:ok, completed} ->
        conn
        |> delete_session(:opsonde_oidc_request_id)
        |> redirect(
          external: append_query(completed.redirect_uri, %{request_id: completed.id, code: code})
        )

      {:error, _error} ->
        conn
        |> delete_session(:opsonde_oidc_request_id)
        |> browser_result(%{type: "opsonde:oidc-error"})
    end
  end

  defp complete_link(conn, request, user, token) do
    if request.completed_at && request.user_id == user.id && is_binary(token) do
      conn
      |> delete_session(:opsonde_oidc_request_id)
      |> browser_result(%{
        type: "opsonde:oidc-linked",
        token: token,
        account: AccountJSON.data(user)
      })
    else
      conn
      |> delete_session(:opsonde_oidc_request_id)
      |> browser_result(%{type: "opsonde:oidc-error"})
    end
  end

  defp current_request(conn) do
    with id when is_binary(id) <- get_session(conn, :opsonde_oidc_request_id),
         {:ok, %OIDCRequest{} = request} <- Accounts.get_oidc_request(id, authorize?: false) do
      {:ok, request}
    else
      _other -> :error
    end
  end

  defp browser_result(conn, payload) do
    nonce = OIDCRequest.random_secret(18)
    encoded = Jason.encode!(payload, escape: :html_safe)

    html = """
    <!doctype html><meta charset="utf-8"><title>Opsonde</title>
    <script nonce="#{nonce}">
      if (window.opener) window.opener.postMessage(#{encoded}, window.location.origin);
      window.close();
    </script>
    """

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'nonce-#{nonce}'"
    )
    |> send_resp(:ok, html)
  end

  defp append_query(uri, values) do
    parsed = URI.parse(uri)

    query =
      values
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> URI.encode_query()

    to_string(%URI{parsed | query: query})
  end
end
