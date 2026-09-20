defmodule OpsondeWeb.API.V1.AuditController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Audits
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.OutcomeJSON

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
