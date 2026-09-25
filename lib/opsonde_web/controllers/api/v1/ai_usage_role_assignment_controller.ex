defmodule OpsondeWeb.API.V1.AIUsageRoleAssignmentController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Providers
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.{AIUsageRoleAssignmentJSON, ProviderSchemas}

  tags ["AI usage roles"]

  operation :index,
    operation_id: "listAIUsageRoleAssignments",
    summary: "List AI usage-role assignments",
    parameters: OpsondeWeb.API.Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"AI usage-role assignment page", "application/json",
           ProviderSchemas.ref("AIUsageRoleAssignmentPage")}
      ] ++
        OpsondeWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, assignments} <-
           Providers.page_ai_usage_role_assignments(
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, assignments, &AIUsageRoleAssignmentJSON.data/1)
    end
  end
end
