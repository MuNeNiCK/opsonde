defmodule OpsondeWeb.API.V1.AIUsageRoleAssignmentController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Providers
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.AIUsageRoleAssignmentJSON

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
