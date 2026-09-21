defmodule Opsonde.Cases.ReviewProjection do
  @moduledoc false

  alias Opsonde.Cases
  alias Opsonde.Providers.AI

  def build(proposal_id, %AI.Selection{role: :reviewer} = selection) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false),
         :ok <- eligible(proposal, incident, run),
         {:ok, source_evidence} <- source_evidence(incident),
         {:ok, evidence} <- cited_evidence(proposal) do
      request = %AI.ReviewRequest{
        provider_revision: selection.provider_revision,
        session_id: "reviewer:#{proposal.id}",
        resolver_session_id: "resolver:#{run.id}",
        case_id: incident.id,
        objective: objective(incident),
        report_language: incident.report_language,
        policy_summary: policy_summary(proposal),
        proposal: review_proposal(proposal),
        source_evidence: source_evidence,
        cited_evidence: evidence,
        budget: budget(run)
      }

      case AI.Validator.validate_request(:review, request) do
        :ok -> {:ok, request}
        {:error, _error} = error -> error
      end
    end
  end

  def build(_proposal_id, _selection), do: {:error, "Reviewer AI selection is invalid"}

  defp eligible(proposal, incident, run) do
    cond do
      proposal.status != :reviewing or proposal.authority_mode != :auto ->
        {:error, "Proposal is not awaiting Reviewer decision"}

      incident.status != :running or incident.cancel_requested ->
        {:error, "Case resolution is not running"}

      not run.active or run.status != :running or run.generation != proposal.case_generation ->
        {:error, "ResolutionRun is not current"}

      DateTime.compare(DateTime.utc_now(), proposal.expires_at) != :lt ->
        {:error, "Proposal has expired"}

      true ->
        :ok
    end
  end

  defp cited_evidence(proposal) do
    Enum.reduce_while(proposal.evidence_ids, {:ok, []}, fn id, {:ok, loaded} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, evidence}
        when evidence.case_id == proposal.case_id and
               evidence.resolution_run_id == proposal.resolution_run_id ->
          item = %AI.Evidence{
            id: evidence.id,
            kind: evidence.kind,
            target_id: evidence_target(evidence.content, proposal.target_id),
            content: evidence.content
          }

          {:cont, {:ok, loaded ++ [item]}}

        _unavailable ->
          {:halt, {:error, "Proposal Evidence is unavailable"}}
      end
    end)
  end

  defp source_evidence(incident) do
    with {:ok, evidence} <-
           Cases.source_context_evidence(incident.id, incident.source_ref, authorize?: false) do
      {:ok,
       Enum.map(evidence, fn item ->
         %AI.Evidence{
           id: item.id,
           kind: item.kind,
           target_id: nil,
           content: item.content
         }
       end)}
    end
  end

  defp objective(incident) do
    Jason.encode!(%{
      "case_title" => incident.title,
      "initial_context" => incident.initial_context
    })
    |> String.slice(0, 8_000)
  end

  defp evidence_target(%{"target_id" => target_id}, target_id), do: target_id
  defp evidence_target(_content, _target_id), do: nil

  defp review_proposal(proposal) do
    %AI.Proposal{
      tool_id: proposal.tool_id,
      target_id: proposal.target_id,
      target_revision: proposal.target_revision,
      access_method_id: proposal.access_method_id,
      access_method_revision: proposal.access_method_revision,
      request_kind: proposal.request_kind,
      capability: proposal.capability,
      operation: proposal.operation,
      selectors: proposal.selectors,
      parameters: proposal.parameters,
      reason: proposal.reason,
      evidence_ids: proposal.evidence_ids,
      expected_result: proposal.expected_result,
      verification_intent: verification_intent(proposal)
    }
  end

  defp verification_intent(%{request_kind: :observation}), do: nil

  defp verification_intent(proposal) do
    %AI.VerificationIntent{
      tool_id: proposal.verification_intent["tool_id"],
      selectors: proposal.verification_intent["selectors"],
      parameters: proposal.verification_intent["parameters"],
      expected_result: proposal.verification_intent["expected_result"]
    }
  end

  defp policy_summary(proposal) do
    category = proposal.preflight_context["category"] || "cleared"
    revisions = Jason.encode!(proposal.preflight_context["policy_revisions"] || [])

    String.slice(
      "TargetPolicy preflight #{category}; revisions=#{revisions}; mode=#{proposal.authority_mode}; proposal=#{proposal.proposal_digest}",
      0,
      8_000
    )
  end

  defp budget(run) do
    %AI.Budget{
      remaining_turns: max(run.max_resolver_turns - run.turn_count, 0),
      remaining_tokens: max(run.max_ai_usage_units - run.ai_usage_units, 0),
      remaining_target_requests: max(run.max_target_requests - run.target_request_count, 0),
      remaining_effects: max(run.max_effects - run.effect_count, 0),
      remaining_related_targets: max(run.max_related_targets - run.related_target_count, 0)
    }
  end
end
