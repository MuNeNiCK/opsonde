defmodule Opsonde.AI.ReqLLM do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.AI

  alias Opsonde.Providers.AI

  @providers %{"openai" => :openai, "anthropic" => :anthropic, "ollama" => :ollama}
  @configuration_keys ~w(provider model endpoint stream max_tokens timeout_ms)
  @max_model_bytes 200
  @max_output_bytes 65_536
  @max_tokens 32_768
  @max_timeout 600_000
  @poll_interval 20

  @impl Opsonde.Providers.Adapter
  def type, do: "req-llm"

  @impl Opsonde.Providers.Adapter
  def kind, do: :ai

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with :ok <- known_configuration(configuration),
         {:ok, provider} <- provider(configuration),
         {:ok, model} <- required_string(configuration, "model", @max_model_bytes),
         {:ok, endpoint} <- endpoint(configuration),
         {:ok, stream?} <- boolean(configuration, "stream", false),
         {:ok, max_tokens} <- integer(configuration, "max_tokens", 2_048, 1, @max_tokens),
         {:ok, timeout} <- integer(configuration, "timeout_ms", 60_000, 100, @max_timeout),
         {:ok, api_key} <- credentials(provider, credentials),
         model_spec <- model_spec(provider, model),
         {:ok, resolved_model} <- ReqLLM.model(model_spec) do
      {:ok,
       %{
         provider: provider,
         model: resolved_model,
         endpoint: endpoint,
         stream?: stream?,
         max_tokens: max_tokens,
         timeout: timeout,
         api_key: api_key
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(state, _input) do
    output = ReqLLM.Output.choice(["ready"], name: "opsonde_provider_check")

    case invoke(
           state,
           context(
             "You are checking an AI model connection.",
             "Return the single value ready."
           ),
           output,
           min(state.max_tokens, 128),
           fn -> false end
         ) do
      {:ok, response} ->
        if ReqLLM.Response.output(response, output) == "ready",
          do: :ok,
          else: {:error, :capability, "AI model did not produce structured output"}

      {:error, category, message} ->
        check_error(category, message)
    end
  end

  @impl Opsonde.Providers.AI
  def resolve(state, %AI.ResolverRequest{} = request, invocation) do
    output = ReqLLM.Output.object(resolver_schema(request), name: "opsonde_resolver_decision")

    with {:ok, response} <-
           invoke(
             state,
             resolver_context(request),
             output,
             min(state.max_tokens, request.budget.remaining_tokens),
             cancelled_callback(invocation)
           ),
         {:ok, value} <- output(response, output),
         {:ok, usage} <- usage(response),
         {:ok, intent} <- resolver_intent(value, request) do
      {:ok, %AI.ResolverDecision{intent: intent, usage: usage}}
    end
  end

  @impl Opsonde.Providers.AI
  def review(state, %AI.ReviewRequest{} = request, invocation) do
    output = ReqLLM.Output.object(reviewer_schema(), name: "opsonde_review_decision")

    with {:ok, response} <-
           invoke(
             state,
             reviewer_context(request),
             output,
             min(state.max_tokens, request.budget.remaining_tokens),
             cancelled_callback(invocation)
           ),
         {:ok, value} <- output(response, output),
         {:ok, usage} <- usage(response),
         {:ok, verdict} <- verdict(value) do
      {:ok,
       %AI.ReviewDecision{
         verdict: verdict,
         reason: value["reason"],
         usage: usage
       }}
    end
  end

  defp invoke(state, messages, output, max_tokens, cancelled?) do
    parent = self()
    stream_ref = make_ref()

    task =
      Task.async(fn ->
        safe_request(state, messages, output, max_tokens, parent, stream_ref)
      end)

    await(
      task,
      stream_ref,
      nil,
      cancelled?,
      System.monotonic_time(:millisecond) + state.timeout
    )
  end

  defp safe_request(state, messages, output, max_tokens, parent, stream_ref) do
    options =
      [
        output: output,
        output_validation: :strict,
        max_tokens: max_tokens,
        max_retries: 0,
        total_timeout: state.timeout,
        receive_timeout: state.timeout,
        telemetry: [payloads: :none]
      ]
      |> maybe_put(:api_key, state.api_key)
      |> maybe_put(:base_url, state.endpoint)

    request(state, messages, options, parent, stream_ref)
  rescue
    _error -> {:error, :failed, "AI provider failed"}
  catch
    _kind, _reason -> {:error, :failed, "AI provider failed"}
  end

  defp request(%{stream?: false} = state, messages, options, _parent, _stream_ref) do
    state.model
    |> ReqLLM.generate_text(messages, options)
    |> normalize_req_llm_result()
  end

  defp request(%{stream?: true} = state, messages, options, parent, stream_ref) do
    case ReqLLM.stream_text(state.model, messages, options) do
      {:ok, stream_response} ->
        send(parent, {:opsonde_req_llm_stream, stream_ref, stream_response.cancel})

        try do
          stream_response
          |> ReqLLM.StreamResponse.to_response()
          |> normalize_req_llm_result()
        after
          ReqLLM.StreamResponse.close(stream_response)
        end

      {:error, error} ->
        normalize_req_llm_error(error)
    end
  end

  defp await(task, stream_ref, cancel_stream, cancelled?, deadline) do
    cond do
      cancelled?(cancelled?) ->
        cancel(cancel_stream)
        Task.shutdown(task, :brutal_kill)
        {:error, :cancelled, "AI decision was cancelled"}

      System.monotonic_time(:millisecond) >= deadline ->
        cancel(cancel_stream)
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout, "AI provider timed out"}

      true ->
        receive do
          {:opsonde_req_llm_stream, ^stream_ref, callback} when is_function(callback, 0) ->
            await(task, stream_ref, callback, cancelled?, deadline)
        after
          @poll_interval ->
            case Task.yield(task, 0) do
              {:ok, result} -> result
              {:exit, _reason} -> {:error, :failed, "AI provider failed"}
              nil -> await(task, stream_ref, cancel_stream, cancelled?, deadline)
            end
        end
    end
  end

  defp resolver_context(request) do
    payload = %{
      "case_id" => request.case_id,
      "turn" => request.turn,
      "objective" => request.objective,
      "alert_state" => to_string(request.alert_state),
      "report_language" => to_string(request.report_language),
      "budget" => plain(request.budget),
      "evidence" => plain(request.evidence),
      "target_candidates" => plain(request.target_candidates),
      "selected_target_id" => request.selected_target_id,
      "selected_target_revision" => request.selected_target_revision,
      "observation_results" => plain(request.observation_results),
      "target_relations" => plain(request.target_relations),
      "observation_tools" => plain(request.observation_tools),
      "proposal_tools" => plain(request.proposal_tools)
    }

    context(
      "You are the Opsonde Resolver. Select exactly one next intent from the supplied " <>
        "registered Targets and tools. Never execute a tool. Never invent an identifier. " <>
        "Base the intent only on supplied evidence and preserve uncertainty. Write the " <>
        "human-facing reason and required_input fields in the report_language supplied in " <>
        "the user payload. Keep reason concise and at most 500 UTF-8 bytes. Return exactly " <>
        "one intent allowed by the supplied output schema. For expected_result_json fields, " <>
        "encode one JSON object as a string. Use only identifiers and evidence IDs supplied " <>
        "in the user payload.",
      Jason.encode!(payload)
    )
  end

  defp reviewer_context(request) do
    payload = %{
      "case_id" => request.case_id,
      "objective" => request.objective,
      "policy_summary" => request.policy_summary,
      "proposal" => plain(request.proposal),
      "cited_evidence" => plain(request.cited_evidence),
      "budget" => plain(request.budget)
    }

    context(
      "You are an isolated Opsonde Reviewer. Review only the exact proposal and cited " <>
        "evidence supplied here. You have no executable tools and no Resolver conversation. " <>
        "Return approved, rejected, or needs_human with a concise reason.",
      Jason.encode!(payload)
    )
  end

  defp context(system, user) do
    ReqLLM.Context.new([
      ReqLLM.Context.system(system),
      ReqLLM.Context.user(user)
    ])
  end

  defp resolver_intent(%{"reason" => reason, "intent" => intent}, request)
       when is_binary(reason) and is_map(intent) do
    intent
    |> Map.put("reason", reason)
    |> intent(request)
  end

  defp resolver_intent(_value, _request), do: invalid_output()

  defp intent(%{"type" => "target_search"} = value, _request) do
    with {:ok, query} <- string(value, "query"),
         {:ok, reason} <- string(value, "reason") do
      {:ok, %AI.TargetSearch{query: query, reason: reason}}
    end
  end

  defp intent(%{"type" => "target_selection"} = value, request) do
    with {:ok, target_id} <- string(value, "target_id"),
         %AI.TargetCandidate{} = target <-
           Enum.find(request.target_candidates, &(&1.id == target_id)),
         {:ok, evidence_ids} <- string_list(value, "evidence_ids"),
         {:ok, reason} <- string(value, "reason") do
      {:ok,
       %AI.TargetSelection{
         target_id: target.id,
         target_revision: target.revision,
         evidence_ids: evidence_ids,
         reason: reason
       }}
    else
      _error -> invalid_output()
    end
  end

  defp intent(%{"type" => "observation", "tool_input" => tool_input} = value, request)
       when is_map(tool_input) do
    with {:ok, tool_id} <- string(tool_input, "tool_id"),
         %AI.ObservationTool{} <- Enum.find(request.observation_tools, &(&1.id == tool_id)),
         {:ok, selectors} <- map(tool_input, "selectors"),
         {:ok, parameters} <- map(tool_input, "parameters"),
         {:ok, reason} <- string(value, "reason") do
      {:ok,
       %AI.ObservationChoice{
         tool_id: tool_id,
         selectors: selectors,
         parameters: parameters,
         reason: reason
       }}
    else
      _error -> invalid_output()
    end
  end

  defp intent(%{"type" => "target_traversal"} = value, request) do
    with {:ok, relationship_id} <- string(value, "relationship_id"),
         %AI.TargetRelation{} = relationship <-
           Enum.find(request.target_relations, &(&1.id == relationship_id)),
         {:ok, next_target} <- traversal_target(relationship, request.selected_target_id),
         {:ok, evidence_ids} <- string_list(value, "evidence_ids"),
         {:ok, reason} <- string(value, "reason") do
      {:ok,
       %AI.TargetTraversal{
         relationship_id: relationship.id,
         relationship_revision: relationship.revision,
         next_target_id: next_target.id,
         next_target_revision: next_target.revision,
         evidence_ids: evidence_ids,
         reason: reason
       }}
    else
      _error -> invalid_output()
    end
  end

  defp intent(%{"type" => "proposal", "action" => action} = value, request)
       when is_map(action) do
    with {:ok, tool_id} <- string(action, "tool_id"),
         %AI.ProposalTool{} = tool <- Enum.find(request.proposal_tools, &(&1.id == tool_id)),
         {:ok, selectors} <- map(action, "selectors"),
         {:ok, parameters} <- map(action, "parameters"),
         {:ok, reason} <- string(value, "reason"),
         {:ok, evidence_ids} <- string_list(value, "evidence_ids"),
         {:ok, expected_result} <- decoded_map(value, "expected_result_json"),
         {:ok, verification} <- verification_intent(value["verification"], request) do
      {:ok,
       %AI.Proposal{
         tool_id: tool.id,
         target_id: tool.target_id,
         target_revision: tool.target_revision,
         access_method_id: tool.access_method_id,
         access_method_revision: tool.access_method_revision,
         capability: tool.capability,
         operation: tool.operation,
         selectors: selectors,
         parameters: parameters,
         reason: reason,
         evidence_ids: evidence_ids,
         expected_result: expected_result,
         verification_intent: verification
       }}
    else
      _error -> invalid_output()
    end
  end

  defp intent(%{"type" => "recovery"} = value, _request) do
    with {:ok, reason} <- string(value, "reason"),
         {:ok, evidence_ids} <- string_list(value, "evidence_ids") do
      {:ok, %AI.RecoveryConclusion{reason: reason, evidence_ids: evidence_ids}}
    end
  end

  defp intent(%{"type" => "handoff"} = value, _request) do
    with {:ok, reason} <- string(value, "reason"),
         {:ok, required_input} <- string(value, "required_input") do
      {:ok, %AI.Handoff{reason: reason, required_input: required_input}}
    end
  end

  defp intent(_value, _request), do: invalid_output()

  defp verification_intent(value, request) when is_map(value) do
    with {:ok, tool_id} <- string(value, "tool_id"),
         %_{id: ^tool_id} <- verification_tool(request, tool_id),
         {:ok, selectors} <- map(value, "selectors"),
         {:ok, parameters} <- map(value, "parameters"),
         {:ok, expected_result} <- decoded_map(value, "expected_result_json") do
      {:ok,
       %AI.VerificationIntent{
         tool_id: tool_id,
         selectors: selectors,
         parameters: parameters,
         expected_result: expected_result
       }}
    else
      _error -> invalid_output()
    end
  end

  defp verification_intent(_value, _request), do: invalid_output()

  defp verification_tool(request, tool_id),
    do: Enum.find(request.observation_tools ++ request.proposal_tools, &(&1.id == tool_id))

  defp traversal_target(relationship, selected_target_id) do
    cond do
      relationship.source_target.id == selected_target_id ->
        {:ok, relationship.destination_target}

      relationship.destination_target.id == selected_target_id ->
        {:ok, relationship.source_target}

      true ->
        invalid_output()
    end
  end

  defp verdict(%{"verdict" => verdict, "reason" => reason})
       when verdict in ["approved", "rejected", "needs_human"] and is_binary(reason) and
              byte_size(reason) > 0 do
    {:ok, String.to_existing_atom(verdict)}
  end

  defp verdict(_value), do: invalid_output()

  defp output(response, descriptor) do
    value = ReqLLM.Response.output(response, descriptor)

    cond do
      not is_map(value) -> invalid_output()
      encoded_size(value) > @max_output_bytes -> invalid_output("AI provider output is too large")
      true -> {:ok, value}
    end
  end

  defp usage(response) do
    usage = ReqLLM.Response.usage(response)
    input_tokens = value(usage, :input_tokens)
    output_tokens = value(usage, :output_tokens)

    if is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
         output_tokens >= 0 do
      {:ok, %AI.Usage{input_tokens: input_tokens, output_tokens: output_tokens}}
    else
      invalid_output("AI provider did not return token usage")
    end
  end

  defp resolver_schema(request) do
    variants =
      [
        target_search_schema(request),
        target_selection_schema(request),
        observation_schema(request),
        target_traversal_schema(request),
        proposal_schema(request),
        recovery_schema(request),
        handoff_schema()
      ]
      |> Enum.reject(&is_nil/1)

    object_schema(
      %{
        "reason" => bounded_string_schema(500),
        "intent" => %{"anyOf" => variants}
      },
      ~w(reason intent)
    )
  end

  defp target_search_schema(%{budget: %{remaining_target_requests: remaining}})
       when remaining > 0,
       do: intent_schema("target_search", %{"query" => bounded_string_schema(200)})

  defp target_search_schema(_request), do: nil

  defp target_selection_schema(request) do
    target_ids = Enum.map(request.target_candidates, & &1.id)
    evidence_ids = available_evidence_ids(request)

    if target_ids != [] and evidence_ids != [] do
      intent_schema("target_selection", %{
        "target_id" => enum_schema(target_ids),
        "evidence_ids" => identifier_array_schema(evidence_ids)
      })
    end
  end

  defp observation_schema(%{budget: %{remaining_target_requests: remaining}} = request)
       when remaining > 0 do
    case tool_input_variants(request.observation_tools) do
      [] -> nil
      variants -> intent_schema("observation", %{"tool_input" => %{"anyOf" => variants}})
    end
  end

  defp observation_schema(_request), do: nil

  defp target_traversal_schema(%{budget: %{remaining_related_targets: remaining}} = request)
       when remaining > 0 do
    relationship_ids = Enum.map(request.target_relations, & &1.id)
    evidence_ids = available_evidence_ids(request)

    if relationship_ids != [] and evidence_ids != [] do
      intent_schema("target_traversal", %{
        "relationship_id" => enum_schema(relationship_ids),
        "evidence_ids" => identifier_array_schema(evidence_ids)
      })
    end
  end

  defp target_traversal_schema(_request), do: nil

  defp proposal_schema(%{budget: %{remaining_effects: remaining}} = request) when remaining > 0 do
    action_variants = tool_input_variants(request.proposal_tools)

    verification_variants =
      tool_input_variants(
        request.observation_tools ++ request.proposal_tools,
        %{"expected_result_json" => json_object_string_schema()}
      )

    evidence_ids = available_evidence_ids(request)

    if action_variants != [] and verification_variants != [] and evidence_ids != [] do
      intent_schema("proposal", %{
        "action" => %{"anyOf" => action_variants},
        "evidence_ids" => identifier_array_schema(evidence_ids),
        "expected_result_json" => json_object_string_schema(),
        "verification" => %{"anyOf" => verification_variants}
      })
    end
  end

  defp proposal_schema(_request), do: nil

  defp recovery_schema(%{alert_state: state} = request)
       when state in [:recovered, :not_applicable] do
    case available_evidence_ids(request) do
      [] ->
        nil

      evidence_ids ->
        intent_schema("recovery", %{
          "evidence_ids" => identifier_array_schema(evidence_ids)
        })
    end
  end

  defp recovery_schema(_request), do: nil

  defp handoff_schema,
    do: intent_schema("handoff", %{"required_input" => bounded_string_schema(1_000)})

  defp intent_schema(type, properties),
    do:
      object_schema(
        Map.put(properties, "type", enum_schema([type])),
        ["type" | Map.keys(properties)]
      )

  defp tool_input_variants(tools, extra_properties \\ %{}) do
    Enum.flat_map(tools, fn tool ->
      case tool.input_schema do
        %{
          "type" => "object",
          "properties" => properties,
          "required" => required
        } = schema
        when is_map(properties) and is_list(required) ->
          properties =
            properties
            |> Map.merge(extra_properties)
            |> Map.put("tool_id", enum_schema([tool.id]))

          required = ["tool_id" | required ++ Map.keys(extra_properties)] |> Enum.uniq()

          [
            schema
            |> Map.put("properties", properties)
            |> Map.put("required", required)
            |> Map.put("additionalProperties", false)
            |> Map.put("description", tool.description)
          ]

        _schema ->
          []
      end
    end)
  end

  defp available_evidence_ids(request),
    do: Enum.map(request.evidence ++ request.observation_results, & &1.id)

  defp identifier_array_schema(values),
    do: %{
      "type" => "array",
      "items" => enum_schema(values),
      "minItems" => 1,
      "uniqueItems" => true
    }

  defp json_object_string_schema,
    do: %{
      "type" => "string",
      "minLength" => 2,
      "description" => "A JSON-encoded object"
    }

  defp reviewer_schema do
    object_schema(
      %{
        "verdict" => enum_schema(~w(approved rejected needs_human)),
        "reason" => bounded_string_schema(1_000)
      },
      ~w(verdict reason)
    )
  end

  defp object_schema(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  defp string_schema, do: %{"type" => "string", "minLength" => 1}
  defp bounded_string_schema(maximum), do: Map.put(string_schema(), "maxLength", maximum)
  defp enum_schema(values), do: %{"type" => "string", "enum" => values}

  defp provider(configuration) do
    case Map.get(configuration, "provider") do
      value when is_map_key(@providers, value) -> {:ok, Map.fetch!(@providers, value)}
      _value -> {:error, :invalid_provider}
    end
  end

  defp endpoint(configuration) do
    case Map.get(configuration, "endpoint") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> validate_endpoint(value)
      _value -> {:error, :invalid_endpoint}
    end
  end

  defp validate_endpoint(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, String.trim_trailing(value, "/")}

      _uri ->
        {:error, :invalid_endpoint}
    end
  end

  defp credentials(provider, credentials) do
    keys = credentials |> Map.keys() |> Enum.map(&to_string/1)
    api_key = Map.get(credentials, "api_key") || Map.get(credentials, :api_key)

    cond do
      Enum.any?(keys, &(&1 != "api_key")) ->
        {:error, :invalid_credentials}

      provider in [:openai, :anthropic] and not nonempty?(api_key) ->
        {:error, :missing_api_key}

      provider == :ollama and not (is_nil(api_key) or nonempty?(api_key)) ->
        {:error, :invalid_api_key}

      true ->
        {:ok, api_key}
    end
  end

  defp model_spec(provider, model), do: %{provider: provider, id: model}

  defp known_configuration(configuration) do
    if Enum.all?(Map.keys(configuration), &(to_string(&1) in @configuration_keys)),
      do: :ok,
      else: {:error, :unknown_configuration}
  end

  defp required_string(map, key, max_bytes) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes ->
        {:ok, value}

      _value ->
        {:error, :invalid_string}
    end
  end

  defp boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, :invalid_boolean}
    end
  end

  defp integer(map, key, default, minimum, maximum) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value >= minimum and value <= maximum -> {:ok, value}
      _value -> {:error, :invalid_integer}
    end
  end

  defp string(value, key) do
    case Map.get(value, key) do
      item when is_binary(item) and byte_size(item) > 0 -> {:ok, item}
      _item -> invalid_output()
    end
  end

  defp map(value, key) do
    case Map.get(value, key) do
      item when is_map(item) -> {:ok, item}
      _item -> invalid_output()
    end
  end

  defp decoded_map(value, key) do
    with {:ok, encoded} <- string(value, key),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _error -> invalid_output()
    end
  end

  defp string_list(value, key) do
    case Map.get(value, key) do
      items when is_list(items) ->
        if Enum.all?(items, &nonempty?/1), do: {:ok, items}, else: invalid_output()

      _items ->
        invalid_output()
    end
  end

  defp normalize_req_llm_result({:ok, %ReqLLM.Response{} = response}), do: {:ok, response}
  defp normalize_req_llm_result({:error, error}), do: normalize_req_llm_error(error)
  defp normalize_req_llm_result(_result), do: {:error, :failed, "AI provider failed"}

  defp normalize_req_llm_error(%ReqLLM.Error.API.Request{status: status})
       when status in [401, 403],
       do: {:error, :authentication, "AI provider authentication failed"}

  defp normalize_req_llm_error(%ReqLLM.Error.API.Request{status: 429}),
    do: {:error, :rate_limited, "AI provider rate limit exceeded"}

  defp normalize_req_llm_error(%ReqLLM.Error.API.Request{status: status})
       when status in [408, 504],
       do: {:error, :timeout, "AI provider timed out"}

  defp normalize_req_llm_error(%ReqLLM.Error.API.Request{status: nil}),
    do: {:error, :unreachable, "AI provider is unreachable"}

  defp normalize_req_llm_error(%ReqLLM.Error.API.Timeout{}),
    do: {:error, :timeout, "AI provider timed out"}

  defp normalize_req_llm_error(%ReqLLM.Error.Validation.Error{}),
    do: invalid_output()

  defp normalize_req_llm_error(%ReqLLM.Error.API.SchemaValidation{}),
    do: invalid_output()

  defp normalize_req_llm_error(%ReqLLM.Error.API.Response{}),
    do: invalid_output()

  defp normalize_req_llm_error(_error), do: {:error, :failed, "AI provider failed"}

  defp check_error(:authentication, message), do: {:error, :authentication, message}

  defp check_error(:invalid_output, _message),
    do: {:error, :capability, "AI model cannot produce structured output"}

  defp check_error(_category, message), do: {:error, :unreachable, message}

  defp cancelled_callback(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled_callback(_invocation), do: fn -> false end

  defp cancelled?(callback) do
    callback.() == true
  rescue
    _error -> true
  catch
    _kind, _reason -> true
  end

  defp cancel(nil), do: :ok

  defp cancel(callback) do
    callback.()
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp plain(%_{} = value), do: value |> Map.from_struct() |> plain()

  defp plain(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), plain(nested)} end)
  end

  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value) when is_atom(value), do: Atom.to_string(value)
  defp plain(value), do: value

  defp encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp invalid_output(message \\ "AI provider output is invalid"),
    do: {:error, :invalid_output, message}
end
