defmodule Opsonde.Targets.IOSXE.RESTCONF do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.IOSXE

  @native "native.restconf"

  @configuration_keys ~w(ca_certificate connect_timeout_ms request_timeout_ms max_body_bytes)
  @credential_keys ~w(username password)

  defmodule State do
    @moduledoc false
    @enforce_keys [:auth, :cacerts, :connect_timeout, :request_timeout, :max_body_bytes]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "ios-xe-restconf"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, username} <- required_string(credentials, "username", 255),
         false <- String.contains?(username, ":"),
         {:ok, password} <- required_string(credentials, "password", 4_096),
         {:ok, cacerts} <- certificates(configuration),
         {:ok, connect_timeout} <- timeout(configuration, "connect_timeout_ms", 10_000),
         {:ok, request_timeout} <- timeout(configuration, "request_timeout_ms", 30_000),
         {:ok, max_body_bytes} <- body_limit(configuration) do
      {:ok,
       %State{
         auth: {:basic, username <> ":" <> password},
         cacerts: cacerts,
         connect_timeout: connect_timeout,
         request_timeout: request_timeout,
         max_body_bytes: max_body_bytes
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with {:ok, endpoint} <- endpoint(endpoint),
         {:ok, _body} <-
           request(
             state,
             endpoint,
             :get,
             "/restconf/data/ietf-restconf-monitoring:restconf-state/capabilities",
             nil,
             fn -> false end,
             :read
           ) do
      :ok
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IOS XE RESTCONF check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    capabilities = IOSXE.capabilities()

    {:ok,
     %{
       capabilities
       | observations: capabilities.observations ++ [native_observation()],
         effects: capabilities.effects ++ [native_effect()]
     }}
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, %{capability: @native} = target_request, invocation) do
    with {:ok, endpoint} <- endpoint(target_request.connection.endpoint),
         {:ok, method, path, body} <- native_request(target_request, "request.observe"),
         true <- method in [:get, :head],
         {:ok, response} <-
           request(state, endpoint, method, path, body, cancelled?(invocation), :read) do
      IOSXE.observation(%{"response" => response})
    else
      false -> {:error, :failed, "RESTCONF observation must use GET or HEAD"}
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  def observe(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- endpoint(request.connection.endpoint),
         {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts} <- observe_operation(state, endpoint, operation, cancelled?(invocation)) do
      IOSXE.observation(facts)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, %{capability: @native} = target_request, invocation) do
    with {:ok, endpoint} <- endpoint(target_request.connection.endpoint),
         {:ok, method, path, body} <- native_request(target_request, "request.execute"),
         true <- method in [:post, :put, :patch, :delete],
         {:ok, response} <-
           request(state, endpoint, method, path, body, cancelled?(invocation), :effect) do
      IOSXE.applied(%{"response" => response})
    else
      false -> {:error, :failed, "RESTCONF effect requires a mutating HTTP method"}
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  def effect(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- endpoint(request.connection.endpoint),
         {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(state, endpoint, operation, cancelled?(invocation))
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, %{capability: @native} = target_request, invocation) do
    with {:ok, endpoint} <- endpoint(target_request.connection.endpoint),
         {:ok, method, path, body} <- native_request(target_request, "request.observe"),
         true <- method in [:get, :head],
         {:ok, response} <-
           request(state, endpoint, method, path, body, cancelled?(invocation), :read) do
      IOSXE.verification(%{"response" => response}, target_request.expected)
    else
      false -> {:error, :failed, "RESTCONF verification must use GET or HEAD"}
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  def verify(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- endpoint(request.connection.endpoint),
         {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts} <-
           observe_operation(state, endpoint, {:interface, name}, cancelled?(invocation)) do
      IOSXE.verification(facts, expected)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  defp observe_operation(state, endpoint, :system, cancelled?) do
    with {:ok, hostname} <-
           request(
             state,
             endpoint,
             :get,
             "/restconf/data/Cisco-IOS-XE-native:native/hostname",
             nil,
             cancelled?,
             :read
           ),
         {:ok, version} <-
           request(
             state,
             endpoint,
             :get,
             "/restconf/data/Cisco-IOS-XE-native:native/version",
             nil,
             cancelled?,
             :read
           ),
         %{"Cisco-IOS-XE-native:hostname" => hostname} <- hostname,
         %{"Cisco-IOS-XE-native:version" => version} <- version do
      {:ok, %{"hostname" => hostname, "version" => version}}
    else
      {:error, _category, _message} = error -> error
      _response -> {:error, :failed, "IOS XE RESTCONF system response is invalid"}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, cancelled?) do
    key = URI.encode_www_form(name)

    with {:ok, configuration} <-
           request(
             state,
             endpoint,
             :get,
             "/restconf/data/ietf-interfaces:interfaces/interface=#{key}",
             nil,
             cancelled?,
             :read
           ),
         {:ok, operational} <-
           request(
             state,
             endpoint,
             :get,
             "/restconf/data/ietf-interfaces:interfaces-state/interface=#{key}",
             nil,
             cancelled?,
             :read
           ),
         {:ok, facts} <- interface_facts(name, configuration, operational) do
      {:ok, facts}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, cancelled?) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["description"], expected, "description"),
         {:ok, _body} <-
           patch_interface(state, endpoint, name, %{"description" => desired}, cancelled?) do
      IOSXE.applied(%{"interface" => name, "description" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, cancelled?) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, cancelled?),
         :ok <- matches(facts["enabled"], expected, "enabled"),
         {:ok, _body} <-
           patch_interface(state, endpoint, name, %{"enabled" => desired}, cancelled?) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp patch_interface(state, endpoint, name, values, cancelled?) do
    key = URI.encode_www_form(name)
    body = %{"ietf-interfaces:interface" => Map.put(values, "name", name)}

    request(
      state,
      endpoint,
      :patch,
      "/restconf/data/ietf-interfaces:interfaces/interface=#{key}",
      body,
      cancelled?,
      :effect
    )
  end

  defp request(state, endpoint, method, path, body, cancelled?, phase) do
    host = URI.parse(endpoint).host

    operation = fn ->
      options = [
        method: method,
        url: endpoint <> path,
        auth: state.auth,
        headers: [
          {"accept", "application/yang-data+json"},
          {"content-type", "application/yang-data+json"}
        ],
        connect_options: [
          timeout: state.connect_timeout,
          transport_opts: [
            verify: :verify_peer,
            cacerts: state.cacerts,
            partial_chain: partial_chain(state.cacerts),
            verify_fun: verify_fun(state.cacerts, host)
          ]
        ],
        receive_timeout: state.request_timeout,
        retry: false,
        redirect: false,
        decode_body: false
      ]

      options = if is_nil(body), do: options, else: Keyword.put(options, :json, body)
      Req.request(options)
    end

    run(operation, cancelled?, state.request_timeout, phase)
    |> normalize_response(state.max_body_bytes, phase)
  end

  defp run(operation, cancelled?, timeout, phase) do
    if cancelled?.() do
      {:error, :cancelled, "IOS XE RESTCONF operation was cancelled"}
    else
      task = Task.async(fn -> safely(operation) end)
      await(task, cancelled?, System.monotonic_time(:millisecond) + timeout, phase)
    end
  rescue
    _error -> {:error, failure_category(phase), "IOS XE RESTCONF operation failed"}
  end

  defp await(task, cancelled?, deadline, phase) do
    cond do
      cancelled?.() ->
        Task.shutdown(task, :brutal_kill)
        {:error, after_dispatch(phase, :cancelled), "IOS XE RESTCONF operation was cancelled"}

      System.monotonic_time(:millisecond) >= deadline ->
        Task.shutdown(task, :brutal_kill)
        {:error, after_dispatch(phase, :timeout), "IOS XE RESTCONF operation timed out"}

      true ->
        case Task.yield(task, 20) do
          {:ok, result} ->
            result

          {:exit, _reason} ->
            {:error, failure_category(phase), "IOS XE RESTCONF operation failed"}

          nil ->
            await(task, cancelled?, deadline, phase)
        end
    end
  end

  defp safely(operation) do
    operation.()
  rescue
    _error -> {:error, :transport_failure}
  catch
    _kind, _reason -> {:error, :transport_failure}
  end

  defp normalize_response({:ok, %Req.Response{status: status, body: body}}, limit, _phase)
       when status in 200..299 and is_binary(body) and byte_size(body) <= limit do
    if body == "" do
      {:ok, %{}}
    else
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        _error -> {:error, :failed, "IOS XE RESTCONF response is invalid"}
      end
    end
  end

  defp normalize_response({:ok, %Req.Response{status: 401}}, _limit, _phase),
    do: {:error, :authentication, "IOS XE RESTCONF authentication failed"}

  defp normalize_response({:ok, %Req.Response{status: 403}}, _limit, _phase),
    do: {:error, :forbidden, "IOS XE RESTCONF request is forbidden"}

  defp normalize_response({:ok, %Req.Response{status: 404}}, _limit, _phase),
    do: {:error, :not_found, "IOS XE RESTCONF resource was not found"}

  defp normalize_response({:ok, %Req.Response{status: 409}}, _limit, _phase),
    do: {:error, :conflict, "IOS XE RESTCONF resource changed"}

  defp normalize_response({:ok, %Req.Response{status: status}}, _limit, _phase)
       when status in 400..599,
       do: {:error, :rejected, "IOS XE RESTCONF request was rejected"}

  defp normalize_response({:ok, %Req.Response{}}, _limit, phase),
    do: {:error, failure_category(phase), "IOS XE RESTCONF response exceeded its limit"}

  defp normalize_response({:error, %Req.TransportError{reason: :timeout}}, _limit, phase),
    do: {:error, after_dispatch(phase, :timeout), "IOS XE RESTCONF operation timed out"}

  defp normalize_response({:error, _error}, _limit, phase),
    do: {:error, failure_category(phase), "IOS XE RESTCONF endpoint is unreachable"}

  defp normalize_response({:error, _category, _message} = error, _limit, _phase), do: error

  defp normalize_response(_response, _limit, phase),
    do: {:error, failure_category(phase), "IOS XE RESTCONF response is invalid"}

  defp interface_facts(
         name,
         %{"ietf-interfaces:interface" => configuration},
         %{"ietf-interfaces:interface" => operational}
       ) do
    {:ok,
     %{
       "name" => name,
       "description" => configuration["description"],
       "enabled" => Map.get(configuration, "enabled", true),
       "admin_status" => operational["admin-status"],
       "oper_status" => operational["oper-status"],
       "input_errors" => get_in(operational, ["statistics", "in-errors"]),
       "output_errors" => get_in(operational, ["statistics", "out-errors"])
     }}
  end

  defp interface_facts(_name, _configuration, _operational),
    do: {:error, :failed, "IOS XE RESTCONF interface response is invalid"}

  defp matches(observed, expected, _field) when observed == expected, do: :ok
  defp matches(observed, _expected, field), do: {:stale, observed, field}

  defp native_request(request, operation) do
    case request do
      %{
        capability: @native,
        operation: ^operation,
        selectors: selectors,
        parameters: %{"method" => method, "path" => path} = parameters
      }
      when selectors == %{} and is_binary(method) and is_binary(path) ->
        method = method |> String.downcase() |> String.to_existing_atom()
        body = Map.get(parameters, "body")

        if valid_native_path?(path) and method in [:get, :head, :post, :put, :patch, :delete] and
             (is_nil(body) or is_map(body)),
           do: {:ok, method, path, body},
           else: {:error, :failed, "RESTCONF native request is invalid"}

      _request ->
        {:error, :failed, "RESTCONF native request is invalid"}
    end
  rescue
    ArgumentError -> {:error, :failed, "RESTCONF native request method is invalid"}
  end

  defp valid_native_path?(path),
    do:
      byte_size(path) in 1..2_048 and String.starts_with?(path, "/restconf/") and
        not String.contains?(path, ["..", "#"])

  defp native_observation do
    output = native_output_schema()

    %Target.Operation{
      capability: @native,
      operation: "request.observe",
      description: "Send one exact non-mutating RESTCONF request and return its response",
      input_schema: native_schema(["get", "head"]),
      output_schema: output,
      verification_schema: Map.put(output, "minProperties", 1),
      native?: true
    }
  end

  defp native_effect do
    %Target.Operation{
      capability: @native,
      operation: "request.execute",
      description: "Send one exact mutating RESTCONF request after authority review",
      input_schema: native_schema(["post", "put", "patch", "delete"]),
      native?: true
    }
  end

  defp native_schema(methods) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "method" => %{"type" => "string", "enum" => methods},
            "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
            "body" => %{"type" => ["object", "null"]}
          },
          "required" => ["method", "path"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp native_output_schema do
    %{
      "type" => "object",
      "properties" => %{"response" => %{"type" => "object"}},
      "required" => ["response"],
      "additionalProperties" => false
    }
  end

  defp endpoint(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) and byte_size(host) > 0 ->
        if is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             uri.path in [nil, ""] and (is_nil(uri.port) or uri.port in 1..65_535),
           do: {:ok, URI.to_string(%{uri | path: nil})},
           else: invalid_endpoint()

      _uri ->
        invalid_endpoint()
    end
  end

  defp endpoint(_value), do: invalid_endpoint()

  defp certificates(configuration) do
    with {:ok, pem} <- required_string(configuration, "ca_certificate", 65_536),
         entries when is_list(entries) and entries != [] <- :public_key.pem_decode(pem),
         certificates when certificates != [] <-
           Enum.flat_map(entries, fn
             {:Certificate, der, :not_encrypted} -> [der]
             _entry -> []
           end) do
      {:ok, certificates}
    else
      _error -> {:error, :invalid_ca_certificate}
    end
  rescue
    _error -> {:error, :invalid_ca_certificate}
  end

  defp partial_chain(trusted) do
    fn chain ->
      case Enum.find(chain, &(&1 in trusted)) do
        nil -> :unknown_ca
        certificate -> {:trusted_ca, certificate}
      end
    end
  end

  defp verify_fun(trusted, host) do
    callback = fn
      certificate, {:bad_cert, :selfsigned_peer}, state ->
        der = :public_key.pkix_encode(:OTPCertificate, certificate, :otp)

        if der in state.trusted and valid_hostname?(certificate, state.host),
          do: {:valid, state},
          else: {:fail, :selfsigned_peer}

      _certificate, {:bad_cert, reason}, _state ->
        {:fail, reason}

      _certificate, {:extension, _extension}, state ->
        {:unknown, state}

      _certificate, :valid, state ->
        {:valid, state}

      certificate, :valid_peer, state ->
        if valid_hostname?(certificate, state.host),
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

  defp timeout(configuration, key, default) do
    case Map.get(configuration, key, default) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp body_limit(configuration) do
    case Map.get(configuration, "max_body_bytes", 60_000) do
      value when is_integer(value) and value in 1..60_000 -> {:ok, value}
      _value -> {:error, :invalid_body_limit}
    end
  end

  defp exact_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(to_string(&1) in allowed)),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp required_string(map, key, maximum) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum ->
        {:ok, value}

      _value ->
        {:error, :invalid_string}
    end
  end

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
  defp after_dispatch(:effect, _category), do: :unknown_after_dispatch
  defp after_dispatch(_phase, category), do: category
  defp failure_category(:effect), do: :unknown_after_dispatch
  defp failure_category(_phase), do: :unreachable
  defp invalid_endpoint, do: {:error, :failed, "IOS XE RESTCONF endpoint is invalid"}
end
