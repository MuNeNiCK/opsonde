defmodule OpsondeWeb.API.V1.TargetSetupController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Targets
  alias OpsondeWeb.API.{Pagination, Response, Schemas}
  alias OpsondeWeb.API.V1.{TargetSchemas, TargetSetupJSON}

  @boundary_fields ~w(name kind facts)
  @target_fields ~w(name kind platform facts management_boundary_id)
  @identity_fields ~w(target_id source kind value)
  @access_method_fields ~w(target_id provider_id name platform method endpoint provider_revision priority capabilities)
  @relationship_fields ~w(source_target_id destination_target_id kind facts valid_until)
  @policy_fields ~w(name request_kinds capabilities operations selector_match parameter_match reason)

  @list_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @show_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :not_found,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @write_errors Schemas.errors([
                  :bad_request,
                  :unauthorized,
                  :forbidden,
                  :not_found,
                  :conflict,
                  :unprocessable_entity,
                  :internal_server_error
                ])

  tags ["Targets"]

  operation :boundaries_index,
    operation_id: "listManagementBoundaries",
    summary: "List management boundaries",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Management boundary page", "application/json",
           TargetSchemas.ref("ManagementBoundaryPage")}
      ] ++
        @list_errors

  operation :boundaries_create,
    operation_id: "createManagementBoundary",
    summary: "Create a management boundary",
    request_body:
      {"Management boundary", "application/json",
       TargetSchemas.ref("CreateManagementBoundaryRequest"), required: true},
    responses:
      [
        created:
          {"Management boundary created", "application/json",
           TargetSchemas.ref("ManagementBoundaryResponse")}
      ] ++ @write_errors

  operation :boundaries_update,
    operation_id: "updateManagementBoundary",
    summary: "Update a management boundary",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Management boundary update", "application/json",
       TargetSchemas.ref("UpdateManagementBoundaryRequest"), required: true},
    responses:
      [
        ok:
          {"Management boundary updated", "application/json",
           TargetSchemas.ref("ManagementBoundaryResponse")}
      ] ++ @write_errors

  operation :boundaries_deactivate,
    operation_id: "deactivateManagementBoundary",
    summary: "Deactivate a management boundary",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Management boundary revision", "application/json",
       TargetSchemas.ref("DeactivateManagementBoundaryRequest"), required: true},
    responses:
      [
        ok:
          {"Management boundary deactivated", "application/json",
           TargetSchemas.ref("ManagementBoundaryResponse")}
      ] ++ @write_errors

  operation :targets_index,
    operation_id: "listTargets",
    summary: "List Targets",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Target page", "application/json", TargetSchemas.ref("TargetPage")}] ++
        @list_errors

  operation :targets_show,
    operation_id: "getTarget",
    summary: "Get a Target",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Target", "application/json", TargetSchemas.ref("TargetResponse")}] ++
        @show_errors

  operation :targets_create,
    operation_id: "createTarget",
    summary: "Create a Target",
    request_body:
      {"Target", "application/json", TargetSchemas.ref("CreateTargetRequest"), required: true},
    responses:
      [created: {"Target created", "application/json", TargetSchemas.ref("TargetResponse")}] ++
        @write_errors

  operation :targets_update,
    operation_id: "updateTarget",
    summary: "Update a Target",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target update", "application/json", TargetSchemas.ref("UpdateTargetRequest"),
       required: true},
    responses:
      [ok: {"Target updated", "application/json", TargetSchemas.ref("TargetResponse")}] ++
        @write_errors

  operation :targets_deactivate,
    operation_id: "deactivateTarget",
    summary: "Deactivate a Target",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target revision", "application/json", TargetSchemas.ref("DeactivateTargetRequest"),
       required: true},
    responses:
      [ok: {"Target deactivated", "application/json", TargetSchemas.ref("TargetResponse")}] ++
        @write_errors

  operation :identities_index,
    operation_id: "listExternalIdentities",
    summary: "List external identities",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"External identity page", "application/json",
           TargetSchemas.ref("ExternalIdentityPage")}
      ] ++ @list_errors

  operation :identities_create,
    operation_id: "createExternalIdentity",
    summary: "Create an external identity",
    request_body:
      {"External identity", "application/json",
       TargetSchemas.ref("CreateExternalIdentityRequest"), required: true},
    responses:
      [
        created:
          {"External identity created", "application/json",
           TargetSchemas.ref("ExternalIdentityResponse")}
      ] ++ @write_errors

  operation :identities_update,
    operation_id: "updateExternalIdentity",
    summary: "Update an external identity",
    parameters: Schemas.id_parameter(),
    request_body:
      {"External identity update", "application/json",
       TargetSchemas.ref("UpdateExternalIdentityRequest"), required: true},
    responses:
      [
        ok:
          {"External identity updated", "application/json",
           TargetSchemas.ref("ExternalIdentityResponse")}
      ] ++ @write_errors

  operation :identities_deactivate,
    operation_id: "deactivateExternalIdentity",
    summary: "Deactivate an external identity",
    parameters: Schemas.id_parameter(),
    request_body:
      {"External identity revision", "application/json",
       TargetSchemas.ref("DeactivateExternalIdentityRequest"), required: true},
    responses:
      [
        ok:
          {"External identity deactivated", "application/json",
           TargetSchemas.ref("ExternalIdentityResponse")}
      ] ++ @write_errors

  operation :access_methods_index,
    operation_id: "listAccessMethods",
    summary: "List Access Methods",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Access Method page", "application/json", TargetSchemas.ref("AccessMethodPage")}] ++
        @list_errors

  operation :access_methods_create,
    operation_id: "createAccessMethod",
    summary: "Create an Access Method",
    request_body:
      {"Access Method", "application/json", TargetSchemas.ref("CreateAccessMethodRequest"),
       required: true},
    responses:
      [
        created:
          {"Access Method created", "application/json", TargetSchemas.ref("AccessMethodResponse")}
      ] ++ @write_errors

  operation :access_methods_update,
    operation_id: "updateAccessMethod",
    summary: "Update an Access Method",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Access Method update", "application/json", TargetSchemas.ref("UpdateAccessMethodRequest"),
       required: true},
    responses:
      [
        ok:
          {"Access Method updated", "application/json", TargetSchemas.ref("AccessMethodResponse")}
      ] ++ @write_errors

  operation :access_methods_deactivate,
    operation_id: "deactivateAccessMethod",
    summary: "Deactivate an Access Method",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Access Method revision", "application/json",
       TargetSchemas.ref("DeactivateAccessMethodRequest"), required: true},
    responses:
      [
        ok:
          {"Access Method deactivated", "application/json",
           TargetSchemas.ref("AccessMethodResponse")}
      ] ++ @write_errors

  operation :relationships_index,
    operation_id: "listTargetRelationships",
    summary: "List Target relationships",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Target relationship page", "application/json",
           TargetSchemas.ref("TargetRelationshipPage")}
      ] ++ @list_errors

  operation :relationships_create,
    operation_id: "createTargetRelationship",
    summary: "Create a Target relationship",
    request_body:
      {"Target relationship", "application/json",
       TargetSchemas.ref("CreateTargetRelationshipRequest"), required: true},
    responses:
      [
        created:
          {"Target relationship created", "application/json",
           TargetSchemas.ref("TargetRelationshipResponse")}
      ] ++ @write_errors

  operation :relationships_update,
    operation_id: "updateTargetRelationship",
    summary: "Update a Target relationship",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target relationship update", "application/json",
       TargetSchemas.ref("UpdateTargetRelationshipRequest"), required: true},
    responses:
      [
        ok:
          {"Target relationship updated", "application/json",
           TargetSchemas.ref("TargetRelationshipResponse")}
      ] ++ @write_errors

  operation :relationships_deactivate,
    operation_id: "deactivateTargetRelationship",
    summary: "Deactivate a Target relationship",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target relationship revision", "application/json",
       TargetSchemas.ref("DeactivateTargetRelationshipRequest"), required: true},
    responses:
      [
        ok:
          {"Target relationship deactivated", "application/json",
           TargetSchemas.ref("TargetRelationshipResponse")}
      ] ++ @write_errors

  operation :policies_index,
    operation_id: "listTargetPolicies",
    summary: "List Target policies",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Target policy page", "application/json", TargetSchemas.ref("TargetPolicyPage")}] ++
        @list_errors

  operation :policies_create,
    operation_id: "createTargetPolicy",
    summary: "Create a Target policy",
    request_body:
      {"Target policy", "application/json", TargetSchemas.ref("CreateTargetPolicyRequest"),
       required: true},
    responses:
      [
        created:
          {"Target policy created", "application/json", TargetSchemas.ref("TargetPolicyResponse")}
      ] ++ @write_errors

  operation :policies_update,
    operation_id: "updateTargetPolicy",
    summary: "Update a Target policy",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target policy update", "application/json", TargetSchemas.ref("UpdateTargetPolicyRequest"),
       required: true},
    responses:
      [
        ok:
          {"Target policy updated", "application/json", TargetSchemas.ref("TargetPolicyResponse")}
      ] ++
        @write_errors

  operation :policies_deactivate,
    operation_id: "deactivateTargetPolicy",
    summary: "Deactivate a Target policy",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Target policy revision", "application/json",
       TargetSchemas.ref("DeactivateTargetPolicyRequest"), required: true},
    responses:
      [
        ok:
          {"Target policy deactivated", "application/json",
           TargetSchemas.ref("TargetPolicyResponse")}
      ] ++ @write_errors

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
