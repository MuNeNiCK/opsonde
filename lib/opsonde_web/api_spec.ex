defmodule OpsondeWeb.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias OpsondeWeb.API.Schemas
  alias OpsondeWeb.API.V1.{AccountSchemas, InventorySchemas, ProviderSchemas, TargetSchemas}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Opsonde API",
        version: Application.spec(:opsonde, :vsn) |> to_string()
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(OpsondeWeb.Router),
      components: %Components{
        schemas:
          Schemas.components()
          |> Map.merge(AccountSchemas.components())
          |> Map.merge(ProviderSchemas.components())
          |> Map.merge(TargetSchemas.components())
          |> Map.merge(InventorySchemas.components()),
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
