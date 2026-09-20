defmodule OpsondeWeb.API.V1.OperationController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.{Response, Schemas}
  alias OpsondeWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  @errors Schemas.errors([
            :unauthorized,
            :forbidden,
            :not_found,
            :unprocessable_entity,
            :internal_server_error
          ])

  tags ["Operations"]

  operation :show,
    operation_id: "getOperation",
    summary: "Get an Operation",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Operation", "application/json", WorkflowSchemas.ref("OperationResponse")}] ++
        @errors

  operation :show_verification,
    operation_id: "getVerificationAttempt",
    summary: "Get a verification attempt",
    parameters: Schemas.id_parameter(),
    responses:
      [
        ok:
          {"Verification attempt", "application/json",
           WorkflowSchemas.ref("VerificationAttemptResponse")}
      ] ++ @errors

  def show(conn, %{"id" => id}) do
    with {:ok, operation} <- Cases.get_operation(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.operation(operation))
    end
  end

  def show_verification(conn, %{"id" => id}) do
    with {:ok, attempt} <-
           Cases.get_verification_attempt(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.verification_attempt(attempt))
    end
  end
end
