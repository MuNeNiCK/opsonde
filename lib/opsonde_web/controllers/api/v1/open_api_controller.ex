defmodule OpsondeWeb.API.V1.OpenAPIController do
  use OpsondeWeb, :api_controller

  alias OpenApiSpex.Schema

  tags ["OpenAPI"]

  operation :show,
    operation_id: "getOpenAPISpecification",
    summary: "Get the OpenAPI specification",
    security: [],
    responses: [
      ok:
        {"Resolved OpenAPI specification", "application/json",
         %Schema{type: :object, additionalProperties: true}}
    ]

  def show(conn, _params), do: OpenApiSpex.Plug.RenderSpec.call(conn, [])
end
