defmodule OpsondeWeb.API.V1.ReportController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Reports
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.OutcomeJSON

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, reports} <- Reports.page_reports(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, reports, &OutcomeJSON.report/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, report} <- Reports.get_report(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.report(report))
    end
  end

  def generate(
        conn,
        %{"case_id" => case_id, "report" => %{"expected_case_revision" => revision}}
      ) do
    with {:ok, report} <-
           Reports.generate_report(case_id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.report(report), :created)
    end
  end

  def generate(_conn, _params), do: {:error, :bad_request}
end
