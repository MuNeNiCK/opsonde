defmodule Opsonde.Providers.Provider.Actions.AI do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{AI, Redactor, Registry}

  @adapter_failures [:failed, :rate_limited, :cancelled]

  @impl true
  def run(input, _opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments

    with :ok <- ensure_not_cancelled(invocation),
         :ok <- validate_request(request),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             provider_id,
             request.provider_revision,
             :ai,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_ai_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider),
         {:ok, decision} <-
           call_adapter(adapter, state, request, invocation, provider.credentials),
         :ok <- validate_decision(decision, request) do
      {:ok, Redactor.value(decision, provider.credentials)}
    end
  rescue
    _error -> {:error, ai_error(:failed, "AI provider failed")}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
  end

  defp validate_request(
         %AI.Request{
           provider_revision: revision,
           budget: %AI.Budget{} = budget,
           disclosure: %AI.Disclosure{} = disclosure
         } = request
       )
       when is_integer(revision) and revision > 0 do
    cond do
      not valid_budget?(budget) ->
        {:error, ai_error(:invalid_input, "AI budget is invalid")}

      budget.remaining_turns == 0 or budget.remaining_tokens == 0 ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      not valid_disclosure?(disclosure) or not valid_items?(request) ->
        {:error, ai_error(:invalid_input, "AI request is invalid")}

      not disclosed?(request) ->
        {:error, ai_error(:disclosure_limit, "AI disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  defp validate_request(_request),
    do: {:error, ai_error(:invalid_input, "AI request is invalid")}

  defp valid_budget?(budget) do
    is_integer(budget.remaining_turns) and budget.remaining_turns >= 0 and
      is_integer(budget.remaining_tokens) and budget.remaining_tokens >= 0
  end

  defp valid_disclosure?(disclosure) do
    is_integer(disclosure.max_items) and disclosure.max_items >= 0 and
      is_integer(disclosure.max_bytes) and disclosure.max_bytes >= 0 and
      is_list(disclosure.allowed_target_ids) and
      Enum.all?(disclosure.allowed_target_ids, &nonempty?/1) and
      is_list(disclosure.allowed_evidence_kinds) and
      Enum.all?(disclosure.allowed_evidence_kinds, &is_atom/1)
  end

  defp valid_items?(request) do
    is_list(request.evidence) and Enum.all?(request.evidence, &valid_evidence?/1) and
      is_list(request.observation_results) and
      Enum.all?(request.observation_results, &valid_observation_result?/1) and
      is_list(request.tools) and Enum.all?(request.tools, &valid_tool?/1)
  end

  defp valid_evidence?(%AI.Evidence{id: id, kind: kind, target_id: target_id}),
    do: nonempty?(id) and is_atom(kind) and (is_nil(target_id) or nonempty?(target_id))

  defp valid_evidence?(_evidence), do: false

  defp valid_observation_result?(%AI.ObservationResult{} = result),
    do:
      nonempty?(result.tool_id) and nonempty?(result.target_id) and is_atom(result.kind) and
        is_atom(result.status)

  defp valid_observation_result?(_result), do: false

  defp valid_tool?(%AI.ObservationTool{} = tool),
    do:
      nonempty?(tool.id) and nonempty?(tool.target_id) and is_atom(tool.capability) and
        is_binary(tool.description) and is_map(tool.input_schema)

  defp valid_tool?(_tool), do: false

  defp disclosed?(request) do
    items = request.evidence ++ request.observation_results ++ request.tools
    disclosure = request.disclosure

    length(items) <= disclosure.max_items and
      evidence_allowed?(request.evidence, disclosure) and
      results_allowed?(request.observation_results, disclosure) and
      tools_allowed?(request.tools, disclosure) and
      encoded_size(items) <= disclosure.max_bytes
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

  defp tools_allowed?(tools, disclosure) do
    ids = Enum.map(tools, & &1.id)

    length(ids) == MapSet.size(MapSet.new(ids)) and
      Enum.all?(tools, &(&1.target_id in disclosure.allowed_target_ids))
  end

  defp encoded_size(items) do
    items = Enum.map(items, &Map.from_struct/1)

    case Jason.encode(items) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  defp fetch_ai_adapter(adapter_type) do
    case Registry.fetch(adapter_type, AI) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _reason} -> {:error, ai_error(:failed, "AI adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, ai_error(:failed, "AI configuration is invalid")}
    end
  end

  defp call_adapter(adapter, state, request, invocation, credentials) do
    adapter.decide(state, request, invocation)
    |> normalize_adapter_result(credentials)
  rescue
    error -> {:error, ai_error(:failed, Redactor.message(Exception.message(error), credentials))}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
  end

  defp normalize_adapter_result({:ok, %AI.Decision{} = decision}, _credentials),
    do: {:ok, decision}

  defp normalize_adapter_result({:error, category, message}, credentials)
       when category in @adapter_failures and is_binary(message),
       do: {:error, ai_error(category, Redactor.message(message, credentials))}

  defp normalize_adapter_result(_result, _credentials),
    do: {:error, ai_error(:invalid_output, "AI output is invalid")}

  defp validate_decision(%AI.Decision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget) do
      validate_decision_shape(decision, request)
    end
  end

  defp validate_decision_shape(
         %AI.Decision{next_observation: %AI.ObservationChoice{} = choice} = decision,
         request
       ) do
    tool_ids = Enum.map(request.tools, & &1.id)

    if choice.tool_id in tool_ids and is_map(choice.parameters) and nonempty?(choice.reason) and
         decision.findings == [] and decision.proposals == [] do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI observation choice is invalid")}
    end
  end

  defp validate_decision_shape(%AI.Decision{next_observation: nil} = decision, request) do
    if valid_findings?(decision.findings, request) and
         valid_proposals?(decision.proposals, request) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI findings or proposals are invalid")}
    end
  end

  defp validate_decision_shape(_decision, _request),
    do: {:error, ai_error(:invalid_output, "AI output is invalid")}

  defp valid_findings?(findings, request) when is_list(findings) do
    evidence_ids = Enum.map(request.evidence, & &1.id)

    Enum.all?(findings, fn
      %AI.Finding{summary: summary, confidence: confidence, evidence_ids: ids} ->
        is_binary(summary) and is_number(confidence) and confidence >= 0 and confidence <= 1 and
          is_list(ids) and Enum.all?(ids, &(&1 in evidence_ids))

      _invalid ->
        false
    end)
  end

  defp valid_findings?(_findings, _request), do: false

  defp valid_proposals?(proposals, request) when is_list(proposals) do
    Enum.all?(proposals, fn
      %AI.Proposal{
        target_id: target_id,
        capability: capability,
        parameters: parameters,
        reason: reason
      } ->
        target_id in request.disclosure.allowed_target_ids and is_atom(capability) and
          is_map(parameters) and nonempty?(reason)

      _invalid ->
        false
    end)
  end

  defp valid_proposals?(_proposals, _request), do: false

  defp validate_usage(%AI.Usage{input_tokens: input, output_tokens: output}, budget)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    if input + output <= budget.remaining_tokens do
      :ok
    else
      {:error, ai_error(:budget_exhausted, "AI token budget was exceeded")}
    end
  end

  defp validate_usage(_usage, _budget),
    do: {:error, ai_error(:invalid_output, "AI token usage is invalid")}

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.() do
      {:error, ai_error(:cancelled, "AI decision was cancelled")}
    else
      :ok
    end
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
