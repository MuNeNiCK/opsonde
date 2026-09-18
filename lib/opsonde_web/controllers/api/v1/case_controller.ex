defmodule OpsondeWeb.API.V1.CaseController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.WorkflowJSON

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, cases} <- Cases.page_cases(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, cases, &WorkflowJSON.case_record/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, snapshot} <- Cases.case_reconnect_snapshot(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.snapshot(snapshot))
    end
  end

  def create(conn, %{"case" => input}) do
    with {:ok, incident} <-
           Cases.open_case(
             input["trigger_kind"],
             input["source"],
             input["source_ref"],
             input["title"],
             input["severity"],
             input["alert_state"] || "not_applicable",
             input["initial_context"] || %{},
             input["initial_target_id"],
             input["report_language"] || "en",
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.case_record(incident), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def timeline(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, events} <-
           Cases.page_case_events(id, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, events, &WorkflowJSON.event/1)
    end
  end

  def turns(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_turns(id, &1), &WorkflowJSON.turn/1)
  end

  def evidence(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_evidence(id, &1), &WorkflowJSON.evidence/1)
  end

  def approvals(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_approvals(id, &1), &WorkflowJSON.approval/1)
  end

  def review_decisions(conn, %{"id" => id} = params) do
    page_case_records(
      conn,
      params,
      &Cases.page_case_review_decisions(id, &1),
      &WorkflowJSON.review_decision/1
    )
  end

  def claim(conn, %{"id" => id, "case" => %{"expected_revision" => revision}}) do
    with {:ok, incident} <- Cases.claim_case(id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def claim(_conn, _params), do: {:error, :bad_request}

  def handoff(
        conn,
        %{"id" => id, "case" => %{"expected_revision" => revision, "owner_id" => owner_id}}
      ) do
    with {:ok, incident} <-
           Cases.handoff_case(id, revision, owner_id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def handoff(_conn, _params), do: {:error, :bad_request}

  def cancel(conn, %{"id" => id, "case" => %{"expected_revision" => revision}}) do
    with {:ok, incident} <-
           Cases.request_case_cancellation(id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def cancel(_conn, _params), do: {:error, :bad_request}

  def resume(
        conn,
        %{
          "id" => id,
          "case" =>
            %{
              "expected_case_revision" => case_revision,
              "resolution_run_id" => run_id,
              "expected_run_revision" => run_revision
            } = input
        }
      ) do
    with {:ok, run} <-
           Cases.resume_case(
             id,
             case_revision,
             run_id,
             run_revision,
             input["authority_mode"],
             input["max_elapsed_seconds"],
             input["max_resolver_turns"],
             input["max_target_requests"],
             input["max_effects"],
             input["max_related_targets"],
             input["max_ai_usage_units"],
             input["max_no_progress_turns"],
             input["reason"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.resolution_run(run))
    end
  end

  def resume(_conn, _params), do: {:error, :bad_request}

  defp page_case_records(conn, params, read, serializer) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, records} <- read.(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, records, serializer)
    end
  end
end
