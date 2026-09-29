defmodule Opsonde.Targets.Adapters.NETCONF do
  @moduledoc false

  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Transports.{NETCONF, SSH}

  @observation "request.netconf.observe"
  @effect "request.netconf.effect"

  @impl Opsonde.Providers.Adapter
  def type, do: "netconf"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "netconf",
      capabilities: [@observation, @effect]
    }
  end

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration),
    do: SSH.build(Map.put_new(configuration, "max_output_bytes", 60_000), credentials)

  def build(configuration, credentials), do: SSH.build(configuration, credentials)

  @impl Opsonde.Providers.Adapter
  def check(%SSH.Config{} = state, %{"endpoint" => endpoint}) do
    case NETCONF.check(state, endpoint) do
      {:ok, _session} ->
        :ok

      {:error, category, message} when category in [:authentication, :host_key] ->
        {:error, :authentication, message}

      {:error, _category, message} ->
        {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "NETCONF check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(_state, _invocation) do
    input = %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "body" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => NETCONF.max_body_bytes()
            }
          },
          "required" => ["body"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }

    output = %{
      "type" => "object",
      "properties" => %{"reply" => %{"type" => "string", "minLength" => 1, "maxLength" => 60_000}},
      "required" => ["reply"],
      "additionalProperties" => false
    }

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @observation,
           operation: "rpc.observe",
           description: "Read one exact NETCONF RPC",
           input_schema: input,
           output_schema: output,
           verification_schema: output
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "rpc.execute",
           description: "Execute one exact NETCONF RPC after authority review",
           input_schema: input
         }
       ]
     }}
  end

  @impl Opsonde.Providers.Target
  def classify_request(_state, request) do
    case request_body(request) do
      {:ok, body} ->
        with {:ok, kind} <- NETCONF.classify_body(body) do
          if request.capability == @effect, do: {:ok, :effect}, else: {:ok, kind}
        end

      error ->
        error
    end
  end

  @impl Opsonde.Providers.Target
  def observe(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @observation,
         {:ok, body} <- request_body(request),
         {:ok, :observation} <- NETCONF.classify_body(body),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, cancelled?(invocation)) do
      {:ok, %Target.Observation{facts: %{"reply" => reply}, observed_at: DateTime.utc_now()}}
    else
      false -> {:error, :failed, "NETCONF observation request is invalid"}
      {:ok, :effect} -> {:error, :failed, "NETCONF observation is unsafe"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @effect,
         {:ok, body} <- request_body(request),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, cancelled?(invocation)) do
      {:ok, %Target.EffectResult{status: :applied, details: %{"reply" => reply}}}
    else
      false -> {:error, :failed, "NETCONF effect request is invalid"}
      {:error, category, message} -> effect_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @observation,
         {:ok, body} <- request_body(request),
         {:ok, :observation} <- NETCONF.classify_body(body),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, cancelled?(invocation)) do
      facts = %{"reply" => reply}

      status =
        cond do
          request.expected == %{} -> :unknown
          Enum.all?(request.expected, fn {key, value} -> facts[key] == value end) -> :verified
          true -> :not_verified
        end

      {:ok, %Target.Verification{status: status, observed_at: DateTime.utc_now(), facts: facts}}
    else
      false -> {:error, :failed, "NETCONF verification request is invalid"}
      {:ok, :effect} -> {:error, :failed, "NETCONF verification is unsafe"}
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp request_body(%{
         capability: capability,
         operation: operation,
         selectors: %{},
         parameters: %{"body" => body} = parameters
       })
       when {capability, operation} in [
              {@observation, "rpc.observe"},
              {@effect, "rpc.execute"}
            ] and map_size(parameters) == 1 and is_binary(body),
       do: {:ok, body}

  defp request_body(_request), do: {:error, :failed, "NETCONF RPC request is invalid"}

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}

  defp read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  defp read_error(category, message)
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp effect_error(category, message)
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch,
              :unknown_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_error(:rejected, message),
    do: {:ok, %Target.EffectResult{status: :failed, details: %{"error" => message}}}

  defp effect_error(:cancelled, message), do: {:error, :cancelled, message}
  defp effect_error(_category, message), do: {:error, :failed, message}

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
