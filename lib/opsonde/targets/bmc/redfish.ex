defmodule Opsonde.Targets.BMC.Redfish do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.BMC

  @reset_types %{
    "bmc.power.on" => "On",
    "bmc.power.off" => "ForceOff",
    "bmc.power.cycle" => "PowerCycle",
    "bmc.power.reset" => "ForceRestart"
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [:endpoint, :system_path, :expected_uuid, :auth, :cacerts, :timeout]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "bmc-redfish"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    allowed = ~w(endpoint system_path expected_uuid ca_certificate timeout_ms)

    with true <- Enum.all?(Map.keys(configuration), &(&1 in allowed)),
         true <- Enum.sort(Map.keys(credentials)) == ["password", "username"],
         {:ok, endpoint} <- endpoint(configuration["endpoint"]),
         {:ok, system_path} <- system_path(configuration["system_path"]),
         {:ok, expected_uuid} <- required_string(configuration["expected_uuid"], 128),
         {:ok, username} <- required_string(credentials["username"], 255),
         false <- String.contains?(username, ":"),
         {:ok, password} <- required_string(credentials["password"], 4_096),
         {:ok, certificates} <- certificates(configuration["ca_certificate"]),
         timeout when is_integer(timeout) and timeout in 100..60_000 <-
           Map.get(configuration, "timeout_ms", 10_000) do
      {:ok,
       %State{
         endpoint: endpoint,
         system_path: system_path,
         expected_uuid: expected_uuid,
         auth: {:basic, username <> ":" <> password},
         cacerts: certificates,
         timeout: timeout
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{endpoint: endpoint} = state, %{"endpoint" => endpoint}) do
    case system(state) do
      {:ok, _system} -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :identity, message} -> {:error, :capability, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do:
      {:error, :invalid_configuration, "Redfish check endpoint must match Provider configuration"}

  @impl Opsonde.Providers.Target
  def capabilities(state, _invocation) do
    with {:ok, system} <- system(state) do
      capabilities = BMC.capabilities()

      effects =
        case reset_action(state, system) do
          {:ok, _target, allowed} ->
            Enum.filter(capabilities.effects, fn operation ->
              @reset_types[operation.operation] in allowed
            end)

          {:error, _category, _message} ->
            []
        end

      {:ok, %{capabilities | effects: effects}}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with true <- BMC.inspect_request?(request),
         true <- request.connection.endpoint == state.endpoint,
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state),
         {:ok, power} <- power_state(system) do
      {:ok, BMC.observation(power, state.expected_uuid, "redfish")}
    else
      false -> {:error, :failed, "Redfish observation request is invalid"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         {:ok, intent} <- BMC.effect_request(request),
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state),
         {:ok, observed} <- power_state(system),
         :ok <- BMC.expected_state(intent.expected, observed),
         {:ok, action_path, allowed} <- reset_action(state, system),
         reset_type when is_binary(reset_type) <- @reset_types[intent.operation],
         true <- reset_type in allowed,
         :ok <- not_cancelled(invocation) do
      case request(state, :post, action_path, %{"ResetType" => reset_type}) do
        {:ok, status, _headers, _body} when status in [200, 201, 204] ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             reference: intent.operation,
             details: %{"reset_type" => reset_type, "pre_power_state" => observed}
           }}

        {:ok, 202, headers, _body} ->
          task_location =
            List.first(Req.Response.get_header(%Req.Response{headers: headers}, "location"))

          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: intent.operation,
             details:
               %{"reason" => "Redfish task was accepted but is not complete"}
               |> maybe_task_location(task_location)
           }}

        {:error, :transport, _message} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: intent.operation,
             details: %{"reason" => "Redfish reset response was lost after dispatch"}
           }}

        {:error, _category, message} ->
          {:error, :failed, message}

        _ ->
          {:error, :failed, "Redfish reset was rejected"}
      end
    else
      false -> {:error, :failed, "Redfish reset request or allowed value is invalid"}
      {:error, _category, message} -> {:error, :failed, message}
      _ -> {:error, :failed, "Redfish reset type is unavailable"}
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         true <- BMC.inspect_request?(request),
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state),
         {:ok, power} <- power_state(system) do
      verification = BMC.verification(power, state.expected_uuid, "redfish", request.expected)

      verification =
        if request.reference in ["bmc.power.cycle", "bmc.power.reset"],
          do: %{verification | status: :unknown},
          else: verification

      {:ok, verification}
    else
      false -> {:error, :failed, "Redfish verification request is invalid"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp system(state) do
    with {:ok, 200, _headers, collection} <- request(state, :get, "/redfish/v1/Systems", nil),
         members when is_list(members) <- collection["Members"],
         true <- Enum.any?(members, &(&1["@odata.id"] == state.system_path)),
         {:ok, 200, _headers, system} <- request(state, :get, state.system_path, nil),
         true <- system["@odata.id"] == state.system_path,
         true <- system["UUID"] == state.expected_uuid do
      {:ok, system}
    else
      false -> {:error, :identity, "Redfish System identity does not match the configured host"}
      {:error, _category, _message} = error -> error
      _ -> {:error, :failed, "Redfish System response is invalid"}
    end
  end

  defp reset_action(state, system) do
    with %{"target" => target} = action <- get_in(system, ["Actions", "#ComputerSystem.Reset"]),
         {:ok, path} <- action_path(state, target),
         {:ok, allowed} <- allowable_values(state, action),
         true <- Enum.all?(allowed, &is_binary/1) do
      {:ok, path, allowed}
    else
      _ -> {:error, :failed, "Redfish System does not advertise a usable reset action"}
    end
  end

  defp allowable_values(_state, %{"ResetType@Redfish.AllowableValues" => allowed})
       when is_list(allowed),
       do: {:ok, allowed}

  defp allowable_values(state, %{"@Redfish.ActionInfo" => info_uri}) do
    with {:ok, info_path} <- resource_path(state, info_uri),
         true <- String.starts_with?(info_path, state.system_path <> "/"),
         {:ok, 200, _headers, %{"Parameters" => parameters}} <-
           request(state, :get, info_path, nil),
         true <- is_list(parameters),
         %{"AllowableValues" => allowed} <-
           Enum.find(parameters, &(is_map(&1) and &1["Name"] == "ResetType")),
         true <- is_list(allowed) do
      {:ok, allowed}
    else
      _ -> {:error, :failed, "Redfish reset ActionInfo is unavailable"}
    end
  end

  defp allowable_values(_state, _action),
    do: {:error, :failed, "Redfish reset allowable values are unavailable"}

  defp action_path(state, target) when is_binary(target) do
    with {:ok, path} <- resource_path(state, target),
         true <- String.starts_with?(path, state.system_path <> "/Actions/") do
      {:ok, path}
    else
      _ -> {:error, :failed, "Redfish reset action target is outside the selected System"}
    end
  end

  defp action_path(_state, _target), do: {:error, :failed, "Redfish reset action is invalid"}

  defp resource_path(state, target) when is_binary(target) do
    uri = URI.parse(target)
    endpoint = URI.parse(state.endpoint)

    same_origin =
      is_nil(uri.scheme) or
        (uri.scheme == endpoint.scheme and uri.host == endpoint.host and
           (uri.port || 443) == (endpoint.port || 443))

    if same_origin and is_nil(uri.userinfo) and is_nil(uri.query) and
         is_nil(uri.fragment) and is_binary(uri.path) and
         String.starts_with?(uri.path, "/redfish/v1/") and
         byte_size(uri.path) <= 2_048 do
      {:ok, uri.path}
    else
      {:error, :failed, "Redfish resource URI is outside the BMC origin"}
    end
  end

  defp resource_path(_state, _target), do: {:error, :failed, "Redfish resource URI is invalid"}

  defp maybe_task_location(details, location) when is_binary(location),
    do: Map.put(details, "task_location", location)

  defp maybe_task_location(details, _location), do: details

  defp power_state(%{"PowerState" => "On"}), do: {:ok, "on"}
  defp power_state(%{"PowerState" => "Off"}), do: {:ok, "off"}
  defp power_state(_system), do: {:error, :failed, "Redfish PowerState is unavailable"}

  defp request(state, method, path, body) do
    host = URI.parse(state.endpoint).host

    options = [
      method: method,
      url: state.endpoint <> path,
      auth: state.auth,
      headers: [{"accept", "application/json"}, {"content-type", "application/json"}],
      connect_options: [
        timeout: state.timeout,
        transport_opts: [
          verify: :verify_peer,
          cacerts: state.cacerts,
          verify_fun: verify_fun(state.cacerts, host)
        ]
      ],
      receive_timeout: state.timeout,
      retry: false,
      redirect: false,
      decode_body: false
    ]

    options = if is_nil(body), do: options, else: Keyword.put(options, :json, body)

    case Req.request(options) do
      {:ok, %Req.Response{status: status, headers: headers, body: raw}}
      when is_binary(raw) and byte_size(raw) <= 65_536 ->
        cond do
          status in 200..299 ->
            decoded = if raw == "", do: %{}, else: Jason.decode(raw)

            case decoded do
              {:ok, value} when is_map(value) -> {:ok, status, headers, value}
              %{} = value -> {:ok, status, headers, value}
              _ -> {:error, :failed, "Redfish response is not a JSON object"}
            end

          status in [401, 403] ->
            {:error, :authentication, "Redfish authentication failed"}

          true ->
            {:error, :rejected, "Redfish request was rejected (HTTP #{status})"}
        end

      {:ok, _response} ->
        {:error, :failed, "Redfish response exceeded its limit"}

      {:error, _error} ->
        {:error, :transport, "Redfish endpoint is unreachable"}
    end
  rescue
    _ -> {:error, :transport, "Redfish request failed"}
  end

  defp verify_fun(trusted, host) do
    callback = fn
      cert, {:bad_cert, :selfsigned_peer}, state ->
        der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)

        if der in state.trusted and valid_hostname?(cert, state.host),
          do: {:valid, state},
          else: {:fail, :selfsigned_peer}

      _cert, {:bad_cert, reason}, _state ->
        {:fail, reason}

      _cert, {:extension, _extension}, state ->
        {:unknown, state}

      _cert, :valid, state ->
        {:valid, state}

      cert, :valid_peer, state ->
        if valid_hostname?(cert, state.host),
          do: {:valid, state},
          else: {:fail, :hostname_check_failed}
    end

    {callback, %{trusted: trusted, host: host}}
  end

  defp valid_hostname?(certificate, host) do
    references =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} -> [{:ip, address}]
        {:error, :einval} -> [{:dns_id, String.to_charlist(host)}]
      end

    :public_key.pkix_verify_hostname(certificate, references)
  end

  defp endpoint(value) when is_binary(value) and byte_size(value) <= 255 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and path in [nil, ""] and
             (is_nil(uri.port) or uri.port in 1..65_535) ->
        {:ok, URI.to_string(%{uri | path: nil})}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp system_path(path) when is_binary(path) and byte_size(path) <= 512 do
    if Regex.match?(~r{^/redfish/v1/Systems/[A-Za-z0-9._~-]+$}, path),
      do: {:ok, path},
      else: {:error, :invalid_system_path}
  end

  defp system_path(_path), do: {:error, :invalid_system_path}

  defp certificates(pem) when is_binary(pem) and byte_size(pem) <= 65_536 do
    certs =
      pem
      |> :public_key.pem_decode()
      |> Enum.flat_map(fn
        {:Certificate, der, :not_encrypted} -> [der]
        _ -> []
      end)

    if certs == [], do: {:error, :invalid_ca}, else: {:ok, certs}
  rescue
    _ -> {:error, :invalid_ca}
  end

  defp certificates(_pem), do: {:error, :invalid_ca}

  defp required_string(value, max) when is_binary(value) do
    if byte_size(value) in 1..max, do: {:ok, value}, else: {:error, :invalid_string}
  end

  defp required_string(_value, _max), do: {:error, :invalid_string}

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "Redfish request was cancelled"}, else: :ok
  end

  defp not_cancelled(_invocation), do: :ok

  defp read_error(:transport, message), do: {:error, :retryable, message}
  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(_category, message), do: {:error, :failed, message}
end
