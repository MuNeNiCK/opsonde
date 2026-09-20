defmodule OpsondeWeb.API.V1.SignalReceiptController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Signals
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.OutcomeJSON

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, receipts} <-
           Signals.page_signal_receipts(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, receipts, &OutcomeJSON.receipt/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, receipt} <- Signals.get_signal_receipt(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.receipt(receipt))
    end
  end

  def events(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, events} <-
           Signals.page_signal_events_for_receipt(id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, events, &OutcomeJSON.signal_event/1)
    end
  end
end
