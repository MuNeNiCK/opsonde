defmodule OpsondeWeb.API.FallbackController do
  @moduledoc false

  use OpsondeWeb, :controller

  def call(conn, {:error, error}), do: OpsondeWeb.API.Response.from_error(conn, error)
  def call(conn, error), do: OpsondeWeb.API.Response.from_error(conn, error)
end
