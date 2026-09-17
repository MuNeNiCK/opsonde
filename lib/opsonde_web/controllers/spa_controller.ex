defmodule OpsondeWeb.SPAController do
  use OpsondeWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(:ok, Application.app_dir(:opsonde, "priv/static/index.html"))
  end
end
