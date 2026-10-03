defmodule Opsonde.Transports.IPMI do
  @moduledoc false

  use Rustler, otp_app: :opsonde, crate: :ipmi_nif

  def send_command(_address, _username, _password, _timeout_ms, _request, _token),
    do: :erlang.nif_error(:nif_not_loaded)

  def exchange_command(address, username, password, timeout, request, invocation) do
    exchange(invocation, fn cancellation ->
      send_command(address, username, password, timeout, request, cancellation)
    end)
  end

  def exchange_console(address, username, password, timeout, request, invocation) do
    case exchange(invocation, fn cancellation ->
           sol_exchange(address, username, password, timeout, request, cancellation)
         end) do
      {:ok, result} ->
        {status, reason} =
          case result.status do
            0 -> {:applied, nil}
            5 -> {:failed, "BMC rejected SOL activation"}
            _ -> {:unknown, "SOL exchange ended without a complete receipt"}
          end

        {:ok,
         %{result | status: status}
         |> Map.put(:reason, reason)
         |> Map.update!(:activation_completion, &if(&1 < 0, do: nil, else: &1))
         |> Map.update!(:deactivation_completion, &if(&1 < 0, do: nil, else: &1))}

      {:error, "outcome_unknown"} ->
        {:ok, %{status: :unknown, output: [], reason: "SOL exchange interrupted"}}

      result ->
        result
    end
  end

  defp exchange(invocation, native_call) do
    cancellation = cancellation_token()
    task = Task.async(fn -> native_call.(cancellation) end)
    await_exchange(task, cancellation, Map.get(invocation, :cancelled?, fn -> false end))
  end

  defp await_exchange(task, cancellation, cancelled?) do
    if cancelled?.(), do: cancel(cancellation)

    case Task.yield(task, 20) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, "outcome_unknown"}

      nil ->
        await_exchange(task, cancellation, cancelled?)
    end
  end

  def cancellation_token, do: :erlang.nif_error(:nif_not_loaded)
  def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)

  def sol_exchange(_address, _username, _password, _timeout_ms, _request, _token),
    do: :erlang.nif_error(:nif_not_loaded)
end
