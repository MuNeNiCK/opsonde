defmodule Opsonde.Providers.Provider.Actions.Target do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{Redactor, Registry}
  alias Opsonde.Providers.Target

  @read_failures [:retryable, :timeout, :failed, :cancelled]
  @effect_failures [:failed, :cancelled]
  @effect_statuses [:applied, :unknown, :partial, :failed]
  @verification_statuses [:verified, :not_verified, :unknown]

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

    if is_integer(request.max_attempts) and request.max_attempts > 0 do
      observe(adapter, state, request, invocation, credentials, request.max_attempts)
    else
      {:error, target_error(:failed, "Observation max_attempts must be greater than zero")}
    end
  end

  defp invoke(:effect, adapter, state, arguments, invocation, credentials) do
    safe_call(fn -> adapter.effect(state, arguments.request, invocation) end, credentials)
    |> normalize_effect(credentials)
  end

  defp invoke(:verify, adapter, state, arguments, invocation, credentials) do
    safe_call(fn -> adapter.verify(state, arguments.request, invocation) end, credentials)
    |> normalize_verification(credentials)
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
    if Enum.all?(observations ++ effects, &is_atom/1) do
      {:ok, Redactor.value(value, credentials)}
    else
      {:error, target_error(:failed, "Invalid capabilities result")}
    end
  end

  defp normalize_capabilities(result, credentials),
    do: normalize_error(result, @read_failures, "Invalid capabilities result", credentials)

  defp normalize_observation(
         {:ok,
          %Target.Observation{facts: facts, observed_at: %DateTime{}, evidence: evidence} = value},
         credentials
       )
       when is_map(facts) and is_list(evidence),
       do: {:ok, Redactor.value(value, credentials)}

  defp normalize_observation(result, credentials),
    do: normalize_error(result, @read_failures, "Invalid observation result", credentials)

  defp normalize_effect({:ok, %Target.EffectResult{status: status} = value}, credentials)
       when status in @effect_statuses and is_map(value.details),
       do: {:ok, Redactor.value(value, credentials)}

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
       when status in @verification_statuses and is_map(facts) and is_list(evidence),
       do: {:ok, Redactor.value(value, credentials)}

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

  defp target_error(category, message),
    do: Target.Error.exception(category: category, message: message)
end
