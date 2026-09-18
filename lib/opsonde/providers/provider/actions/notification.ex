defmodule Opsonde.Providers.Provider.Actions.Notification do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Providers
  alias Opsonde.Providers.{Notification, Redactor, Registry}

  @statuses [:accepted, :delivered, :failed, :unknown]
  @failures [:failed, :cancelled]

  @impl true
  def run(input, _opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments

    with :ok <- validate_request(request),
         :ok <- ensure_not_cancelled(invocation),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             provider_id,
             request.provider_revision,
             :notification,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_notification_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider) do
      adapter
      |> deliver(state, request, invocation, provider.credentials)
      |> normalize_result(provider.credentials)
    end
  rescue
    _error -> {:error, notification_error(:failed, "Notification provider failed")}
  catch
    _kind, _reason -> {:error, notification_error(:failed, "Notification provider failed")}
  end

  defp validate_request(%Notification.Request{} = request) do
    if positive?(request.provider_revision) and nonempty?(request.report_id) and
         positive?(request.report_revision) and nonempty?(request.destination_id) and
         positive?(request.destination_revision) and nonempty?(request.idempotency_key) and
         is_map(request.payload) do
      :ok
    else
      {:error, notification_error(:failed, "Notification request is invalid")}
    end
  end

  defp validate_request(_request),
    do: {:error, notification_error(:failed, "Notification request is invalid")}

  defp fetch_notification_adapter(adapter_type) do
    case Registry.fetch(adapter_type, Notification) do
      {:ok, adapter} ->
        {:ok, adapter}

      {:error, _reason} ->
        {:error, notification_error(:failed, "Notification adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        {:error, notification_error(:failed, "Notification configuration is invalid")}
    end
  end

  defp deliver(adapter, state, request, invocation, credentials) do
    adapter.deliver(state, request, invocation)
  rescue
    error ->
      unknown(Redactor.message(Exception.message(error), credentials))
  catch
    _kind, _reason -> unknown("Notification outcome is unknown")
  end

  defp normalize_result({:ok, %Notification.Result{status: status} = result}, credentials)
       when status in @statuses and is_map(result.details) and
              (is_nil(result.reference) or is_binary(result.reference)),
       do: {:ok, Redactor.value(result, credentials)}

  defp normalize_result({:error, :timeout, message}, credentials) when is_binary(message),
    do: unknown(Redactor.message(message, credentials)) |> normalize_result(credentials)

  defp normalize_result({:error, category, message}, credentials)
       when category in @failures and is_binary(message),
       do: {:error, notification_error(category, Redactor.message(message, credentials))}

  defp normalize_result(_result, _credentials),
    do: {:error, notification_error(:failed, "Invalid notification result")}

  defp unknown(message) do
    {:ok, %Notification.Result{status: :unknown, details: %{error: message}}}
  end

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.() do
      {:error, notification_error(:cancelled, "Notification delivery was cancelled")}
    else
      :ok
    end
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp notification_error(category, message),
    do: Notification.Error.exception(category: category, message: message)
end
