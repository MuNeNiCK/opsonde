defmodule OpsondeWeb.API.V1.ProposalController do
  use OpsondeWeb, :api_controller

  action_fallback OpsondeWeb.API.FallbackController

  alias Opsonde.Cases
  alias OpsondeWeb.API.{Response, Schemas}
  alias OpsondeWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  tags ["Proposals"]

  operation :show,
    operation_id: "getProposal",
    summary: "Get a Proposal",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Proposal", "application/json", WorkflowSchemas.ref("ProposalResponse")}] ++
        Schemas.errors([
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :decide,
    operation_id: "decideProposal",
    summary: "Approve or reject a Proposal",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Proposal decision", "application/json", WorkflowSchemas.ref("DecideProposalRequest"),
       required: true},
    responses:
      [ok: {"Proposal decided", "application/json", WorkflowSchemas.ref("ProposalResponse")}] ++
        Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

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
