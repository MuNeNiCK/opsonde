defmodule OpsondeWeb.API.V1.TargetSetupController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Targets
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.TargetSetupJSON

  @boundary_fields ~w(name kind facts)
  @target_fields ~w(name kind platform facts management_boundary_id)
  @identity_fields ~w(target_id source kind value)
  @access_method_fields ~w(target_id provider_id name platform method endpoint provider_revision priority capabilities)
  @relationship_fields ~w(source_target_id destination_target_id kind facts valid_until)
  @policy_fields ~w(name request_kinds capabilities operations selector_match parameter_match reason)

  def boundaries_index(conn, params) do
    page(conn, params, &Targets.page_management_boundaries/1, &TargetSetupJSON.boundary/1)
  end

  def boundaries_create(conn, %{"management_boundary" => input}) do
    with {:ok, boundary} <-
           Targets.create_management_boundary(input["name"], input["kind"], input["facts"] || %{},
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.boundary(boundary), :created)
    end
  end

  def boundaries_create(_conn, _params), do: {:error, :bad_request}

  def boundaries_update(conn, %{"id" => id, "management_boundary" => input}) do
    update_record(
      conn,
      id,
      input,
      @boundary_fields,
      &Targets.get_management_boundary/2,
      &Targets.update_management_boundary/4,
      &TargetSetupJSON.boundary/1
    )
  end

  def boundaries_update(_conn, _params), do: {:error, :bad_request}

  def boundaries_deactivate(conn, %{"id" => id, "management_boundary" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_management_boundary/2,
      &Targets.deactivate_management_boundary/3,
      &TargetSetupJSON.boundary/1
    )
  end

  def boundaries_deactivate(_conn, _params), do: {:error, :bad_request}

  def targets_index(conn, params) do
    page(conn, params, &Targets.page_targets/1, &TargetSetupJSON.target/1)
  end

  def targets_show(conn, %{"id" => id}) do
    with {:ok, target} <- Targets.get_target(id, actor: conn.assigns.current_user) do
      Response.data(conn, TargetSetupJSON.target(target))
    end
  end

  def targets_create(conn, %{"target" => input}) do
    with {:ok, target} <-
           Targets.create_target(
             input["name"],
             input["kind"],
             input["platform"],
             input["facts"] || %{},
             input["management_boundary_id"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.target(target), :created)
    end
  end

  def targets_create(_conn, _params), do: {:error, :bad_request}

  def targets_update(conn, %{"id" => id, "target" => input}) do
    update_record(
      conn,
      id,
      input,
      @target_fields,
      &Targets.get_target/2,
      &Targets.update_target/4,
      &TargetSetupJSON.target/1
    )
  end

  def targets_update(_conn, _params), do: {:error, :bad_request}

  def targets_deactivate(conn, %{"id" => id, "target" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_target/2,
      &Targets.deactivate_target/3,
      &TargetSetupJSON.target/1
    )
  end

  def targets_deactivate(_conn, _params), do: {:error, :bad_request}

  def identities_index(conn, params) do
    page(conn, params, &Targets.page_external_identities/1, &TargetSetupJSON.identity/1)
  end

  def identities_create(conn, %{"external_identity" => input}) do
    with {:ok, identity} <-
           Targets.create_external_identity(
             input["target_id"],
             input["source"],
             input["kind"],
             input["value"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.identity(identity), :created)
    end
  end

  def identities_create(_conn, _params), do: {:error, :bad_request}

  def identities_update(conn, %{"id" => id, "external_identity" => input}) do
    update_record(
      conn,
      id,
      input,
      @identity_fields,
      &Targets.get_external_identity/2,
      &Targets.update_external_identity/4,
      &TargetSetupJSON.identity/1
    )
  end

  def identities_update(_conn, _params), do: {:error, :bad_request}

  def identities_deactivate(conn, %{"id" => id, "external_identity" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_external_identity/2,
      &Targets.deactivate_external_identity/3,
      &TargetSetupJSON.identity/1
    )
  end

  def identities_deactivate(_conn, _params), do: {:error, :bad_request}

  def access_methods_index(conn, params) do
    page(conn, params, &Targets.page_access_methods/1, &TargetSetupJSON.access_method/1)
  end

  def access_methods_create(conn, %{"access_method" => input}) do
    with {:ok, method} <-
           Targets.create_access_method(
             input["target_id"],
             input["provider_id"],
             input["name"],
             input["platform"],
             input["method"],
             input["endpoint"],
             input["provider_revision"],
             input["priority"] || 100,
             input["capabilities"] || [],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.access_method(method), :created)
    end
  end

  def access_methods_create(_conn, _params), do: {:error, :bad_request}

  def access_methods_update(conn, %{"id" => id, "access_method" => input}) do
    update_record(
      conn,
      id,
      input,
      @access_method_fields,
      &Targets.get_access_method/2,
      &Targets.update_access_method/4,
      &TargetSetupJSON.access_method/1
    )
  end

  def access_methods_update(_conn, _params), do: {:error, :bad_request}

  def access_methods_deactivate(conn, %{"id" => id, "access_method" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_access_method/2,
      &Targets.deactivate_access_method/3,
      &TargetSetupJSON.access_method/1
    )
  end

  def access_methods_deactivate(_conn, _params), do: {:error, :bad_request}

  def relationships_index(conn, params) do
    page(conn, params, &Targets.page_relationships/1, &TargetSetupJSON.relationship/1)
  end

  def relationships_create(conn, %{"relationship" => input}) do
    with {:ok, relationship} <-
           Targets.create_relationship(
             input["source_target_id"],
             input["destination_target_id"],
             input["kind"],
             input["facts"] || %{},
             input["valid_until"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.relationship(relationship), :created)
    end
  end

  def relationships_create(_conn, _params), do: {:error, :bad_request}

  def relationships_update(conn, %{"id" => id, "relationship" => input}) do
    update_record(
      conn,
      id,
      input,
      @relationship_fields,
      &Targets.get_relationship/2,
      &Targets.update_relationship/4,
      &TargetSetupJSON.relationship/1
    )
  end

  def relationships_update(_conn, _params), do: {:error, :bad_request}

  def relationships_deactivate(conn, %{"id" => id, "relationship" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_relationship/2,
      &Targets.deactivate_relationship/3,
      &TargetSetupJSON.relationship/1
    )
  end

  def relationships_deactivate(_conn, _params), do: {:error, :bad_request}

  def policies_index(conn, params) do
    page(conn, params, &Targets.page_target_policies/1, &TargetSetupJSON.policy/1)
  end

  def policies_create(conn, %{"target_policy" => input}) do
    with {:ok, policy} <-
           Targets.create_target_policy(
             input["target_id"],
             input["name"],
             input["request_kinds"],
             input["capabilities"] || [],
             input["operations"] || [],
             input["selector_match"] || %{},
             input["parameter_match"] || %{},
             input["reason"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetSetupJSON.policy(policy), :created)
    end
  end

  def policies_create(_conn, _params), do: {:error, :bad_request}

  def policies_update(conn, %{"id" => id, "target_policy" => input}) do
    update_record(
      conn,
      id,
      input,
      @policy_fields,
      &Targets.get_target_policy/2,
      &Targets.update_target_policy/4,
      &TargetSetupJSON.policy/1
    )
  end

  def policies_update(_conn, _params), do: {:error, :bad_request}

  def policies_deactivate(conn, %{"id" => id, "target_policy" => input}) do
    deactivate_record(
      conn,
      id,
      input,
      &Targets.get_target_policy/2,
      &Targets.deactivate_target_policy/3,
      &TargetSetupJSON.policy/1
    )
  end

  def policies_deactivate(_conn, _params), do: {:error, :bad_request}

  defp page(conn, params, action, serializer) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, records} <- action.(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, records, serializer)
    end
  end

  defp update_record(conn, id, input, fields, get, update, serializer) do
    with {:ok, expected_revision} <- Map.fetch(input, "expected_revision"),
         attrs when map_size(attrs) > 0 <- attributes(input, fields),
         {:ok, record} <- get.(id, actor: conn.assigns.current_user),
         {:ok, updated} <-
           update.(record, expected_revision, attrs, actor: conn.assigns.current_user) do
      Response.data(conn, serializer.(updated))
    else
      :error -> {:error, :bad_request}
      attrs when is_map(attrs) -> {:error, :bad_request}
      error -> error
    end
  end

  defp deactivate_record(conn, id, input, get, deactivate, serializer) do
    with {:ok, expected_revision} <- Map.fetch(input, "expected_revision"),
         {:ok, record} <- get.(id, actor: conn.assigns.current_user),
         {:ok, deactivated} <-
           deactivate.(record, expected_revision, actor: conn.assigns.current_user) do
      Response.data(conn, serializer.(deactivated))
    else
      :error -> {:error, :bad_request}
      error -> error
    end
  end

  defp attributes(input, fields) do
    Enum.reduce(fields, %{}, fn field, attrs ->
      case Map.fetch(input, field) do
        {:ok, value} -> Map.put(attrs, String.to_existing_atom(field), value)
        :error -> attrs
      end
    end)
  end
end
