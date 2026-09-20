defmodule OpsondeWeb.API.V1.ReportController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Reports
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

  tags ["Reports"]

  operation :index,
    operation_id: "listReports",
    summary: "List Reports",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Report page", "application/json", OutcomeSchemas.ref("ReportPage")}] ++ @list_errors

  operation :show,
    operation_id: "getReport",
    summary: "Get a Report",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Report", "application/json", OutcomeSchemas.ref("ReportResponse")}] ++ @show_errors

  operation :generate,
    operation_id: "generateCaseReport",
    summary: "Generate an immutable Case Report",
    parameters: Schemas.id_parameter(:case_id),
    request_body:
      {"Case revision", "application/json", OutcomeSchemas.ref("GenerateReportRequest"),
       required: true},
    responses:
      [created: {"Report generated", "application/json", OutcomeSchemas.ref("ReportResponse")}] ++
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
