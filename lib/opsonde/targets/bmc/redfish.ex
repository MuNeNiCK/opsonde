defmodule Opsonde.Targets.BMC.Redfish do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.BMC
  alias Opsonde.Targets.BMC.OutputProjection
  alias Opsonde.Targets.BMC.Redfish.ResourceURI

  @reset_types %{
    "bmc.power.on" => "On",
    "bmc.power.off" => "ForceOff",
    "bmc.power.cycle" => "PowerCycle",
    "bmc.power.reset" => "ForceRestart"
  }
  @api_read_methods %{"GET" => :get, "HEAD" => :head}
  @api_write_methods %{"POST" => :post, "PATCH" => :patch, "PUT" => :put, "DELETE" => :delete}
  @native_read "native.redfish.observe"
  @native_effect "native.redfish.effect"
  @sensitive_names ~w(password passphrase secret token credential authorization apikey privatekey community)
  @max_collection_pages 8

  defmodule State do
    @moduledoc false
    @enforce_keys [:endpoint, :system_path, :expected_uuid, :auth, :cacerts, :timeout]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "bmc-redfish"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    profile = BMC.access_method_profile("redfish")
    %{profile | capabilities: [@native_read, @native_effect | profile.capabilities]}
  end

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

      api = BMC.api_capabilities()

      {:ok,
       %Target.Capabilities{
         observations: capabilities.observations ++ api.observations ++ [native_read_operation()],
         effects: effects ++ api.effects ++ [native_effect_operation()]
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, %{capability: @native_read} = request, invocation),
    do: native_observe(state, request, invocation)

  def observe(%State{} = state, %{capability: "observe.bmc_api"} = request, invocation),
    do: api_observe(state, request, invocation)

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
  def effect(%State{} = state, %{capability: @native_effect} = request, invocation),
    do: native_effect(state, request, invocation)

  def effect(%State{} = state, %{capability: "effect.bmc_api"} = request, invocation),
    do: api_effect(state, request, invocation)

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
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: intent.operation,
             details:
               %{"reason" => "Redfish task was accepted but is not complete"}
               |> maybe_task_location(response_task_location(state, headers))
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

  defp api_observe(state, request, invocation) do
    with {:ok, method, path} <- api_request(state, request, @api_read_methods),
         :ok <- not_cancelled(invocation),
         {:ok, _system} <- system(state),
         {:ok, status, body, pages, headers} <- read_api_resource(state, method, path, invocation),
         {:ok, facts} <- public_response(body, request) do
      evidence =
        %{
          "source" => "redfish",
          "method" => request.protocol_request["method"],
          "uri" => path,
          "http_status" => status,
          "pages" => pages
        }
        |> maybe_etag(if(pages == 1, do: response_etag(headers), else: nil))

      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [evidence]
       }}
    else
      {:error, :invalid_output} ->
        {:error, :failed, "Redfish response does not match registered output schema"}

      {:error, category, message} ->
        read_error(category, message)
    end
  end

  defp native_observe(state, request, invocation) do
    with {:ok, method, path} <- native_read_request(state, request),
         :ok <- not_cancelled(invocation),
         {:ok, _system} <- system(state),
         {:ok, status, body, pages, headers} <- read_api_resource(state, method, path, invocation) do
      evidence =
        %{
          "source" => "redfish",
          "method" => String.upcase(to_string(method)),
          "uri" => path,
          "http_status" => status,
          "pages" => pages
        }
        |> maybe_etag(if(pages == 1, do: response_etag(headers), else: nil))

      {:ok,
       %Target.Observation{
         facts: %{"http_status" => status, "response" => sanitize_response(body)},
         observed_at: DateTime.utc_now(),
         evidence: [evidence]
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp native_read_operation do
    output = %{
      "type" => "object",
      "properties" => %{
        "http_status" => %{"type" => "integer"},
        "response" => %{"type" => "object"}
      },
      "required" => ["http_status", "response"],
      "additionalProperties" => false
    }

    %Target.Operation{
      capability: @native_read,
      operation: "request.observe",
      description: "Read one exact standard or OEM Redfish resource by relative URI",
      input_schema: native_schema(["GET", "HEAD"]),
      output_schema: output,
      verification_schema: output,
      native?: true
    }
  end

  defp native_effect_operation do
    %Target.Operation{
      capability: @native_effect,
      operation: "request.execute",
      description:
        "Send one exact standard or OEM Redfish write by relative URI after authority review",
      input_schema: native_schema(Map.keys(@api_write_methods), true),
      native?: true
    }
  end

  defp native_schema(methods, write? \\ false) do
    selector_properties =
      if write?, do: %{"if_match" => %{"type" => "string", "maxLength" => 256}}, else: %{}

    parameter_properties = %{
      "method" => %{"type" => "string", "enum" => methods},
      "uri" => %{"type" => "string", "minLength" => 11, "maxLength" => 2_048}
    }

    parameter_properties =
      if write? do
        Map.merge(parameter_properties, %{
          "body" => %{"type" => "object"},
          "include_response" => %{"type" => "boolean"}
        })
      else
        parameter_properties
      end

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => selector_properties,
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameter_properties,
          "required" => ["method", "uri"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp native_read_request(state, request) do
    with true <- request.operation == "request.observe",
         true <- request.connection.endpoint == state.endpoint,
         true <- request.selectors == %{} and request.secret_values == %{},
         true <- is_nil(request.protocol_request),
         %{"method" => method, "uri" => uri} = parameters <- request.parameters,
         true <- map_size(parameters) == 2,
         {:ok, verb} <- Map.fetch(@api_read_methods, method),
         {:ok, path} <- ResourceURI.relative(uri) do
      {:ok, verb, path}
    else
      _ -> {:error, :failed, "Redfish native observation request is invalid"}
    end
  end

  defp native_effect(state, target_request, invocation) do
    with {:ok, method, path, body, headers, include_response?} <-
           native_write_request(state, target_request),
         :ok <- not_cancelled(invocation),
         {:ok, _system} <- system(state),
         :ok <- not_cancelled(invocation) do
      result = request(state, method, path, body, headers)

      effect_response(state, result, target_request.operation, fn status, reply ->
        native_response_details(status, reply, include_response?)
      end)
    else
      {:error, :cancelled, _message} = error -> error
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  defp native_write_request(state, request) do
    parameters = request.parameters

    with true <- request.operation == "request.execute",
         true <- request.connection.endpoint == state.endpoint,
         true <- is_nil(request.protocol_request) and request.secret_values == %{},
         %{"method" => method, "uri" => uri} <- parameters,
         true <- Enum.all?(Map.keys(parameters), &(&1 in ~w(method uri body include_response))),
         {:ok, verb} <- Map.fetch(@api_write_methods, method),
         {:ok, path} <- ResourceURI.relative(uri),
         {:ok, headers} <- if_match_headers(request.selectors),
         include_response? when is_boolean(include_response?) <-
           Map.get(parameters, "include_response", false),
         {:ok, body} <- native_body(verb, parameters) do
      {:ok, verb, path, body, headers, include_response?}
    else
      _ -> {:error, :failed, "Redfish native effect request is invalid"}
    end
  end

  defp native_body(verb, parameters) do
    body = Map.get(parameters, "body")

    if (verb == :delete or is_map(body)) and (is_nil(body) or is_map(body)) do
      case Jason.encode(body) do
        {:ok, encoded} when byte_size(encoded) <= 65_536 -> {:ok, body}
        _ -> {:error, :failed, "Redfish request body exceeds its limit"}
      end
    else
      {:error, :failed, "Redfish request body is invalid"}
    end
  rescue
    _ -> {:error, :failed, "Redfish request body is invalid"}
  end

  defp native_response_details(status, reply, _include_response?) when map_size(reply) == 0,
    do: %{"http_status" => status}

  defp native_response_details(status, reply, true),
    do: %{"http_status" => status, "response" => sanitize_response(reply)}

  defp native_response_details(status, _reply, false),
    do: %{"http_status" => status, "response_redacted" => true}

  defp api_effect(state, request, invocation) do
    with {:ok, method, path} <- api_request(state, request, @api_write_methods),
         {:ok, conditional_headers} <- if_match_headers(request.selectors),
         :ok <- not_cancelled(invocation),
         {:ok, _system} <- system(state),
         :ok <- not_cancelled(invocation) do
      body = if method == :delete and request.parameters == %{}, do: nil, else: request.parameters

      result = request(state, method, path, body, conditional_headers)

      effect_response(state, result, request.operation, fn status, reply ->
        %{"http_status" => status}
        |> Map.merge(public_response_details(reply, request))
      end)
    else
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  defp effect_response(state, {:ok, status, headers, reply}, reference, details)
       when status in [200, 201, 202, 204] do
    outcome = if status == 202, do: :unknown, else: :applied
    visible = details.(status, reply)

    visible =
      if status == 202,
        do: maybe_task_location(visible, response_task_location(state, headers)),
        else: visible

    {:ok, %Target.EffectResult{status: outcome, reference: reference, details: visible}}
  end

  defp effect_response(_state, {:ok, status, _headers, _reply}, reference, _details) do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"http_status" => status, "reason" => "Redfish write outcome is unclear"}
     }}
  end

  defp effect_response(_state, {:error, :transport, _message}, reference, _details) do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"reason" => "Redfish response was lost after dispatch"}
     }}
  end

  defp effect_response(_state, {:error, _category, message}, _reference, _details),
    do: {:error, :failed, message}

  defp api_request(state, request, methods) do
    protocol = request.protocol_request

    with true <- request.connection.endpoint == state.endpoint,
         %{"method" => method, "uri" => uri} <- protocol,
         {:ok, verb} <- Map.fetch(methods, method),
         {:ok, path} <- ResourceURI.relative(uri) do
      {:ok, verb, path}
    else
      _ -> {:error, :failed, "Redfish API request is invalid for this Access Method"}
    end
  end

  defp read_api_resource(state, method, path, invocation) do
    case request(state, method, path, nil) do
      {:ok, status, headers, body} when status in [200, 204] ->
        with {:ok, combined, pages} <-
               collect_pages(state, method, path, body, 1, MapSet.new([path]), invocation) do
          {:ok, status, combined, pages, headers}
        end

      {:ok, _status, _headers, _body} ->
        {:error, :failed, "Redfish read is incomplete"}

      {:error, _category, _message} = error ->
        error
    end
  end

  defp collect_pages(_state, :head, _path, body, pages, _seen, _invocation),
    do: {:ok, body, pages}

  defp collect_pages(state, :get, path, body, pages, seen, invocation) do
    next = body["Members@odata.nextLink"] || body["@odata.nextLink"]

    case next do
      nil ->
        {:ok, body, pages}

      link when is_binary(link) and pages < @max_collection_pages ->
        with :ok <- not_cancelled(invocation),
             {:ok, next_path} <- ResourceURI.from_link(state.endpoint, link, path),
             false <- MapSet.member?(seen, next_path),
             {:ok, 200, _headers, next_body} <- request(state, :get, next_path, nil),
             first when is_list(first) <- body["Members"],
             following when is_list(following) <- next_body["Members"],
             merged <-
               body
               |> Map.put("Members", first ++ following)
               |> Map.put("Members@odata.nextLink", next_body["Members@odata.nextLink"])
               |> Map.put("@odata.nextLink", next_body["@odata.nextLink"]),
             true <- bounded_response?(merged) do
          collect_pages(
            state,
            :get,
            next_path,
            merged,
            pages + 1,
            MapSet.put(seen, next_path),
            invocation
          )
        else
          {:error, _category, _message} = error -> error
          _ -> {:error, :failed, "Redfish collection pagination is invalid"}
        end

      _ ->
        {:error, :failed, "Redfish collection pagination limit was reached"}
    end
  end

  defp bounded_response?(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> byte_size(encoded) <= 65_536
      _ -> false
    end
  end

  defp response_etag(headers) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "etag") do
      [etag] when is_binary(etag) ->
        if valid_etag?(etag), do: etag, else: nil

      _ ->
        nil
    end
  end

  defp maybe_etag(evidence, etag) when is_binary(etag), do: Map.put(evidence, "etag", etag)
  defp maybe_etag(evidence, _etag), do: evidence

  defp if_match_headers(%{} = selectors) when map_size(selectors) == 0, do: {:ok, []}

  defp if_match_headers(%{"if_match" => etag} = selectors) when map_size(selectors) == 1 do
    if valid_etag?(etag) and not String.starts_with?(etag, "W/"),
      do: {:ok, [{"if-match", etag}]},
      else: {:error, :failed, "Redfish If-Match value is invalid"}
  end

  defp if_match_headers(_selectors),
    do: {:error, :failed, "Redfish If-Match selector is invalid"}

  defp valid_etag?(etag) when is_binary(etag) and byte_size(etag) in 1..256,
    do: etag == "*" or Regex.match?(~r/\A(?:W\/)?"[\x21\x23-\x7E]*"\z/, etag)

  defp valid_etag?(_etag), do: false

  defp public_response(body, request) do
    secret_bound? = map_size(request.secret_values) > 0
    value = if secret_bound?, do: body, else: sanitize_response(body)
    OutputProjection.project(value, request.output_schema, secret_bound?)
  end

  defp public_response_details(body, request) do
    case public_response(body, request) do
      {:ok, projected} when map_size(projected) > 0 -> %{"response" => projected}
      {:ok, _empty} -> %{}
      {:error, _reason} -> %{"response_unavailable" => true}
    end
  end

  defp response_task_location(state, headers) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "location") do
      [location] -> safe_task_location(state, location)
      _ -> nil
    end
  end

  defp safe_task_location(state, location) do
    case resource_path(state, location) do
      {:ok, path} ->
        if Regex.match?(
             ~r{\A/redfish/v1/TaskService/(?:TaskMonitors|Tasks)/[A-Za-z0-9._~-]+\z},
             path
           ),
           do: path,
           else: nil

      _ ->
        nil
    end
  end

  defp maybe_task_location(details, location) when is_binary(location),
    do: Map.put(details, "task_location", location)

  defp maybe_task_location(details, _location), do: details

  defp sanitize_response(value), do: sanitize_response(value, 0)

  defp sanitize_response(value, depth) when is_map(value) and depth < 16 do
    Map.new(value, fn {key, item} ->
      safe = if sensitive_name?(key), do: "[REDACTED]", else: sanitize_response(item, depth + 1)
      {key, safe}
    end)
  end

  defp sanitize_response(value, depth) when is_list(value) and depth < 16,
    do: Enum.map(value, &sanitize_response(&1, depth + 1))

  defp sanitize_response(_value, depth) when depth >= 16, do: "[TRUNCATED]"
  defp sanitize_response(value, _depth), do: value

  defp sensitive_name?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    Enum.any?(@sensitive_names, &String.contains?(normalized, &1))
  end

  defp sensitive_name?(_key), do: false

  defp system(state) do
    with {:ok, 200, collection, _pages, _headers} <-
           read_api_resource(state, :get, "/redfish/v1/Systems", %{}),
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
    case ResourceURI.from_link(state.endpoint, target) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :failed, "Redfish resource URI is outside the BMC origin"}
    end
  end

  defp resource_path(_state, _target), do: {:error, :failed, "Redfish resource URI is invalid"}

  defp power_state(%{"PowerState" => "On"}), do: {:ok, "on"}
  defp power_state(%{"PowerState" => "Off"}), do: {:ok, "off"}
  defp power_state(_system), do: {:error, :failed, "Redfish PowerState is unavailable"}

  defp request(state, method, path, body, extra_headers \\ []) do
    host = URI.parse(state.endpoint).host

    options = [
      method: method,
      url: state.endpoint <> path,
      auth: state.auth,
      headers:
        [{"accept", "application/json"}, {"content-type", "application/json"}] ++ extra_headers,
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
      decode_body: false,
      into: fn {:data, data}, {req, response} ->
        accumulated = if is_binary(response.body), do: response.body, else: ""

        if byte_size(accumulated) + byte_size(data) <= 65_536 do
          {:cont, {req, %{response | body: accumulated <> data}}}
        else
          {:halt, {req, %{response | body: :too_large}}}
        end
      end
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

          status == 412 ->
            {:error, :rejected, "Redfish write precondition failed (HTTP 412)"}

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
