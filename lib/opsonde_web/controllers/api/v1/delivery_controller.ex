defmodule OpsondeWeb.API.V1.DeliveryController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Notifications
  alias OpsondeWeb.API.{Pagination, Response, Schemas}
  alias OpsondeWeb.API.V1.{OutcomeJSON, OutcomeSchemas}

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

  tags ["Deliveries"]

  operation :index,
    operation_id: "listDeliveries",
    summary: "List Report deliveries",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Delivery page", "application/json", OutcomeSchemas.ref("DeliveryPage")}] ++
        @list_errors

  operation :show,
    operation_id: "getDelivery",
    summary: "Get a Report delivery",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Delivery", "application/json", OutcomeSchemas.ref("DeliveryResponse")}] ++
        @show_errors

  operation :create,
    operation_id: "createDelivery",
    summary: "Enqueue a Report delivery",
    request_body:
      {"Delivery", "application/json", OutcomeSchemas.ref("CreateDeliveryRequest"),
       required: true},
    responses:
      [accepted: {"Delivery queued", "application/json", OutcomeSchemas.ref("DeliveryResponse")}] ++
        Schemas.errors([
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
         {:ok, deliveries} <-
           Notifications.page_deliveries(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, deliveries, &OutcomeJSON.delivery/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, delivery} <- Notifications.get_delivery(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.delivery(delivery))
    end
  end

  def create(conn, %{"delivery" => input}) do
    with {:ok, delivery} <-
           Notifications.enqueue_delivery(
             input["report_id"],
             input["report_revision"],
             input["provider_id"],
             input["provider_revision"],
             input["idempotency_key"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.delivery(delivery), :accepted)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}
end
