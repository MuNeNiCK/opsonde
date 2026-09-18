defmodule OpsondeWeb.SignalWebhookController do
  use OpsondeWeb, :controller

  alias Opsonde.{Cases, Providers}
  alias Opsonde.Providers.Signal

  def alertmanager(conn, %{"provider_id" => provider_id}),
    do: ingest(conn, provider_id, "alertmanager-webhook")

  def zabbix(conn, %{"provider_id" => provider_id}),
    do: ingest(conn, provider_id, "zabbix-webhook")

  defp ingest(conn, provider_id, adapter_type) do
    with {:ok, provider} <- provider(provider_id, adapter_type),
         envelope <- envelope(conn),
         {:ok, receipt} <-
           Cases.ingest_signal(
             provider.id,
             provider.revision,
             envelope,
             %{},
             authorize?: false
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{receipt_id: receipt.receipt_id})
    else
      {:error, :not_found} -> error(conn, :not_found, "Signal endpoint was not found")
      {:error, failure} -> signal_error(conn, failure)
    end
  end

  defp provider(id, adapter_type) do
    case Providers.get_provider(id, authorize?: false, not_found_error?: false) do
      {:ok, %{kind: :signal, adapter_type: ^adapter_type} = provider} -> {:ok, provider}
      _missing -> {:error, :not_found}
    end
  end

  defp envelope(conn) do
    %Signal.Envelope{
      body: OpsondeWeb.CacheBodyReader.raw_body(conn),
      headers: headers(conn),
      received_at: DateTime.utc_now()
    }
  end

  defp headers(conn) do
    Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp signal_error(conn, failure) do
    case find_signal_error(failure) do
      %Signal.Error{category: :authentication} ->
        error(conn, :unauthorized, "Webhook authentication failed")

      %Signal.Error{category: :invalid_input, message: message} ->
        error(conn, :unprocessable_entity, message)

      _failure ->
        error(conn, :service_unavailable, "Signal could not be accepted")
    end
  end

  defp find_signal_error(%Signal.Error{} = error), do: error

  defp find_signal_error(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &find_signal_error/1)
  end

  defp find_signal_error(%{} = error) do
    error
    |> Map.values()
    |> Enum.find_value(&find_signal_error/1)
  end

  defp find_signal_error(_error), do: nil

  defp error(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end
end
