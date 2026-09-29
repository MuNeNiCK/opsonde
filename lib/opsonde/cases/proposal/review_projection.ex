defmodule Opsonde.Cases.Proposal.ReviewProjection do
  @moduledoc false

  alias Opsonde.{Cases, Targets}
  alias Opsonde.Cases.Evidence.ReviewerEvidence, as: ReviewerEvidence
  alias Opsonde.Cases.Case.ConditionContext, as: ConditionContext
  alias Opsonde.Providers.AI

  def build(proposal_id, selection, retry_context \\ nil)

  def build(proposal_id, %AI.Selection{role: :reviewer} = selection, retry_context) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false),
         :ok <- eligible(proposal, incident, run),
         {:ok, {conditions, _recovery_ids}} <-
           ConditionContext.current_condition_context(incident),
         {:ok, true} <- ConditionContext.current?(incident, proposal.source_turn_id),
         {:ok, true} <-
           ConditionContext.affected_current?(
             incident,
             proposal.request_kind,
             proposal.affected_conditions,
             proposal.evidence_ids,
             proposal
           ),
         {:ok, source_evidence} <- source_evidence(incident),
         {:ok, evidence} <- cited_evidence(proposal),
         {:ok, context_evidence} <-
           ReviewerEvidence.recent(
             incident.id,
             proposal.target_id,
             Enum.map(evidence, & &1.id)
           ),
         {:ok, target_relations} <- target_relations(incident, proposal) do
      request = %AI.ReviewRequest{
        provider_revision: selection.provider_revision,
        session_id: "reviewer:#{proposal.id}",
        resolver_session_id: "resolver:#{run.id}",
        case_id: incident.id,
        objective: objective(incident),
        report_language: incident.report_language,
        policy_summary: policy_summary(proposal),
        proposal: review_proposal(proposal),
        conditions: conditions,
        source_evidence: source_evidence,
        cited_evidence: evidence,
        context_evidence: context_evidence,
        initial_target_id: incident.initial_target_id,
        target_relations: target_relations,
        retry_context: retry_context,
        budget: budget(run)
      }

      case AI.Validator.validate_request(:review, request) do
        :ok -> {:ok, request}
        {:error, _error} = error -> error
      end
    end
  end

  def build(_proposal_id, _selection, _retry_context),
    do: {:error, "Reviewer AI selection is invalid"}

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
        {:ok, evidence} when evidence.case_id == proposal.case_id ->
          item = %AI.Evidence{
            id: evidence.id,
            kind: evidence.kind,
            target_id: evidence_target(evidence.content),
            observed_at_us: DateTime.to_unix(evidence.observed_at, :microsecond),
            content: ReviewerEvidence.project_content(evidence.content)
          }

          {:cont, {:ok, loaded ++ [item]}}

        _unavailable ->
          {:halt, {:error, "Proposal Evidence is unavailable"}}
      end
    end)
  end

  defp source_evidence(incident) do
    with {:ok, evidence} <- Cases.signal_context_evidence(incident.id, authorize?: false) do
      {:ok,
       evidence
       |> Enum.map(fn item ->
         %AI.Evidence{
           id: item.id,
           kind: item.kind,
           target_id: nil,
           observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
           content: item.content
         }
       end)}
    end
  end

  defp target_relations(incident, proposal) do
    with {:ok, initial} <- initial_target_relations(incident, proposal),
         {:ok, claimed} <- claimed_target_relations(proposal),
         {:ok, projected} <-
           project_relations(Enum.uniq_by(initial ++ claimed, & &1.id), proposal) do
      {:ok, projected}
    end
  end

  defp initial_target_relations(%{initial_target_id: nil}, _proposal), do: {:ok, []}
  defp initial_target_relations(%{initial_target_id: id}, %{target_id: id}), do: {:ok, []}

  defp initial_target_relations(%{initial_target_id: id}, proposal) do
    with {:ok, adjacent} <-
           Targets.adjacent_relationships_for_traversal(id, authorize?: false) do
      {:ok,
       Enum.filter(adjacent, fn relation ->
         proposal.target_id in [relation.source_target_id, relation.destination_target_id]
       end)}
    end
  end

  defp claimed_target_relations(proposal) do
    proposal.affected_conditions
    |> Enum.filter(&Map.has_key?(&1, "relationship_id"))
    |> Enum.uniq_by(& &1["relationship_id"])
    |> Enum.reduce_while({:ok, []}, fn claim, {:ok, relations} ->
      case Targets.load_relationship_for_traversal(
             claim["relationship_id"],
             claim["relationship_revision"],
             authorize?: false
           ) do
        {:ok, relation} -> {:cont, {:ok, [relation | relations]}}
        _changed -> {:halt, {:error, "Reviewer Target relationship changed"}}
      end
    end)
  end

  defp project_relations([], _proposal), do: {:ok, []}

  defp project_relations(relations, proposal) do
    ids =
      relations
      |> Enum.flat_map(&[&1.source_target_id, &1.destination_target_id])
      |> Enum.uniq()

    with {:ok, candidates} <- relation_targets(ids),
         %{revision: revision} <- Map.get(candidates, proposal.target_id),
         true <- revision == proposal.target_revision do
      {:ok,
       Enum.map(relations, fn relation ->
         %AI.TargetRelation{
           id: relation.id,
           revision: relation.revision,
           source_target: target_candidate(candidates[relation.source_target_id]),
           destination_target: target_candidate(candidates[relation.destination_target_id]),
           kind: relation.kind,
           attributes: relation.facts
         }
       end)}
    else
      _changed -> {:error, "Reviewer Target relationship changed"}
    end
  end

  defp relation_targets(ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, targets} ->
      case Targets.get_target(id, authorize?: false) do
        {:ok, %{active: true} = target} ->
          {:cont, {:ok, Map.put(targets, id, target)}}

        _changed ->
          {:halt, {:error, "Reviewer Target relationship changed"}}
      end
    end)
  end

  defp target_candidate(target) do
    %AI.TargetCandidate{
      id: target.id,
      revision: target.revision,
      name: target.name,
      kind: target.kind,
      type_id: target.type_id,
      facts: target.facts
    }
  end

  defp objective(incident) do
    Jason.encode!(%{
      "case_title" => incident.title,
      "initial_context" => incident.initial_context
    })
    |> String.slice(0, 8_000)
  end

  defp evidence_target(%{"target_id" => target_id}) when is_binary(target_id), do: target_id
  defp evidence_target(_content), do: nil

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
      affected_conditions: proposal.affected_conditions,
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
