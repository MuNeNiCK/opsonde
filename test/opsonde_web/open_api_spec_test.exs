defmodule OpsondeWeb.OpenAPISpecTest do
  use OpsondeWeb.ConnCase, async: true

  @http_methods [:delete, :get, :head, :options, :patch, :post, :put, :trace]

  test "the application serves the resolved specification" do
    document =
      build_conn()
      |> get("/api/v1/openapi.json")
      |> json_response(200)

    assert document["openapi"] == "3.0.0"
    assert document["info"]["title"] == "Opsonde API"
    assert document["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"

    assert document["paths"]["/api/v1/openapi.json"]["get"]["operationId"] ==
             "getOpenAPISpecification"
  end

  test "route coverage exposes operations that still need domain contracts" do
    missing = api_routes() -- documented_operations()

    assert {:post, "/api/v1/accounts/bootstrap"} in missing
    refute {:get, "/api/v1/openapi.json"} in missing
  end

  test "contract validation uses the existing API error envelope" do
    response =
      build_conn()
      |> put_resp_header("x-request-id", "openapi-test")
      |> OpsondeWeb.API.OpenAPIError.call([%{name: :email}])

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "Request validation failed",
               "request_id" => "openapi-test",
               "details" => %{"fields" => ["email"]}
             }
           } = json_response(response, 422)
  end

  defp api_routes do
    OpsondeWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&product_api_route?/1)
    |> Enum.map(&{&1.verb, normalize_path(&1.path)})
    |> Enum.sort()
  end

  defp documented_operations do
    for {path, path_item} <- OpsondeWeb.ApiSpec.spec().paths,
        method <- @http_methods,
        match?(%OpenApiSpex.Operation{}, Map.get(path_item, method)),
        do: {method, path}
  end

  defp product_api_route?(route) do
    String.starts_with?(route.path, "/api/v1") and
      route.plug != OpsondeWeb.APIErrorController
  end

  defp normalize_path(path) do
    Regex.replace(~r/:([a-z_]+)/, path, "{\\1}")
  end
end
