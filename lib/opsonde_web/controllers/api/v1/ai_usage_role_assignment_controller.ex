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

  operation :create,
    operation_id: "createAIUsageRoleAssignment",
    summary: "Assign an AI Provider role",
    request_body:
      {"AI usage-role assignment", "application/json",
       ProviderSchemas.ref("CreateAIUsageRoleAssignmentRequest"), required: true},
    responses:
      [
        created:
          {"AI usage-role assignment created", "application/json",
           ProviderSchemas.ref("AIUsageRoleAssignmentResponse")}
      ] ++
        OpsondeWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :update,
    operation_id: "updateAIUsageRoleAssignment",
    summary: "Update an AI usage-role assignment",
    parameters: OpsondeWeb.API.Schemas.id_parameter(),
    request_body:
      {"AI usage-role assignment update", "application/json",
       ProviderSchemas.ref("UpdateAIUsageRoleAssignmentRequest"), required: true},
    responses:
      [
        ok:
          {"AI usage-role assignment updated", "application/json",
           ProviderSchemas.ref("AIUsageRoleAssignmentResponse")}
      ] ++
        OpsondeWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
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

  def create(
        conn,
        %{
          "assignment" => %{
            "provider_id" => provider_id,
            "role" => role,
            "priority" => priority
          }
        }
      ) do
    with {:ok, assignment} <-
           Providers.create_ai_usage_role_assignment(provider_id, role, priority,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, AIUsageRoleAssignmentJSON.data(assignment), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def update(
        conn,
        %{
          "id" => id,
          "assignment" => %{"expected_revision" => expected_revision} = input
        }
      ) do
    attrs = assignment_attributes(input)

    if map_size(attrs) == 0 do
      {:error, :bad_request}
    else
      with {:ok, assignment} <-
             Providers.get_ai_usage_role_assignment(id, actor: conn.assigns.current_user),
           {:ok, updated} <-
             Providers.update_ai_usage_role_assignment(assignment, expected_revision, attrs,
               actor: conn.assigns.current_user
             ) do
        Response.data(conn, AIUsageRoleAssignmentJSON.data(updated))
      end
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}

  defp assignment_attributes(input) do
    [:priority, :enabled]
    |> Enum.reduce(%{}, fn field, attrs ->
      case Map.fetch(input, Atom.to_string(field)) do
        {:ok, value} -> Map.put(attrs, field, value)
        :error -> attrs
      end
    end)
  end
end
