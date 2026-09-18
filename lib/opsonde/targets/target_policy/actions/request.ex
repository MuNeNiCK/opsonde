defmodule Opsonde.Targets.TargetPolicy.Actions.Request do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.{PolicyError, PolicyMatcher, PolicyRequest, RequestClearance}

  @authority_modes [:readonly, :ask, :auto, :full_access]
  @request_kinds [:observation, :effect, :verification]
  @max_payload_items 100
  @max_payload_bytes 65_536

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :clear -> clear(context.actor, input.arguments.request)
      operation -> dispatch(operation, context.actor, input.arguments)
    end
  end

  defp clear(actor, %PolicyRequest{} = request) do
    with {:ok, current_actor} <- current_actor(actor),
         :ok <- validate_request(request),
         {:ok, context} <- resolve(request),
         :ok <- evaluate(context.policies, request),
         :ok <- validate_authority(request) do
      {:ok, build_clearance(current_actor, request, context)}
    end
  end

  defp dispatch(operation, actor, %{clearance: %RequestClearance{} = clearance} = arguments) do
    with :ok <- expected_dispatch(operation, clearance.kind),
         :ok <- valid_digest(clearance),
         {:ok, current_actor} <- current_actor(actor),
         :ok <- same_actor(current_actor, clearance),
         request <- request_from_clearance(clearance),
         :ok <- validate_request(request),
         {:ok, context} <- resolve(request),
         :ok <- evaluate(context.policies, request),
         :ok <- validate_authority(request),
         :ok <- current_policy_set(context.policies, clearance.policy_revisions),
         :ok <- current_provider(context.access_method, clearance) do
      invoke(operation, current_actor, context.access_method, clearance, arguments.invocation)
    end
  end

  defp dispatch(_operation, _actor, _arguments),
    do: {:error, policy_error(:invalid_clearance, "Policy clearance is invalid")}

  defp resolve(request) do
    with {:ok, target} <- Targets.get_target(request.target_id, authorize?: false),
         :ok <- current(target.revision, request.target_revision),
         :ok <- active(target.active, :inactive_target),
         {:ok, access_method} <-
           Targets.load_access_method_for_use(
             request.access_method_id,
             request.access_method_revision,
             request.capability,
             authorize?: false
           ),
         :ok <- same_target(access_method, target),
         {:ok, policies} <- Targets.active_target_policies(target.id, authorize?: false) do
      {:ok, %{target: target, access_method: access_method, policies: policies}}
    else
      {:error, %PolicyError{} = error} ->
        {:error, error}

      {:error, _error} ->
        {:error, policy_error(:stale_context, "Target request context is unavailable")}
    end
  end

  defp evaluate(policies, request) do
    Enum.reduce_while(policies, :ok, fn policy, :ok ->
      case policy_match(policy, request) do
        :match ->
          {:halt, {:error, policy_error(:denied, policy.reason, policy_id: policy.id)}}

        :no_match ->
          {:cont, :ok}

        {:error, _reason} ->
          {:halt,
           {:error,
            policy_error(:ambiguous_policy, "Target policy could not be evaluated safely",
              policy_id: policy.id
            )}}
      end
    end)
  end

  defp policy_match(policy, request) do
    kind = policy_kind(request.kind)

    cond do
      kind not in policy.request_kinds ->
        :no_match

      policy.capabilities != [] and request.capability not in policy.capabilities ->
        :no_match

      policy.operations != [] and request.operation not in policy.operations ->
        :no_match

      true ->
        with :match <- PolicyMatcher.match(policy.selector_match, request.selectors),
             :match <- PolicyMatcher.match(policy.parameter_match, request.parameters) do
          :match
        else
          :no_match -> :no_match
          {:error, _reason} = error -> error
        end
    end
  end

  defp build_clearance(actor, request, context) do
    attributes = %{
      actor_id: actor.id,
      kind: request.kind,
      authority_mode: request.authority_mode,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.access_method.id,
      access_method_revision: context.access_method.revision,
      provider_id: context.access_method.provider_id,
      provider_revision: context.access_method.provider_revision,
      capability: request.capability,
      operation: request.operation,
      selectors: request.selectors,
      parameters: request.parameters,
      operation_id: request.operation_id,
      idempotency_key: request.idempotency_key,
      reference: request.reference,
      expected: request.expected,
      max_attempts: request.max_attempts,
      policy_revisions: policy_revisions(context.policies)
    }

    struct!(RequestClearance, Map.put(attributes, :digest, digest(attributes)))
  end

  defp request_from_clearance(clearance) do
    struct!(PolicyRequest,
      kind: clearance.kind,
      authority_mode: clearance.authority_mode,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      capability: clearance.capability,
      operation: clearance.operation,
      selectors: clearance.selectors,
      parameters: clearance.parameters,
      operation_id: clearance.operation_id,
      idempotency_key: clearance.idempotency_key,
      reference: clearance.reference,
      expected: clearance.expected,
      max_attempts: clearance.max_attempts
    )
  end

  defp invoke(:observe, actor, method, clearance, invocation) do
    request = %ProviderTarget.ObservationRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      selectors: clearance.selectors,
      parameters: clearance.parameters,
      max_attempts: clearance.max_attempts
    }

    Providers.target_observe(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp invoke(:effect, actor, method, clearance, invocation) do
    request = %ProviderTarget.EffectRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      selectors: clearance.selectors,
      parameters: clearance.parameters,
      operation_id: clearance.operation_id,
      idempotency_key: clearance.idempotency_key
    }

    Providers.target_effect(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp invoke(:verify, actor, method, clearance, invocation) do
    request = %ProviderTarget.VerificationRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      selectors: clearance.selectors,
      parameters: clearance.parameters,
      operation_id: clearance.operation_id,
      reference: clearance.reference,
      expected: clearance.expected
    }

    Providers.target_verify(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp validate_request(%PolicyRequest{} = request) do
    cond do
      request.kind not in @request_kinds ->
        invalid_request()

      request.authority_mode not in @authority_modes ->
        invalid_request()

      not nonempty_binary?(request.target_id) ->
        invalid_request()

      not positive_integer?(request.target_revision) ->
        invalid_request()

      not nonempty_binary?(request.access_method_id) ->
        invalid_request()

      not positive_integer?(request.access_method_revision) ->
        invalid_request()

      not bounded_string?(request.capability, 120) ->
        invalid_request()

      not bounded_string?(request.operation, 120) ->
        invalid_request()

      not bounded_map?(request.selectors) ->
        invalid_request()

      not bounded_map?(request.parameters) ->
        invalid_request()

      not bounded_map?(request.expected) ->
        invalid_request()

      not is_integer(request.max_attempts) or request.max_attempts not in 1..5 ->
        invalid_request()

      request.kind == :effect and not nonempty_binary?(request.operation_id) ->
        invalid_request()

      request.kind == :effect and not nonempty_binary?(request.idempotency_key) ->
        invalid_request()

      request.kind == :verification and not nonempty_binary?(request.operation_id) ->
        invalid_request()

      not is_nil(request.reference) and not nonempty_binary?(request.reference) ->
        invalid_request()

      true ->
        :ok
    end
  end

  defp validate_authority(%PolicyRequest{kind: :effect, authority_mode: :readonly}),
    do: {:error, policy_error(:forbidden, "Readonly authority cannot execute Target effects")}

  defp validate_authority(%PolicyRequest{}), do: :ok

  defp current_actor(%{id: actor_id}) do
    case Accounts.get_user(actor_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] -> {:ok, actor}
      _other -> {:error, policy_error(:forbidden, "Actor is not authorized for Target requests")}
    end
  end

  defp current_actor(_actor),
    do: {:error, policy_error(:forbidden, "Actor is not authorized for Target requests")}

  defp same_actor(%{id: id}, %{actor_id: id}), do: :ok

  defp same_actor(_actor, _clearance),
    do: {:error, policy_error(:clearance_mismatch, "Policy clearance actor changed")}

  defp same_target(%{target_id: id}, %{id: id}), do: :ok

  defp same_target(_method, _target),
    do: {:error, policy_error(:out_of_scope, "Access Method belongs to another Target")}

  defp current_policy_set(policies, expected) do
    if policy_revisions(policies) == expected,
      do: :ok,
      else: {:error, policy_error(:stale_policy, "Target policy set changed")}
  end

  defp current_provider(method, clearance) do
    if method.provider_id == clearance.provider_id and
         method.provider_revision == clearance.provider_revision do
      :ok
    else
      {:error, policy_error(:stale_context, "Target Provider changed")}
    end
  end

  defp expected_dispatch(:observe, :observation), do: :ok
  defp expected_dispatch(:effect, :effect), do: :ok
  defp expected_dispatch(:verify, :verification), do: :ok

  defp expected_dispatch(_operation, _kind),
    do:
      {:error, policy_error(:invalid_clearance, "Policy clearance kind does not match dispatch")}

  defp valid_digest(%RequestClearance{} = clearance) do
    attributes = clearance |> Map.from_struct() |> Map.delete(:digest)
    expected = digest(attributes)

    if is_binary(clearance.digest) and byte_size(clearance.digest) == byte_size(expected) and
         :crypto.hash_equals(clearance.digest, expected) do
      :ok
    else
      {:error, policy_error(:clearance_mismatch, "Policy clearance was modified")}
    end
  end

  defp policy_revisions(policies), do: Enum.map(policies, &{&1.id, &1.revision})
  defp policy_kind(:verification), do: :observation
  defp policy_kind(kind), do: kind

  defp digest(attributes) do
    key = Application.fetch_env!(:opsonde, :token_signing_secret)
    payload = :erlang.term_to_binary(attributes, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, "opsonde-target-clearance-v1\0" <> payload)
  end

  defp current(value, value), do: :ok

  defp current(_actual, _expected),
    do: {:error, policy_error(:stale_context, "Target revision changed")}

  defp active(true, _category), do: :ok
  defp active(false, category), do: {:error, policy_error(category, "Target is inactive")}

  defp bounded_map?(map) when is_map(map) and map_size(map) <= @max_payload_items do
    case Jason.encode(map) do
      {:ok, encoded} -> byte_size(encoded) <= @max_payload_bytes
      {:error, _error} -> false
    end
  end

  defp bounded_map?(_map), do: false
  defp bounded_string?(value, max) when is_binary(value), do: byte_size(value) in 1..max
  defp bounded_string?(_value, _max), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp invalid_request(),
    do: {:error, policy_error(:invalid_request, "Target request is invalid")}

  defp policy_error(category, message, opts \\ []) do
    PolicyError.exception(
      category: category,
      message: message,
      policy_id: opts[:policy_id]
    )
  end
end
