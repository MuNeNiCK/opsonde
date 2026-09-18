defmodule OpsondeWeb.API.V1.DeliveryController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Notifications
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.OutcomeJSON

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
