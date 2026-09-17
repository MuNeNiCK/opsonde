defmodule OpsondeWeb.APIErrorController do
  use OpsondeWeb, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(OpsondeWeb.ErrorJSON.render("404.json", %{}))
  end
end
