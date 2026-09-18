defmodule OpsondeWeb.API.Auth do
  @moduledoc false

  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias OpsondeWeb.API.Response

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = Helpers.retrieve_from_bearer(conn, :opsonde)

    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Response.error(:unauthorized, "unauthenticated", "Authentication is required")
      |> halt()
    end
  end
end
