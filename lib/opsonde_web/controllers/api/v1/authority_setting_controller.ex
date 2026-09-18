defmodule OpsondeWeb.API.V1.AuthoritySettingController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.{Pagination, Response}
  alias OpsondeWeb.API.V1.WorkflowJSON

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, settings} <-
           Cases.page_authority_settings(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, settings, &WorkflowJSON.authority/1)
    end
  end

  def show(conn, _params) do
    with {:ok, setting} <- Cases.current_authority_setting(actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.authority(setting))
    end
  end

  def update(conn, %{"authority_setting" => input}) do
    with {:ok, setting} <-
           Cases.configure_authority_setting(
             input["expected_setting_revision"],
             input["authority_mode"],
             input["signal_automation_enabled"],
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
      Response.data(conn, WorkflowJSON.authority(setting))
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}
end
