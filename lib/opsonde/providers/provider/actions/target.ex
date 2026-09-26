defmodule Opsonde.Providers.Provider.Actions.Target do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{Redactor, Registry}
  alias Opsonde.Providers.Target

  @read_failures [:retryable, :timeout, :failed, :cancelled]
  @effect_failures [:failed, :cancelled]
  @effect_statuses [:applied, :unknown, :partial, :failed]
  @verification_statuses [:verified, :not_verified, :unknown]
  @max_read_attempts 5
  @max_payload_items 100
  @max_payload_bytes 65_536

  @impl true
  def run(input, opts, _context) do
    invocation = input.arguments.invocation

    with :ok <- ensure_not_cancelled(invocation),
         {:ok, provider} <- load_provider(input.arguments, opts[:operation]),
         {:ok, adapter} <- fetch_target_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider) do
      invoke(opts[:operation], adapter, state, input.arguments, invocation, provider.credentials)
    end
  rescue
    _error -> {:error, target_error(:failed, "Target provider failed")}
  catch
    _kind, _reason -> {:error, target_error(:failed, "Target provider failed")}
  end

  defp load_provider(arguments, :capabilities) do
    Providers.load_provider_for_invocation(
      arguments.provider_id,
      arguments.expected_revision,
      :target,
      authorize?: false
    )
  end

  defp load_provider(arguments, _operation) do
    Providers.load_provider_for_invocation(
      arguments.provider_id,
      arguments.request.provider_revision,
      :target,
      authorize?: false
    )
  end

  defp fetch_target_adapter(adapter_type) do
    case Registry.fetch(adapter_type, Target) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _reason} -> {:error, target_error(:failed, "Target adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, target_error(:failed, "Target configuration is invalid")}
    end
  end

  defp invoke(:capabilities, adapter, state, _arguments, invocation, credentials) do
    safe_call(fn -> adapter.capabilities(state, invocation) end, credentials)
    |> normalize_capabilities(credentials)
  end

  defp invoke(:observe, adapter, state, arguments, invocation, credentials) do
    request = arguments.request

    with :ok <- validate_observation_request(request) do
      observe(adapter, state, request, invocation, credentials, request.max_attempts)
    end
  end

  defp invoke(:effect, adapter, state, arguments, invocation, credentials) do
    with :ok <- validate_effect_request(arguments.request) do
      safe_effect_call(
        fn -> adapter.effect(state, arguments.request, invocation) end,
        credentials
      )
      |> normalize_effect(credentials)
    end
  end

  defp invoke(:verify, adapter, state, arguments, invocation, credentials) do
    with :ok <- validate_verification_request(arguments.request) do
      safe_call(fn -> adapter.verify(state, arguments.request, invocation) end, credentials)
      |> normalize_verification(credentials)
    end
  end

  defp observe(adapter, state, request, invocation, credentials, attempts_left) do
    with :ok <- ensure_not_cancelled(invocation) do
      result =
        safe_call(fn -> adapter.observe(state, request, invocation) end, credentials)
        |> normalize_observation(credentials)

      case result do
        {:error, %Target.Error{category: category}}
        when category in [:retryable, :timeout] and attempts_left > 1 ->
          observe(adapter, state, request, invocation, credentials, attempts_left - 1)

        other ->
          other
      end
    end
  end

  defp normalize_capabilities(
         {:ok, %Target.Capabilities{observations: observations, effects: effects} = value},
         credentials
       )
       when is_list(observations) and is_list(effects) do
    redacted = Redactor.value(value, credentials)

    if valid_capabilities?(value) and valid_capabilities?(redacted) do
      {:ok, redacted}
    else
      {:error, target_error(:failed, "Invalid capabilities result")}
    end
  end

  defp normalize_capabilities(result, credentials),
    do: normalize_error(result, @read_failures, "Invalid capabilities result", credentials)

  defp valid_capabilities?(%Target.Capabilities{observations: observations, effects: effects}) do
    valid_observations?(observations) and valid_effects?(effects, observations) and
      bounded_term_list?(observations ++ effects)
  end

  defp valid_observations?(operations) do
    valid_operations?(operations) and
      Enum.all?(operations, fn operation ->
        operation.evidence_requirements == [] and valid_schema?(operation.output_schema) and
          (is_nil(operation.verification_schema) or
             valid_schema?(operation.verification_schema))
      end)
  end

  defp valid_effects?(effects, observations) do
    valid_operations?(effects) and
      Enum.all?(effects, &valid_evidence_requirements?(&1, observations))
  end

  defp valid_evidence_requirements?(operation, observations)
       when is_list(operation.evidence_requirements) do
    parameter_properties =
      get_in(operation.input_schema, ["properties", "parameters", "properties"])

    operation.evidence_requirements == [] or
      (is_map(parameter_properties) and length(operation.evidence_requirements) <= 20 and
         Enum.all?(operation.evidence_requirements, fn
           %Target.EvidenceRequirement{} = requirement ->
             matching_observations =
               Enum.filter(observations, &(&1.operation == requirement.observation))

             observation = List.first(matching_observations)
             fact_properties = observation && observation.output_schema["properties"]

             length(matching_observations) == 1 and
               bounded_binary?(requirement.parameter, 500) and
               Map.has_key?(parameter_properties, requirement.parameter) and
               bounded_binary?(requirement.fact, 500) and is_map(fact_properties) and
               Map.has_key?(fact_properties, requirement.fact)

           _requirement ->
             false
         end) and
         Enum.uniq_by(operation.evidence_requirements, & &1.parameter) ==
           operation.evidence_requirements)
  end

  defp valid_evidence_requirements?(_operation, _observations), do: false

  defp normalize_observation(
         {:ok,
          %Target.Observation{facts: facts, observed_at: %DateTime{}, evidence: evidence} = value},
         credentials
       )
       when is_map(facts) and is_list(evidence) do
    if bounded_map?(facts) and bounded_list?(evidence) and
         bounded_map?(%{"facts" => facts, "evidence" => evidence}),
       do: {:ok, Redactor.value(value, credentials)},
       else: {:error, target_error(:failed, "Invalid observation result")}
  end

  defp normalize_observation(result, credentials),
    do: normalize_error(result, @read_failures, "Invalid observation result", credentials)

  defp normalize_effect({:ok, %Target.EffectResult{status: status} = value}, credentials)
       when status in @effect_statuses and is_map(value.details) do
    if bounded_map?(value.details) and
         (is_nil(value.reference) or nonempty_binary?(value.reference)) do
      {:ok, Redactor.value(value, credentials)}
    else
      {:error, target_error(:failed, "Invalid effect result")}
    end
  end

  defp normalize_effect(result, credentials),
    do: normalize_error(result, @effect_failures, "Invalid effect result", credentials)

  defp normalize_verification(
         {:ok,
          %Target.Verification{
            status: status,
            observed_at: %DateTime{},
            facts: facts,
            evidence: evidence
          } = value},
         credentials
       )
       when status in @verification_statuses and is_map(facts) and is_list(evidence) do
    if bounded_map?(facts) and bounded_list?(evidence) and
         bounded_map?(%{"facts" => facts, "evidence" => evidence}),
       do: {:ok, Redactor.value(value, credentials)},
       else: {:error, target_error(:failed, "Invalid verification result")}
  end

  defp normalize_verification(result, credentials),
    do: normalize_error(result, @read_failures, "Invalid verification result", credentials)

  defp normalize_error({:error, category, message}, allowed, fallback, credentials)
       when is_binary(message) do
    if category in allowed do
      {:error, target_error(category, Redactor.message(message, credentials))}
    else
      {:error, target_error(:failed, fallback)}
    end
  end

  defp normalize_error(_result, _allowed, fallback, _credentials),
    do: {:error, target_error(:failed, fallback)}

  defp validate_observation_request(%Target.ObservationRequest{} = request) do
    if valid_request_base?(request) and is_integer(request.max_attempts) and
         request.max_attempts in 1..@max_read_attempts do
      :ok
    else
      {:error, target_error(:failed, "Invalid observation request")}
    end
  end

  defp validate_effect_request(%Target.EffectRequest{} = request) do
    if valid_request_base?(request) and nonempty_binary?(request.operation_id) and
         nonempty_binary?(request.idempotency_key) do
      :ok
    else
      {:error, target_error(:failed, "Invalid effect request")}
    end
  end

  defp validate_verification_request(%Target.VerificationRequest{} = request) do
    if valid_request_base?(request) and nonempty_binary?(request.operation_id) and
         (is_nil(request.reference) or nonempty_binary?(request.reference)) and
         bounded_map?(request.parameters) and bounded_map?(request.expected) do
      :ok
    else
      {:error, target_error(:failed, "Invalid verification request")}
    end
  end

  defp valid_request_base?(request) do
    positive_integer?(request.provider_revision) and nonempty_binary?(request.target_id) and
      positive_integer?(request.target_revision) and
      nonempty_binary?(request.access_method_id) and
      positive_integer?(request.access_method_revision) and
      valid_connection?(request.connection) and
      nonempty_binary?(request.capability) and nonempty_binary?(request.operation) and
      nonempty_binary?(request.authorization_digest) and bounded_map?(request.selectors) and
      (is_nil(request.protocol_request) or bounded_map?(request.protocol_request)) and
      (not Map.has_key?(request, :parameters) or bounded_map?(request.parameters))
  end

  defp valid_connection?(%Target.Connection{endpoint: endpoint}),
    do: bounded_binary?(endpoint, 1_024)

  defp valid_connection?(_connection), do: false

  defp valid_operations?(operations) do
    Enum.all?(operations, &valid_operation?/1) and
      Enum.uniq_by(operations, &{&1.capability, &1.operation}) == operations
  end

  defp valid_operation?(%Target.Operation{} = operation) do
    bounded_binary?(operation.capability, 120) and
      bounded_binary?(operation.operation, 120) and
      bounded_binary?(operation.description, 500) and
      bounded_map?(operation.input_schema) and json_encodable?(operation.input_schema)
  end

  defp valid_operation?(_operation), do: false

  defp valid_schema?(schema),
    do: bounded_map?(schema) and json_encodable?(schema) and valid_json_schema?(schema)

  defp valid_json_schema?(schema) do
    try do
      match?({:ok, %JSV.Root{}}, JSV.build(schema, warnings: :silent))
    rescue
      _error -> false
    end
  end

  defp json_encodable?(value), do: match?({:ok, _encoded}, Jason.encode(value))

  defp bounded_binary?(value, maximum) when is_binary(value),
    do: byte_size(value) in 1..maximum

  defp bounded_binary?(_value, _maximum), do: false

  defp bounded_list?(items) when is_list(items) and length(items) <= @max_payload_items,
    do: :erlang.external_size(items) <= @max_payload_bytes and json_encodable?(items)

  defp bounded_list?(_items), do: false

  defp bounded_term_list?(items) when is_list(items) and length(items) <= @max_payload_items,
    do: :erlang.external_size(items) <= @max_payload_bytes

  defp bounded_term_list?(_items), do: false

  defp bounded_map?(map) when is_map(map) and map_size(map) <= @max_payload_items,
    do: :erlang.external_size(map) <= @max_payload_bytes and json_encodable?(map)

  defp bounded_map?(_map), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.() do
      {:error, target_error(:cancelled, "Target invocation was cancelled")}
    else
      :ok
    end
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp safe_call(callback, credentials) do
    callback.()
  rescue
    error -> {:error, :failed, Redactor.message(Exception.message(error), credentials)}
  catch
    _kind, _reason -> {:error, :failed, "Target provider failed"}
  end

  defp safe_effect_call(callback, credentials) do
    callback.()
  rescue
    error ->
      {:ok,
       %Target.EffectResult{
         status: :unknown,
         details: %{error: Redactor.message(Exception.message(error), credentials)}
       }}
  catch
    _kind, _reason ->
      {:ok, %Target.EffectResult{status: :unknown, details: %{error: "Target provider failed"}}}
  end

  defp target_error(category, message),
    do: Target.Error.exception(category: category, message: message)
end
