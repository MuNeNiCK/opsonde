defmodule OpsondeWeb.API.V1.ProposalController do
  use OpsondeWeb, :controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.Response
  alias OpsondeWeb.API.V1.WorkflowJSON

  def show(conn, %{"id" => id}) do
    with {:ok, proposal} <- Cases.get_proposal(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.proposal(proposal))
    end
  end

  def decide(
        conn,
        %{
          "id" => id,
          "proposal" => %{
            "expected_revision" => revision,
            "proposal_digest" => digest,
            "decision" => decision,
            "reason" => reason
          }
        }
      ) do
    with {:ok, proposal} <-
           Cases.decide_proposal(id, revision, digest, decision, reason,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.proposal(proposal))
    end
  end

  def decide(_conn, _params), do: {:error, :bad_request}
end
