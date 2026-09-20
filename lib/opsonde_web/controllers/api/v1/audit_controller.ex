defmodule OpsondeWeb.API.V1.AuditController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Audits
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
  @write_errors Schemas.errors([
                  :bad_request,
                  :unauthorized,
                  :forbidden,
                  :not_found,
                  :conflict,
                  :unprocessable_entity,
                  :internal_server_error
                ])

  tags ["Audits"]

  operation :schedules,
    operation_id: "listAuditSchedules",
    summary: "List audit schedules",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok: {"Audit-schedule page", "application/json", OutcomeSchemas.ref("AuditSchedulePage")}
      ] ++ @list_errors

  operation :schedule,
    operation_id: "createAuditSchedule",
    summary: "Create an audit schedule",
    request_body:
      {"Audit schedule", "application/json", OutcomeSchemas.ref("CreateAuditScheduleRequest"),
       required: true},
    responses:
      [
        created:
          {"Audit schedule created", "application/json",
           OutcomeSchemas.ref("AuditScheduleResponse")}
      ] ++ @write_errors

  operation :show_schedule,
    operation_id: "getAuditSchedule",
    summary: "Get an audit schedule",
    parameters: Schemas.id_parameter(),
    responses:
      [
        ok: {"Audit schedule", "application/json", OutcomeSchemas.ref("AuditScheduleResponse")}
      ] ++ @show_errors

  operation :deactivate,
    operation_id: "deactivateAuditSchedule",
    summary: "Deactivate an audit schedule",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Audit-schedule revision", "application/json",
       OutcomeSchemas.ref("DeactivateAuditScheduleRequest"), required: true},
    responses:
      [
        ok:
          {"Audit schedule deactivated", "application/json",
           OutcomeSchemas.ref("AuditScheduleResponse")}
      ] ++ @write_errors

  operation :runs,
    operation_id: "listAuditRuns",
    summary: "List audit runs",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Audit-run page", "application/json", OutcomeSchemas.ref("AuditRunPage")}] ++
        @list_errors

  operation :show_run,
    operation_id: "getAuditRun",
    summary: "Get an audit run",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Audit run", "application/json", OutcomeSchemas.ref("AuditRunResponse")}] ++
        @show_errors

  def schedules(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, schedules} <-
           Audits.page_audit_schedules(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, schedules, &OutcomeJSON.audit_schedule/1)
    end
  end

  def schedule(conn, %{"audit_schedule" => input}) do
    with {:ok, schedule} <-
           Audits.schedule_audit(
             input["name"],
             input["objective"],
             input["timezone"],
             input["cron_expression"],
             input["report_language"],
             input["target_ids"] || [],
             input["management_boundary_id"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.audit_schedule(schedule), :created)
    end
  end

  def schedule(_conn, _params), do: {:error, :bad_request}

  def show_schedule(conn, %{"id" => id}) do
    with {:ok, schedule} <- Audits.get_audit_schedule(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.audit_schedule(schedule))
    end
  end

  def deactivate(
        conn,
        %{"id" => id, "audit_schedule" => %{"expected_revision" => revision}}
      ) do
    with {:ok, schedule} <- Audits.get_audit_schedule(id, actor: conn.assigns.current_user),
         {:ok, deactivated} <-
           Audits.deactivate_audit_schedule(schedule, revision, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.audit_schedule(deactivated))
    end
  end

  def deactivate(_conn, _params), do: {:error, :bad_request}

  def runs(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, runs} <- Audits.page_audit_runs(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, runs, &OutcomeJSON.audit_run/1)
    end
  end

  def show_run(conn, %{"id" => id}) do
    with {:ok, run} <- Audits.get_audit_run(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.audit_run(run))
    end
  end
end
