defmodule OpsondeWeb.APIErrorControllerTest do
  use OpsondeWeb.ConnCase, async: true

  test "returns JSON for an unknown API route", %{conn: conn} do
    conn = get(conn, "/api/missing")

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
  end
end
