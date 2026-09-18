defmodule OpsondeWeb.APIErrorController do
  use OpsondeWeb, :controller

  def not_found(conn, _params) do
    OpsondeWeb.API.Response.error(conn, :not_found, "not_found", "API route was not found")
  end
end
