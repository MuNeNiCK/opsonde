defmodule Opsonde.Transports.IPMI do
  @moduledoc false

  use Rustler, otp_app: :opsonde, crate: :ipmi_nif

  def send_command(_address, _username, _password, _timeout_ms, _request),
    do: :erlang.nif_error(:nif_not_loaded)

  def exchange_console(address, username, password, timeout, request, invocation) do
    cancellation = cancellation_token()

    task =
      Task.async(fn ->
        sol_exchange(address, username, password, timeout, request, cancellation)
      end)

    await_console(task, cancellation, Map.get(invocation, :cancelled?, fn -> false end))
  end

  defp await_console(task, cancellation, cancelled?) do
    if cancelled?.(), do: cancel(cancellation)

    case Task.yield(task, 20) do
      {:ok, {:ok, result}} ->
        {status, reason} =
          case result.status do
            0 -> {:applied, nil}
            5 -> {:failed, "BMC rejected SOL activation"}
            _ -> {:unknown, "SOL exchange ended without a complete receipt"}
          end

        public =
          %{result | status: status}
          |> Map.put(:reason, reason)
          |> Map.update!(:activation_completion, &if(&1 < 0, do: nil, else: &1))
          |> Map.update!(:deactivation_completion, &if(&1 < 0, do: nil, else: &1))

        {:ok, public}

      {:ok, result} ->
        result

      {:exit, _} ->
        {:ok, %{status: :unknown, output: [], reason: "SOL exchange interrupted"}}

      nil ->
        await_console(task, cancellation, cancelled?)
    end
  end

  def cancellation_token, do: :erlang.nif_error(:nif_not_loaded)
  def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)

  def sol_exchange(_address, _username, _password, _timeout_ms, _request, _token),
    do: :erlang.nif_error(:nif_not_loaded)
end
