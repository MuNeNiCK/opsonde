defmodule OpsondeWeb.API.V1.OperationController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.WorkflowJSON

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
