defmodule OpsondeWeb.ErrorJSONTest do
  use OpsondeWeb.ConnCase, async: true

  test "renders 404" do
    assert OpsondeWeb.ErrorJSON.render("404.json", %{}) == %{
             error: %{code: "not_found", message: "Not Found", request_id: nil}
           }
  end

  test "renders 500" do
    assert OpsondeWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               error: %{code: "internal_error", message: "Internal Server Error", request_id: nil}
             }
  end
end
