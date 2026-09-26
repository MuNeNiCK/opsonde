defmodule Opsonde.Targets.BMC.IPMI do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.BMC

  defmodule State do
    @moduledoc false
    @enforce_keys [:endpoint, :host, :port, :user, :password, :timeout]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "bmc-ipmi"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with true <-
           Enum.sort(Map.keys(configuration)) in [
             ["endpoint"],
             ["endpoint", "timeout_ms"]
           ],
         true <- Enum.sort(Map.keys(credentials)) == ["password", "username"],
         {:ok, endpoint, host, port} <- endpoint(configuration["endpoint"]),
         {:ok, user} <- short_secret(credentials["username"]),
         {:ok, password} <- short_secret(credentials["password"]),
         timeout when is_integer(timeout) and timeout in 100..30_000 <-
           Map.get(configuration, "timeout_ms", 3_000) do
      {:ok,
       %State{
         endpoint: endpoint,
         host: host,
         port: port,
         user: user,
         password: password,
         timeout: timeout
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{endpoint: endpoint} = state, %{"endpoint" => endpoint}) do
    case with_session(state, fn session ->
           with {:ok, _device} <- :eipmi.get_device_id(session),
                {:ok, status} <- :eipmi.get_chassis_status(session) do
             power_state(status)
           end
         end) do
      {:ok, _state} -> :ok
      {:error, :authentication, _message} = error -> error
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IPMI check endpoint must match Provider configuration"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation), do: {:ok, BMC.capabilities()}

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with true <- BMC.inspect_request?(request),
         true <- request.connection.endpoint == state.endpoint,
         :ok <- not_cancelled(invocation),
         {:ok, power} <- read_power(state) do
      {:ok, BMC.observation(power, state.endpoint, "ipmi")}
    else
      false -> {:error, :failed, "IPMI observation request is invalid"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         {:ok, intent} <- BMC.effect_request(request),
         :ok <- not_cancelled(invocation),
         {:ok, result} <- effect_in_session(state, intent, invocation) do
      {:ok, result}
    else
      false ->
        {:error, :failed, "IPMI endpoint does not match checked Provider"}

      {:error, :after_dispatch, message} ->
        {:ok,
         %Target.EffectResult{
           status: :unknown,
           reference: request.operation,
           details: %{"reason" => message}
         }}

      {:error, _category, message} ->
        {:error, :failed, message}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         true <- BMC.inspect_request?(request),
         :ok <- not_cancelled(invocation),
         {:ok, power} <- read_power(state) do
      verification = BMC.verification(power, state.endpoint, "ipmi", request.expected)

      verification =
        if request.reference in ["bmc.power.cycle", "bmc.power.reset"],
          do: %{verification | status: :unknown},
          else: verification

      {:ok, verification}
    else
      false -> {:error, :failed, "IPMI verification request is invalid"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp effect_in_session(state, intent, invocation) do
    with_session(state, fn session ->
      with {:ok, status} <- :eipmi.get_chassis_status(session),
           {:ok, observed} <- power_state(status),
           :ok <- BMC.expected_state(intent.expected, observed),
           :ok <- not_cancelled(invocation) do
        command =
          case intent.operation do
            "bmc.power.on" -> :power_up
            "bmc.power.off" -> :power_down
            "bmc.power.cycle" -> :power_cycle
            "bmc.power.reset" -> :hard_reset
          end

        case chassis_control(session, command) do
          :ok ->
            {:ok,
             %Target.EffectResult{
               status: :applied,
               reference: intent.operation,
               details: %{"command" => intent.operation, "pre_power_state" => observed}
             }}

          {:error, {:bmc_error, _reason}} ->
            {:error, :failed, "IPMI BMC rejected chassis control"}

          _ ->
            {:error, :after_dispatch, "IPMI chassis control result is unknown"}
        end
      end
    end)
  end

  defp chassis_control(session, command) do
    :eipmi.chassis_control(session, command)
  rescue
    _ -> {:error, :after_dispatch, "IPMI chassis control result is unknown"}
  catch
    _, _ -> {:error, :after_dispatch, "IPMI chassis control result is unknown"}
  end

  defp read_power(state) do
    with_session(state, fn session ->
      with {:ok, status} <- :eipmi.get_chassis_status(session) do
        power_state(status)
      end
    end)
  end

  defp with_session(state, callback) do
    options = [
      user: state.user,
      password: state.password,
      port: state.port,
      timeout: state.timeout,
      rq_auth_type: :rmcp_plus,
      rakp_auth_type: :hmac_sha1,
      integrity_type: :hmac_sha1_96,
      encrypt_type: :aes_cbc
    ]

    case :eipmi.open(state.host, options) do
      {:ok, session} ->
        try do
          case callback.(session) do
            {:error, _reason} -> {:error, :unreachable, "IPMI BMC request failed"}
            result -> result
          end
        after
          try do
            :eipmi.close(session)
          catch
            _, _ -> :ok
          end
        end

      _ ->
        {:error, :unreachable, "IPMI session could not be established"}
    end
  rescue
    _ -> {:error, :unreachable, "IPMI session failed"}
  catch
    _, _ -> {:error, :unreachable, "IPMI session failed"}
  end

  defp power_state(status) do
    case Keyword.get(status, :power_status) do
      1 -> {:ok, "on"}
      0 -> {:ok, "off"}
      _ -> {:error, :failed, "IPMI BMC returned no power state"}
    end
  end

  defp endpoint(value) when is_binary(value) and byte_size(value) <= 255 do
    case URI.parse(value) do
      %URI{
        scheme: "ipmi",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and path in [nil, ""] and
             (is_nil(port) or port in 1..65_535) ->
        {:ok, value, String.to_charlist(host), port || 623}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp short_secret(value) when is_binary(value) and byte_size(value) in 1..16,
    do: {:ok, String.to_charlist(value)}

  defp short_secret(_value), do: {:error, :invalid_secret}

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "IPMI request was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok

  defp read_error(:unreachable, message), do: {:error, :retryable, message}
  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(_category, message), do: {:error, :failed, message}
end
