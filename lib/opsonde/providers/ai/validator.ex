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

      review_exhausted?(request.budget) ->
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
      request.alert_state in [:firing, :recovered, :not_applicable] and
      request.report_language in [:en, :ja] and
      valid_budget?(request.budget) and
      valid_disclosure?(request.disclosure) and valid_selected_target?(request) and
      valid_resolver_items?(request)
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
  defp review_exhausted?(budget), do: budget.remaining_tokens == 0

  defp valid_disclosure?(%AI.Disclosure{} = disclosure) do
    limits = AI.resolver_disclosure_limits()

    is_integer(disclosure.max_items) and disclosure.max_items >= 0 and
      disclosure.max_items <= limits.max_items and
      is_integer(disclosure.max_bytes) and disclosure.max_bytes >= 0 and
      disclosure.max_bytes <= limits.max_bytes and
      is_list(disclosure.allowed_target_ids) and
      length(disclosure.allowed_target_ids) <= limits.max_items and
      Enum.all?(disclosure.allowed_target_ids, &bounded_identifier?/1) and
      unique?(disclosure.allowed_target_ids) and
      is_list(disclosure.allowed_evidence_kinds) and
      length(disclosure.allowed_evidence_kinds) <= limits.max_items and
      Enum.all?(disclosure.allowed_evidence_kinds, &bounded_kind?/1) and
      encoded_size(%{}, [disclosure]) <= limits.max_bytes
  end

  defp valid_disclosure?(_disclosure), do: false

  defp valid_resolver_items?(request) do
    if Enum.all?(
         [
           request.evidence,
           request.target_candidates,
           request.observation_results,
           request.target_relations,
           request.observation_tools,
           request.proposal_tools
         ],
         &is_list/1
       ) do
      valid? =
        Enum.all?(request.evidence, &valid_evidence?/1) and
          Enum.all?(request.target_candidates, &valid_candidate?/1) and
          Enum.all?(request.observation_results, &valid_observation_result?/1) and
          Enum.all?(request.target_relations, &valid_relation?/1) and
          Enum.all?(request.observation_tools, &valid_tool?/1) and
          Enum.all?(request.proposal_tools, &valid_proposal_tool?/1)

      if valid? do
        evidence_ids = Enum.map(request.evidence, & &1.id)
        candidate_ids = Enum.map(request.target_candidates, & &1.id)
        result_ids = Enum.map(request.observation_results, & &1.id)
        relation_ids = Enum.map(request.target_relations, & &1.id)
        tool_ids = Enum.map(request.observation_tools ++ request.proposal_tools, & &1.id)

        unique?(evidence_ids ++ result_ids ++ relation_ids) and unique?(candidate_ids) and
          unique?(tool_ids) and valid_preselection_tools?(request)
      else
        false
      end
    else
      false
    end
  end

  defp valid_evidence?(%AI.Evidence{id: id, kind: kind, target_id: target_id}),
    do: nonempty?(id) and bounded_kind?(kind) and (is_nil(target_id) or nonempty?(target_id))

  defp valid_evidence?(_evidence), do: false

  defp valid_candidate?(%AI.TargetCandidate{} = candidate),
    do:
      nonempty?(candidate.id) and positive?(candidate.revision) and nonempty?(candidate.name) and
        nonempty?(candidate.kind) and nonempty?(candidate.platform) and is_map(candidate.facts)

  defp valid_candidate?(_candidate), do: false

  defp valid_observation_result?(%AI.ObservationResult{} = result),
    do:
      nonempty?(result.id) and nonempty?(result.tool_id) and nonempty?(result.target_id) and
        bounded_kind?(result.kind) and is_atom(result.status)

  defp valid_observation_result?(_result), do: false

  defp valid_relation?(%AI.TargetRelation{} = relation),
    do:
      nonempty?(relation.id) and positive?(relation.revision) and
        valid_candidate?(relation.source_target) and
        valid_candidate?(relation.destination_target) and
        relation.source_target.id != relation.destination_target.id and
        bounded_kind?(relation.kind) and is_map(relation.attributes)

  defp valid_relation?(_relation), do: false

  defp valid_tool?(%AI.ObservationTool{} = tool),
    do:
      valid_exact_tool?(tool) and nonempty?(tool.description) and
        valid_input_schema?(tool.input_schema)

  defp valid_tool?(_tool), do: false

  defp valid_proposal_tool?(%AI.ProposalTool{} = tool),
    do:
      valid_exact_tool?(tool) and nonempty?(tool.description) and
        valid_input_schema?(tool.input_schema)

  defp valid_proposal_tool?(_tool), do: false

  defp disclosed?(request) do
    items = AI.resolver_disclosure_items(request)

    disclosure = request.disclosure

    length(items) <= disclosure.max_items and
      evidence_allowed?(request.evidence, disclosure) and
      candidates_allowed?(request.target_candidates, disclosure) and
      results_allowed?(request.observation_results, disclosure) and
      relations_allowed?(request.target_relations, disclosure) and
      tools_allowed?(request.observation_tools, request.proposal_tools, disclosure) and
      AI.resolver_disclosure_size(request) <= disclosure.max_bytes
  end

  defp candidates_allowed?(candidates, disclosure) do
    Enum.all?(candidates, &(&1.id in disclosure.allowed_target_ids))
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
      relation.source_target.id in disclosure.allowed_target_ids and
        relation.destination_target.id in disclosure.allowed_target_ids
    end)
  end

  defp tools_allowed?(observation_tools, proposal_tools, disclosure) do
    Enum.all?(observation_tools ++ proposal_tools, fn tool ->
      tool.target_id in disclosure.allowed_target_ids
    end)
  end

  defp encoded_size(context, items) do
    encoded_items = Enum.map(items, &plain_value/1)

    case Jason.encode(%{context: context, items: encoded_items}) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  defp review_size(request) do
    encoded = %{
      objective: request.objective,
      policy_summary: request.policy_summary,
      proposal: plain_value(request.proposal),
      cited_evidence: Enum.map(request.cited_evidence, &plain_value/1)
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
         true <- bounded_string?(decision.reason, 1_000),
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
    tool = Enum.find(request.observation_tools, &(&1.id == choice.tool_id))

    if request.budget.remaining_target_requests > 0 and not is_nil(tool) and
         valid_tool_input?(choice.selectors, choice.parameters, tool.input_schema) and
         bounded_string?(choice.reason, 500) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI observation choice is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.TargetSearch{} = search, request) do
    if request.budget.remaining_target_requests > 0 and bounded_string?(search.query, 200) and
         bounded_string?(search.reason, 500) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target search is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.TargetSelection{} = selection, request) do
    evidence_ids = available_evidence_ids(request)

    candidate =
      Enum.find(request.target_candidates, fn candidate ->
        candidate.id == selection.target_id and
          candidate.revision == selection.target_revision
      end)

    if not is_nil(candidate) and bounded_string?(selection.reason, 500) and
         nonempty_list?(selection.evidence_ids) and
         unique?(selection.evidence_ids) and
         Enum.all?(selection.evidence_ids, &(&1 in evidence_ids)) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target selection is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.TargetTraversal{} = traversal, request) do
    evidence_ids = available_evidence_ids(request)

    relationship =
      Enum.find(request.target_relations, fn relationship ->
        relationship.id == traversal.relationship_id and
          relationship.revision == traversal.relationship_revision
      end)

    if request.budget.remaining_related_targets > 0 and not is_nil(relationship) and
         traversal_destination?(relationship, request.selected_target_id, traversal) and
         bounded_string?(traversal.reason, 500) and
         nonempty_list?(traversal.evidence_ids) and unique?(traversal.evidence_ids) and
         Enum.all?(traversal.evidence_ids, &(&1 in evidence_ids)) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target traversal is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.Proposal{} = proposal, request) do
    evidence_ids = available_evidence_ids(request)

    case Enum.find(request.proposal_tools, &(&1.id == proposal.tool_id)) do
      %AI.ProposalTool{} = tool ->
        if request.budget.remaining_effects > 0 and
             valid_tool_input?(proposal.selectors, proposal.parameters, tool.input_schema) and
             exact_proposal?(proposal, tool) and is_map(proposal.expected_result) and
             valid_verification_intent?(
               proposal.verification_intent,
               request.observation_tools ++ request.proposal_tools
             ) and
             bounded_string?(proposal.reason, 500) and
             nonempty_list?(proposal.evidence_ids) and
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
    if request.alert_state in [:recovered, :not_applicable] and
         bounded_string?(conclusion.reason, 500) and
         nonempty_list?(conclusion.evidence_ids) and unique?(conclusion.evidence_ids) and
         Enum.all?(conclusion.evidence_ids, &(&1 in available_evidence_ids(request))) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI recovery conclusion is invalid")}
    end
  end

  defp validate_resolver_intent(%AI.Handoff{} = handoff, _request) do
    if bounded_string?(handoff.reason, 500) and bounded_string?(handoff.required_input, 1_000),
      do: :ok,
      else: {:error, ai_error(:invalid_output, "AI handoff is invalid")}
  end

  defp validate_resolver_intent(_intent, _request),
    do: {:error, ai_error(:invalid_output, "AI Resolver intent is invalid")}

  defp traversal_destination?(relationship, selected_target_id, traversal) do
    next_target =
      cond do
        relationship.source_target.id == selected_target_id ->
          relationship.destination_target

        relationship.destination_target.id == selected_target_id ->
          relationship.source_target

        true ->
          nil
      end

    not is_nil(next_target) and next_target.id == traversal.next_target_id and
      next_target.revision == traversal.next_target_revision
  end

  defp valid_review_proposal?(%AI.Proposal{} = proposal, evidence_ids) do
    nonempty?(proposal.tool_id) and nonempty?(proposal.target_id) and
      positive?(proposal.target_revision) and nonempty?(proposal.access_method_id) and
      positive?(proposal.access_method_revision) and nonempty?(proposal.capability) and
      nonempty?(proposal.operation) and is_map(proposal.parameters) and
      bounded_string?(proposal.reason, 500) and is_map(proposal.selectors) and
      nonempty_list?(proposal.evidence_ids) and
      unique?(proposal.evidence_ids) and
      Enum.all?(proposal.evidence_ids, &(&1 in evidence_ids)) and
      is_map(proposal.expected_result) and
      valid_verification_intent?(proposal.verification_intent)
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

  defp valid_exact_tool?(tool) do
    nonempty?(tool.id) and nonempty?(tool.target_id) and positive?(tool.target_revision) and
      nonempty?(tool.access_method_id) and positive?(tool.access_method_revision) and
      nonempty?(tool.provider_id) and positive?(tool.provider_revision) and
      nonempty?(tool.capability) and nonempty?(tool.operation)
  end

  defp valid_selected_target?(request) do
    (is_nil(request.selected_target_id) and is_nil(request.selected_target_revision)) or
      (nonempty?(request.selected_target_id) and positive?(request.selected_target_revision) and
         request.selected_target_id in request.disclosure.allowed_target_ids)
  end

  defp valid_preselection_tools?(%{selected_target_id: nil} = request) do
    request.observation_tools == [] and request.proposal_tools == [] and
      request.target_relations == []
  end

  defp valid_preselection_tools?(_request), do: true

  defp exact_proposal?(proposal, tool) do
    proposal.target_id == tool.target_id and proposal.target_revision == tool.target_revision and
      proposal.access_method_id == tool.access_method_id and
      proposal.access_method_revision == tool.access_method_revision and
      proposal.capability == tool.capability and proposal.operation == tool.operation
  end

  defp valid_verification_intent?(%AI.VerificationIntent{} = intent, tools) do
    case Enum.find(tools, &(&1.id == intent.tool_id)) do
      %tool_module{} = tool when tool_module in [AI.ObservationTool, AI.ProposalTool] ->
        valid_verification_intent?(intent) and
          valid_tool_input?(intent.selectors, intent.parameters, tool.input_schema)

      _tool ->
        false
    end
  end

  defp valid_verification_intent?(_intent, _tools), do: false

  defp valid_verification_intent?(%AI.VerificationIntent{} = intent),
    do:
      nonempty?(intent.tool_id) and is_map(intent.selectors) and is_map(intent.parameters) and
        is_map(intent.expected_result)

  defp valid_verification_intent?(_intent), do: false

  defp valid_input_schema?(schema) when is_map(schema) do
    match?({:ok, %JSV.Root{}}, JSV.build(schema, warnings: :silent))
  end

  defp valid_input_schema?(_schema), do: false

  defp valid_tool_input?(selectors, parameters, schema)
       when is_map(selectors) and is_map(parameters) do
    with {:ok, root} <- JSV.build(schema, warnings: :silent),
         {:ok, _validated} <-
           JSV.validate(
             %{"selectors" => selectors, "parameters" => parameters},
             root,
             cast: false
           ) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_tool_input?(_selectors, _parameters, _schema), do: false

  defp plain_value(%_{} = value), do: value |> Map.from_struct() |> plain_value()

  defp plain_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, plain_value(nested)} end)

  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  defp plain_value(value), do: value

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

  defp bounded_string?(value, max_bytes),
    do: nonempty?(value) and byte_size(value) <= max_bytes

  defp bounded_kind?(value), do: bounded_string?(value, 120)
  defp bounded_identifier?(value), do: bounded_string?(value, 500)

  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
