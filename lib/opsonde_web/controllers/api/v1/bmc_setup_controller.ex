defmodule OpsondeWeb.API.V1.BMCSetupController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Targets
  alias OpsondeWeb.API.{Pagination, Response, Schemas}
  alias OpsondeWeb.API.V1.{BMCSchemas, BMCSetupJSON}

  @operation_fields ~w(name description request_kind protocol_request secret_bindings parameter_classes input_schema output_schema verification_schema)
  @secret_fields ~w(name value)
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

  operation :operations_index,
    operation_id: "listBMCOperations",
    summary: "List BMC operations for an Access Method",
    parameters: Schemas.id_parameter(:access_method_id) ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"BMC operation page", "application/json", BMCSchemas.ref("BMCOperationPage")}] ++
        @list_errors

  operation :operations_create,
    operation_id: "createBMCOperation",
    summary: "Create a BMC operation",
    parameters: Schemas.id_parameter(:access_method_id),
    request_body:
      {"BMC operation", "application/json", BMCSchemas.ref("CreateBMCOperationRequest"),
       required: true},
    responses:
      [
        created:
          {"BMC operation created", "application/json", BMCSchemas.ref("BMCOperationResponse")}
      ] ++ @write_errors

  operation :operations_show,
    operation_id: "getBMCOperation",
    summary: "Get a BMC operation",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"BMC operation", "application/json", BMCSchemas.ref("BMCOperationResponse")}] ++
        @show_errors

  operation :operations_update,
    operation_id: "updateBMCOperation",
    summary: "Update a BMC operation",
    parameters: Schemas.id_parameter(),
    request_body:
      {"BMC operation update", "application/json", BMCSchemas.ref("UpdateBMCOperationRequest"),
       required: true},
    responses:
      [ok: {"BMC operation updated", "application/json", BMCSchemas.ref("BMCOperationResponse")}] ++
        @write_errors

  operation :operations_deactivate,
    operation_id: "deactivateBMCOperation",
    summary: "Deactivate a BMC operation",
    parameters: Schemas.id_parameter(),
    request_body:
      {"BMC operation revision", "application/json",
       BMCSchemas.ref("DeactivateBMCOperationRequest"), required: true},
    responses:
      [
        ok:
          {"BMC operation deactivated", "application/json",
           BMCSchemas.ref("BMCOperationResponse")}
      ] ++ @write_errors

  operation :secrets_index,
    operation_id: "listBMCSecrets",
    summary: "List BMC secret references for an Access Method",
    parameters: Schemas.id_parameter(:access_method_id) ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"BMC secret page", "application/json", BMCSchemas.ref("BMCSecretPage")}] ++
        @list_errors

  operation :secrets_create,
    operation_id: "createBMCSecret",
    summary: "Create a BMC secret",
    parameters: Schemas.id_parameter(:access_method_id),
    request_body:
      {"BMC secret", "application/json", BMCSchemas.ref("CreateBMCSecretRequest"), required: true},
    responses:
      [created: {"BMC secret created", "application/json", BMCSchemas.ref("BMCSecretResponse")}] ++
        @write_errors

  operation :secrets_show,
    operation_id: "getBMCSecret",
    summary: "Get a BMC secret reference",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"BMC secret", "application/json", BMCSchemas.ref("BMCSecretResponse")}] ++
        @show_errors

  operation :secrets_update,
    operation_id: "updateBMCSecret",
    summary: "Update or rotate a BMC secret",
    parameters: Schemas.id_parameter(),
    request_body:
      {"BMC secret update", "application/json", BMCSchemas.ref("UpdateBMCSecretRequest"),
       required: true},
    responses:
      [ok: {"BMC secret updated", "application/json", BMCSchemas.ref("BMCSecretResponse")}] ++
        @write_errors

  operation :secrets_deactivate,
    operation_id: "deactivateBMCSecret",
    summary: "Deactivate a BMC secret",
    parameters: Schemas.id_parameter(),
    request_body:
      {"BMC secret revision", "application/json", BMCSchemas.ref("DeactivateBMCSecretRequest"),
       required: true},
    responses:
      [ok: {"BMC secret deactivated", "application/json", BMCSchemas.ref("BMCSecretResponse")}] ++
        @write_errors

  def operations_index(conn, %{"access_method_id" => method_id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, records} <-
           Targets.page_bmc_operations_for_method(method_id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, records, &BMCSetupJSON.operation/1)
    end
  end

  def operations_create(conn, %{"access_method_id" => method_id, "bmc_operation" => input}) do
    with {:ok, record} <-
           Targets.create_bmc_operation(
             method_id,
             input["name"],
             input["description"],
             input["request_kind"],
             input["protocol_request"],
             input["input_schema"],
             input["output_schema"],
             input["verification_schema"],
             %{
               secret_bindings: input["secret_bindings"] || %{},
               parameter_classes: input["parameter_classes"] || %{}
             },
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, BMCSetupJSON.operation(record), :created)
    end
  end

  def operations_create(_conn, _params), do: {:error, :bad_request}

  def operations_show(conn, %{"id" => id}) do
    with {:ok, record} <- Targets.get_bmc_operation(id, actor: conn.assigns.current_user) do
      Response.data(conn, BMCSetupJSON.operation(record))
    end
  end

  def operations_update(conn, %{"id" => id, "bmc_operation" => input}) do
    update(
      conn,
      id,
      input,
      @operation_fields,
      &Targets.get_bmc_operation/2,
      &Targets.update_bmc_operation/4,
      &BMCSetupJSON.operation/1
    )
  end

  def operations_update(_conn, _params), do: {:error, :bad_request}

  def operations_deactivate(conn, %{"id" => id, "bmc_operation" => input}) do
    deactivate(
      conn,
      id,
      input,
      &Targets.get_bmc_operation/2,
      &Targets.deactivate_bmc_operation/3,
      &BMCSetupJSON.operation/1
    )
  end

  def operations_deactivate(_conn, _params), do: {:error, :bad_request}

  def secrets_index(conn, %{"access_method_id" => method_id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, records} <-
           Targets.page_bmc_secrets_for_method(method_id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, records, &BMCSetupJSON.secret/1)
    end
  end

  def secrets_create(conn, %{"access_method_id" => method_id, "bmc_secret" => input}) do
    with {:ok, record} <-
           Targets.create_bmc_secret(method_id, input["name"], input["value"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, BMCSetupJSON.secret(record), :created)
    end
  end

  def secrets_create(_conn, _params), do: {:error, :bad_request}

  def secrets_show(conn, %{"id" => id}) do
    with {:ok, record} <- Targets.get_bmc_secret(id, actor: conn.assigns.current_user) do
      Response.data(conn, BMCSetupJSON.secret(record))
    end
  end

  def secrets_update(conn, %{"id" => id, "bmc_secret" => input}) do
    update(
      conn,
      id,
      input,
      @secret_fields,
      &Targets.get_bmc_secret/2,
      &Targets.update_bmc_secret/4,
      &BMCSetupJSON.secret/1
    )
  end

  def secrets_update(_conn, _params), do: {:error, :bad_request}

  def secrets_deactivate(conn, %{"id" => id, "bmc_secret" => input}) do
    deactivate(
      conn,
      id,
      input,
      &Targets.get_bmc_secret/2,
      &Targets.deactivate_bmc_secret/3,
      &BMCSetupJSON.secret/1
    )
  end

  def secrets_deactivate(_conn, _params), do: {:error, :bad_request}

  defp update(conn, id, input, fields, get, change, serialize) do
    with {:ok, revision} <- Map.fetch(input, "expected_revision"),
         attrs when map_size(attrs) > 0 <- attributes(input, fields),
         {:ok, record} <- get.(id, actor: conn.assigns.current_user),
         {:ok, updated} <- change.(record, revision, attrs, actor: conn.assigns.current_user) do
      Response.data(conn, serialize.(updated))
    else
      :error -> {:error, :bad_request}
      attrs when is_map(attrs) -> {:error, :bad_request}
      error -> error
    end
  end

  defp deactivate(conn, id, input, get, change, serialize) do
    with {:ok, revision} <- Map.fetch(input, "expected_revision"),
         {:ok, record} <- get.(id, actor: conn.assigns.current_user),
         {:ok, updated} <- change.(record, revision, actor: conn.assigns.current_user) do
      Response.data(conn, serialize.(updated))
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
