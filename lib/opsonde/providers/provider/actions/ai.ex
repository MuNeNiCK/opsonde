defmodule Opsonde.Providers.Provider.Actions.AI do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{AI, Redactor, Registry}

  @adapter_failures [
    :authentication,
    :unreachable,
    :timeout,
    :failed,
    :rate_limited,
    :cancelled,
    :invalid_output
  ]

  @impl true
  def run(input, opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments
    operation = opts[:operation]

    with :ok <- ensure_not_cancelled(invocation),
         :ok <- AI.Validator.validate_request(operation, request),
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
           call_adapter(operation, adapter, state, request, invocation, provider.credentials),
         validation <- AI.Validator.validate_decision(operation, decision, request) do
      case validation do
        :ok ->
          {:ok, Redactor.value(decision, provider.credentials)}

        {:error, %AI.Error{} = error} ->
          {:error, %{error | usage: decision.usage, dispatched?: true}}

        error ->
          error
      end
    end
  rescue
    _error -> {:error, ai_error(:failed, "AI provider failed")}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
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

  defp call_adapter(operation, adapter, state, request, invocation, credentials) do
    result =
      case operation do
        :resolve -> adapter.resolve(state, request, invocation)
        :review -> adapter.review(state, request, invocation)
      end

    normalize_adapter_result(operation, result, credentials)
  rescue
    error -> {:error, ai_error(:failed, Redactor.message(Exception.message(error), credentials))}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
  end

  defp normalize_adapter_result(:resolve, {:ok, %AI.ResolverDecision{} = decision}, _credentials),
    do: {:ok, decision}

  defp normalize_adapter_result(:review, {:ok, %AI.ReviewDecision{} = decision}, _credentials),
    do: {:ok, decision}

  defp normalize_adapter_result(_operation, {:error, category, message}, credentials)
       when category in @adapter_failures and is_binary(message),
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            dispatched?: true
          )}

  defp normalize_adapter_result(
         _operation,
         {:error, category, message, %AI.Usage{} = usage},
         credentials
       )
       when category in @adapter_failures and is_binary(message),
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            usage: usage,
            dispatched?: true
          )}

  defp normalize_adapter_result(_operation, _result, _credentials),
    do:
      {:error,
       AI.Error.exception(
         category: :invalid_output,
         message: "AI output is invalid",
         dispatched?: true
       )}

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.(),
      do: {:error, ai_error(:cancelled, "AI decision was cancelled")},
      else: :ok
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
