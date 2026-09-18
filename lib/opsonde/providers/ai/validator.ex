defmodule Opsonde.Providers.AI.Validator do
  @moduledoc false

  alias Opsonde.Providers.AI

  @max_output_bytes 65_536
  @max_review_items 100
  @max_review_bytes 65_536

  def validate_request(:resolve, %AI.ResolverRequest{} = request) do
    cond do
      not valid_resolver_request?(request) ->
        {:error, ai_error(:invalid_input, "AI Resolver request is invalid")}

      exhausted?(request.budget) ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      not disclosed?(request) ->
        {:error, ai_error(:disclosure_limit, "AI disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  def validate_request(:review, %AI.ReviewRequest{} = request) do
    cond do
      not valid_review_request?(request) ->
        {:error, ai_error(:invalid_input, "AI Reviewer request is invalid")}

      exhausted?(request.budget) ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      review_size(request) > @max_review_bytes ->
        {:error, ai_error(:disclosure_limit, "AI Reviewer disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  def validate_request(_operation, _request),
    do: {:error, ai_error(:invalid_input, "AI request is invalid")}

  defp valid_resolver_request?(request) do
    positive?(request.provider_revision) and nonempty?(request.session_id) and
      nonempty?(request.case_id) and positive?(request.turn) and nonempty?(request.objective) and
      request.alert_state in [:firing, :recovered] and valid_budget?(request.budget) and
      valid_disclosure?(request.disclosure) and valid_resolver_items?(request)
  end

  defp valid_review_request?(%AI.ReviewRequest{cited_evidence: cited_evidence} = request)
       when is_list(cited_evidence) do
    if length(cited_evidence) <= @max_review_items and
         Enum.all?(cited_evidence, &valid_evidence?/1) do
      evidence_ids = Enum.map(cited_evidence, & &1.id)

      positive?(request.provider_revision) and nonempty?(request.session_id) and
        nonempty?(request.resolver_session_id) and
        request.session_id != request.resolver_session_id and nonempty?(request.case_id) and
        nonempty?(request.objective) and nonempty?(request.policy_summary) and
        valid_budget?(request.budget) and unique?(evidence_ids) and
        valid_review_proposal?(request.proposal, evidence_ids)
    else
      false
    end
  end

  defp valid_review_request?(_request), do: false

  defp valid_budget?(%AI.Budget{} = budget) do
    Enum.all?(
      [
        budget.remaining_turns,
        budget.remaining_tokens,
        budget.remaining_target_requests,
        budget.remaining_effects,
        budget.remaining_related_targets
      ],
      &(is_integer(&1) and &1 >= 0)
    )
  end

  defp valid_budget?(_budget), do: false

  defp exhausted?(budget), do: budget.remaining_turns == 0 or budget.remaining_tokens == 0

  defp valid_disclosure?(%AI.Disclosure{} = disclosure) do
    is_integer(disclosure.max_items) and disclosure.max_items >= 0 and
      is_integer(disclosure.max_bytes) and disclosure.max_bytes >= 0 and
      is_list(disclosure.allowed_target_ids) and
      Enum.all?(disclosure.allowed_target_ids, &nonempty?/1) and
      unique?(disclosure.allowed_target_ids) and
      is_list(disclosure.allowed_evidence_kinds) and
      Enum.all?(disclosure.allowed_evidence_kinds, &is_atom/1)
  end

  defp valid_disclosure?(_disclosure), do: false

  defp valid_resolver_items?(request) do
    if Enum.all?(
         [
           request.evidence,
           request.observation_results,
           request.target_relations,
           request.observation_tools,
           request.proposal_tools
         ],
         &is_list/1
       ) do
      valid? =
        Enum.all?(request.evidence, &valid_evidence?/1) and
          Enum.all?(request.observation_results, &valid_observation_result?/1) and
          Enum.all?(request.target_relations, &valid_relation?/1) and
          Enum.all?(request.observation_tools, &valid_tool?/1) and
          Enum.all?(request.proposal_tools, &valid_proposal_tool?/1)

      if valid? do
        evidence_ids = Enum.map(request.evidence, & &1.id)
        result_ids = Enum.map(request.observation_results, & &1.id)
        relation_ids = Enum.map(request.target_relations, & &1.id)
        tool_ids = Enum.map(request.observation_tools ++ request.proposal_tools, & &1.id)

        unique?(evidence_ids ++ result_ids ++ relation_ids) and unique?(tool_ids)
      else
        false
      end
    else
      false
    end
  end

  defp valid_evidence?(%AI.Evidence{id: id, kind: kind, target_id: target_id}),
    do: nonempty?(id) and is_atom(kind) and (is_nil(target_id) or nonempty?(target_id))

  defp valid_evidence?(_evidence), do: false

  defp valid_observation_result?(%AI.ObservationResult{} = result),
    do:
      nonempty?(result.id) and nonempty?(result.tool_id) and nonempty?(result.target_id) and
        is_atom(result.kind) and is_atom(result.status)

  defp valid_observation_result?(_result), do: false

  defp valid_relation?(%AI.TargetRelation{} = relation),
    do:
      nonempty?(relation.id) and nonempty?(relation.source_target_id) and
        nonempty?(relation.target_target_id) and is_atom(relation.kind) and
        is_map(relation.attributes)

  defp valid_relation?(_relation), do: false

  defp valid_tool?(%AI.ObservationTool{} = tool),
    do:
      nonempty?(tool.id) and nonempty?(tool.target_id) and is_atom(tool.capability) and
        nonempty?(tool.description) and is_map(tool.input_schema)

  defp valid_tool?(_tool), do: false

  defp valid_proposal_tool?(%AI.ProposalTool{} = tool),
    do:
      nonempty?(tool.id) and nonempty?(tool.target_id) and is_atom(tool.capability) and
        nonempty?(tool.description) and is_map(tool.input_schema)

  defp valid_proposal_tool?(_tool), do: false

  defp disclosed?(request) do
    items =
      request.evidence ++
        request.observation_results ++
        request.target_relations ++
        request.observation_tools ++ request.proposal_tools

    disclosure = request.disclosure

    length(items) <= disclosure.max_items and
      evidence_allowed?(request.evidence, disclosure) and
      results_allowed?(request.observation_results, disclosure) and
      relations_allowed?(request.target_relations, disclosure) and
      tools_allowed?(request.observation_tools, request.proposal_tools, disclosure) and
      encoded_size(%{objective: request.objective, alert_state: request.alert_state}, items) <=
        disclosure.max_bytes
  end

  defp evidence_allowed?(evidence, disclosure) do
    Enum.all?(evidence, fn item ->
      item.kind in disclosure.allowed_evidence_kinds and
        (is_nil(item.target_id) or item.target_id in disclosure.allowed_target_ids)
    end)
  end

  defp results_allowed?(results, disclosure) do
    Enum.all?(results, fn result ->
      result.kind in disclosure.allowed_evidence_kinds and
        result.target_id in disclosure.allowed_target_ids
    end)
  end

  defp relations_allowed?(relations, disclosure) do
    Enum.all?(relations, fn relation ->
      relation.source_target_id in disclosure.allowed_target_ids and
        relation.target_target_id in disclosure.allowed_target_ids
    end)
  end

  defp tools_allowed?(observation_tools, proposal_tools, disclosure) do
    Enum.all?(observation_tools ++ proposal_tools, fn tool ->
      tool.target_id in disclosure.allowed_target_ids
    end)
  end

  defp encoded_size(context, items) do
    encoded_items =
      Enum.map(items, fn
        %_{} = item -> Map.from_struct(item)
        item -> item
      end)

    case Jason.encode(%{context: context, items: encoded_items}) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  defp review_size(request) do
    encoded = %{
      objective: request.objective,
      policy_summary: request.policy_summary,
      proposal: Map.from_struct(request.proposal),
      cited_evidence: Enum.map(request.cited_evidence, &Map.from_struct/1)
    }

    case Jason.encode(encoded) do
      {:ok, value} -> byte_size(value)
      {:error, _error} -> :infinity
    end
  end

  def validate_decision(:resolve, %AI.ResolverDecision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget),
         :ok <- validate_resolver_intent(decision.intent, request),
         true <- encoded_size(%{}, [decision.intent]) <= @max_output_bytes do
      :ok
    else
      false -> {:error, ai_error(:invalid_output, "AI Resolver output is too large")}
      {:error, _error} = error -> error
    end
  end

  def validate_decision(:review, %AI.ReviewDecision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget),
         true <- decision.verdict in [:approved, :rejected, :needs_human],
         true <- nonempty?(decision.reason),
         true <- review_decision_size(decision) <= @max_output_bytes do
      :ok
    else
      false -> {:error, ai_error(:invalid_output, "AI Reviewer output is invalid")}
      {:error, _error} = error -> error
    end
  end

  def validate_decision(_operation, _decision, _request),
    do: {:error, ai_error(:invalid_output, "AI output is invalid")}

  defp validate_resolver_intent(%AI.ObservationChoice{} = choice, request) do
    tool_ids = Enum.map(request.observation_tools, & &1.id)

    if request.budget.remaining_target_requests > 0 and choice.tool_id in tool_ids and
         is_map(choice.parameters) and nonempty?(choice.reason) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI observation choice is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.Proposal{} = proposal, request) do
    evidence_ids = available_evidence_ids(request)

    case Enum.find(request.proposal_tools, &(&1.id == proposal.tool_id)) do
      %AI.ProposalTool{target_id: target_id, capability: capability}
      when target_id == proposal.target_id and capability == proposal.capability ->
        if request.budget.remaining_effects > 0 and is_map(proposal.parameters) and
             is_map(proposal.expected_result) and is_map(proposal.verification_intent) and
             nonempty?(proposal.reason) and nonempty_list?(proposal.evidence_ids) and
             unique?(proposal.evidence_ids) and
             Enum.all?(proposal.evidence_ids, &(&1 in evidence_ids)) do
          :ok
        else
          {:error, ai_error(:invalid_output, "AI Proposal is invalid")}
        end

      _tool ->
        {:error, ai_error(:invalid_output, "AI Proposal is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.RecoveryConclusion{} = conclusion, request) do
    if request.alert_state == :recovered and nonempty?(conclusion.reason) and
         nonempty_list?(conclusion.evidence_ids) and unique?(conclusion.evidence_ids) and
         Enum.all?(conclusion.evidence_ids, &(&1 in available_evidence_ids(request))) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI recovery conclusion is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.Handoff{} = handoff, _request) do
    if nonempty?(handoff.reason) and nonempty?(handoff.required_input),
      do: :ok,
      else: {:error, ai_error(:invalid_output, "AI handoff is invalid")}
  end

  defp validate_resolver_intent(_intent, _request),
    do: {:error, ai_error(:invalid_output, "AI Resolver intent is invalid")}

  defp valid_review_proposal?(%AI.Proposal{} = proposal, evidence_ids) do
    nonempty?(proposal.tool_id) and nonempty?(proposal.target_id) and is_atom(proposal.capability) and
      is_map(proposal.parameters) and nonempty?(proposal.reason) and
      nonempty_list?(proposal.evidence_ids) and unique?(proposal.evidence_ids) and
      Enum.all?(proposal.evidence_ids, &(&1 in evidence_ids)) and
      is_map(proposal.expected_result) and is_map(proposal.verification_intent)
  end

  defp valid_review_proposal?(_proposal, _evidence_ids), do: false

  defp review_decision_size(decision) do
    case Jason.encode(%{
           verdict: decision.verdict,
           reason: decision.reason,
           usage: Map.from_struct(decision.usage)
         }) do
      {:ok, value} -> byte_size(value)
      {:error, _error} -> :infinity
    end
  end

  defp available_evidence_ids(request),
    do: Enum.map(request.evidence ++ request.observation_results, & &1.id)

  defp validate_usage(%AI.Usage{input_tokens: input, output_tokens: output}, budget)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    if input + output <= budget.remaining_tokens,
      do: :ok,
      else: {:error, ai_error(:budget_exhausted, "AI token budget was exceeded")}
  end

  defp validate_usage(_usage, _budget),
    do: {:error, ai_error(:invalid_output, "AI token usage is invalid")}

  defp unique?(items), do: length(items) == MapSet.size(MapSet.new(items))
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp nonempty_list?(value), do: is_list(value) and value != []

  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
