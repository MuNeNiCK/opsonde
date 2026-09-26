defmodule Opsonde.Targets.BMC.IPMI do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.BMC
  alias Opsonde.Targets.BMC.IPMINative

  @max_data_bytes 2048

  defmodule State do
    @moduledoc false
    @enforce_keys [:endpoint, :host, :port, :user, :password, :timeout]
    @derive {Inspect, except: [:password]}
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "bmc-ipmi"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with true <- Enum.sort(Map.keys(configuration)) in [["endpoint"], ["endpoint", "timeout_ms"]],
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
    with {:ok, 0, device} <- command(state, 0x06, 0x01, []),
         true <- length(device) >= 11,
         {:ok, _power} <- read_power(state) do
      :ok
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      _ -> {:error, :unreachable, "IPMI BMC check failed"}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IPMI check endpoint must match Provider configuration"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    capabilities = BMC.capabilities()
    api = BMC.api_capabilities()
    effects = Enum.reject(capabilities.effects, &(&1.operation == "bmc.power.cycle"))

    {:ok,
     %Target.Capabilities{
       observations: capabilities.observations ++ api.observations,
       effects: effects ++ api.effects
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, %{capability: "observe.bmc_api"} = request, invocation),
    do: api_observe(state, request, invocation)

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
  def effect(%State{}, %{operation: "bmc.power.cycle"}, _invocation),
    do: {:error, :failed, "IPMI power cycle support cannot be verified for this BMC"}

  def effect(%State{} = state, %{capability: "effect.bmc_api"} = request, invocation),
    do: api_effect(state, request, invocation)

  def effect(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         {:ok, intent} <- BMC.effect_request(request),
         :ok <- not_cancelled(invocation),
         {:ok, observed} <- read_power(state),
         :ok <- BMC.expected_state(intent.expected, observed),
         :ok <- not_cancelled(invocation) do
      data =
        case intent.operation do
          "bmc.power.off" -> [0]
          "bmc.power.on" -> [1]
          "bmc.power.reset" -> [3]
        end

      case command(state, 0x00, 0x02, data) do
        {:ok, 0, _response} ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             reference: intent.operation,
             details: %{"command" => intent.operation, "pre_power_state" => observed}
           }}

        {:ok, _completion, _response} ->
          {:error, :failed, "IPMI BMC rejected chassis control"}

        {:error, :outcome_unknown, _message} ->
          unknown_effect(intent.operation, "IPMI chassis control response was lost")

        {:error, _category, message} ->
          {:error, :failed, message}
      end
    else
      false -> {:error, :failed, "IPMI endpoint does not match checked Provider"}
      {:error, _category, message} -> {:error, :failed, message}
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

  defp api_observe(state, request, invocation) do
    with {:ok, netfn, opcode, data} <- api_request(state, request),
         :ok <- not_cancelled(invocation),
         {:ok, completion, response} <- command(state, netfn, opcode, data) do
      facts =
        %{"completion_code" => completion, "accepted" => completion == 0}
        |> maybe_response(response, map_size(request.secret_values) > 0)

      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [
           %{
             "source" => "ipmi",
             "netfn" => netfn,
             "command" => opcode,
             "completion_code" => completion
           }
         ]
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp api_effect(state, request, invocation) do
    with {:ok, netfn, opcode, data} <- api_request(state, request),
         :ok <- not_cancelled(invocation) do
      case command(state, netfn, opcode, data) do
        {:ok, completion, response} ->
          details =
            %{"netfn" => netfn, "command" => opcode, "completion_code" => completion}
            |> maybe_response(response, map_size(request.secret_values) > 0)

          {:ok,
           %Target.EffectResult{
             status: if(completion == 0, do: :applied, else: :failed),
             reference: request.operation,
             details: details
           }}

        {:error, :outcome_unknown, _message} ->
          unknown_effect(request.operation, "IPMI command response was lost after dispatch")

        {:error, _category, message} ->
          {:error, :failed, message}
      end
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  defp unknown_effect(reference, reason) do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"reason" => reason}
     }}
  end

  defp api_request(state, request) do
    protocol = request.protocol_request

    with true <- request.connection.endpoint == state.endpoint,
         true <- request.selectors == %{},
         %{"netfn" => netfn, "command" => opcode} <- protocol,
         true <- Enum.sort(Map.keys(protocol)) == ["command", "netfn"],
         true <- is_integer(netfn) and netfn in 0..62 and rem(netfn, 2) == 0,
         true <- is_integer(opcode) and opcode in 0..255,
         true <- request.secret_values == %{} or Map.keys(request.secret_values) == ["/data_hex"],
         {:ok, data} <- request_data(request.parameters) do
      {:ok, netfn, opcode, data}
    else
      _ -> {:error, :failed, "IPMI API request is invalid for this Access Method"}
    end
  end

  defp request_data(%{} = parameters) when map_size(parameters) == 0, do: {:ok, []}

  defp request_data(%{"data_hex" => hex} = parameters)
       when map_size(parameters) == 1 and is_binary(hex) and
              byte_size(hex) <= @max_data_bytes * 2 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} -> {:ok, :binary.bin_to_list(data)}
      :error -> {:error, :invalid_data}
    end
  end

  defp request_data(_parameters), do: {:error, :invalid_data}

  defp maybe_response(details, _response, true), do: Map.put(details, "response_redacted", true)

  defp maybe_response(details, response, false),
    do:
      Map.put(
        details,
        "data_hex",
        response |> :erlang.list_to_binary() |> Base.encode16(case: :lower)
      )

  defp read_power(state) do
    case command(state, 0x00, 0x01, []) do
      {:ok, 0, [status | _rest]} -> {:ok, if(Bitwise.band(status, 1) == 1, do: "on", else: "off")}
      {:ok, 0, _response} -> {:error, :failed, "IPMI BMC returned no power state"}
      {:ok, _completion, _response} -> {:error, :failed, "IPMI BMC rejected chassis status"}
      {:error, _category, _message} = error -> error
    end
  end

  defp command(state, netfn, opcode, data) do
    with {:ok, address} <- resolve_address(state.host, state.port, state.timeout) do
      native_command(state, address, netfn, opcode, data)
    end
  end

  defp native_command(state, address, netfn, opcode, data) do
    case IPMINative.send_command(
           address,
           state.user,
           state.password,
           state.timeout,
           netfn,
           opcode,
           data
         ) do
      {:ok, {completion, response}}
      when is_integer(completion) and completion in 0..255 and is_list(response) and
             length(response) <= 4096 ->
        {:ok, completion, response}

      {:error, "authentication"} ->
        {:error, :authentication, "IPMI authentication failed"}

      {:error, "outcome_unknown"} ->
        {:error, :outcome_unknown, "IPMI command response was lost"}

      {:error, "unsupported"} ->
        {:error, :failed, "IPMI BMC transport is unsupported"}

      {:error, "invalid_request"} ->
        {:error, :failed, "IPMI command is invalid"}

      _ ->
        {:error, :unreachable, "IPMI BMC is unreachable"}
    end
  end

  defp resolve_address(host, port, timeout) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, socket_address(ip, port)}

      {:error, _reason} ->
        case :inet.getaddr(String.to_charlist(host), :inet, timeout) do
          {:ok, ip} -> {:ok, socket_address(ip, port)}
          {:error, _reason} -> resolve_ipv6(host, port, timeout)
        end
    end
  end

  defp resolve_ipv6(host, port, timeout) do
    case :inet.getaddr(String.to_charlist(host), :inet6, timeout) do
      {:ok, ip} -> {:ok, socket_address(ip, port)}
      {:error, _reason} -> {:error, :unreachable, "IPMI BMC address could not be resolved"}
    end
  end

  defp socket_address(ip, port) when tuple_size(ip) == 4,
    do: "#{:inet.ntoa(ip)}:#{port}"

  defp socket_address(ip, port) when tuple_size(ip) == 8,
    do: "[#{:inet.ntoa(ip)}]:#{port}"

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
        {:ok, value, host, port || 623}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp short_secret(value) when is_binary(value) and byte_size(value) in 1..16,
    do: {:ok, value}

  defp short_secret(_value), do: {:error, :invalid_secret}

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "IPMI request was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok

  defp read_error(:unreachable, message), do: {:error, :retryable, message}
  defp read_error(:outcome_unknown, message), do: {:error, :timeout, message}
  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(_category, message), do: {:error, :failed, message}
end
