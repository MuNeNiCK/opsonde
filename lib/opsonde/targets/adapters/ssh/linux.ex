defmodule Opsonde.Targets.Adapters.SSH.Linux do
  @moduledoc false
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target
  alias Opsonde.Providers.Target
  alias Opsonde.Transports.SSH, as: Transport
  alias Opsonde.Targets.Adapters.SSH.Command
  alias Opsonde.Targets.Profiles.Linux, as: Profile

  @method_effect "request.ssh.effect"

  defmodule State do
    @moduledoc false
    @enforce_keys [:transport, :privilege]
    defstruct @enforce_keys
  end

  @impl Opsonde.Providers.Adapter
  def type, do: "linux-ssh"

  @impl Opsonde.Providers.Adapter
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def access_method_profile, do: Profile.access_method_profile()

  @impl Opsonde.Providers.Target
  def resource_scope(operation, capability, selectors),
    do: Profile.resource_scope(operation, capability, selectors)

  @impl Opsonde.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) do
    {privilege, transport_configuration} = Map.pop(configuration, "privilege", "none")

    with true <- privilege in ["none", "sudo"],
         {:ok, transport} <- Transport.build(transport_configuration, credentials) do
      {:ok, %State{transport: transport, privilege: privilege}}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(%State{transport: transport}, %{"endpoint" => endpoint}) do
    case Transport.check(transport, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Linux SSH check requires an endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(%State{privilege: privilege}, _invocation), do: Profile.capabilities(privilege)

  @impl Opsonde.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with {:ok, command, decoder} <- Profile.observation_command(state.privilege, request),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- Profile.decode_observation(decoder, result) do
      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def preflight(%State{} = state, request) do
    case Profile.observation_command(state.privilege, request) do
      {:ok, _command, _decoder} -> :ok
      {:error, _category, _message} = error -> error
    end
  end

  @impl Opsonde.Providers.Target
  def effect(%State{} = state, %{capability: capability} = request, invocation)
      when capability != @method_effect do
    with {:ok, command} <- Profile.restart_command(state.privilege, request),
         result <- execute_raw(state, request, command, invocation) do
      effect_result(result)
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  def effect(%State{} = state, %{capability: @method_effect} = request, invocation) do
    with {:ok, command} <- Command.effect_command(request, @method_effect) do
      state
      |> execute_raw(request, Profile.privileged(state.privilege, command), invocation)
      |> effect_result()
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Opsonde.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with {:ok, command, :service} <- Profile.observation_command(state.privilege, request),
         {:ok, expected} <- Profile.verification_expected(request.expected),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- Profile.decode_observation(:service, result) do
      {:ok,
       %Target.Verification{
         status: Profile.expected_status(facts, expected),
         observed_at: DateTime.utc_now(),
         facts: facts,
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
      _error -> {:error, :failed, "Linux verification request is invalid"}
    end
  end

  defp execute(state, request, command, invocation) do
    case execute_raw(state, request, command, invocation) do
      {:ok, %Transport.Result{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, %Transport.Result{exit_status: status}} ->
        {:error, :failed, "Linux observation exited with status #{status}"}

      {:error, category, message} ->
        {:error, category, message}
    end
  end

  defp execute_raw(state, request, command, invocation) do
    Transport.exec(
      state.transport,
      request.connection.endpoint,
      command,
      cancelled?(invocation)
    )
  end

  defp effect_result({:ok, %Transport.Result{exit_status: 0} = result}) do
    {:ok, %Target.EffectResult{status: :applied, details: evidence(result)}}
  end

  defp effect_result({:ok, %Transport.Result{exit_status: 65} = result}) do
    {:ok,
     %Target.EffectResult{
       status: :failed,
       details: Map.put(evidence(result), "category", "stale_definition")
     }}
  end

  defp effect_result({:ok, %Transport.Result{} = result}) do
    {:ok, %Target.EffectResult{status: :failed, details: evidence(result)}}
  end

  defp effect_result({:error, category, message})
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_result({:error, :cancelled, message}), do: {:error, :cancelled, message}
  defp effect_result({:error, _category, message}), do: {:error, :failed, message}

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}

  defp read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  defp read_error(category, message)
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp evidence(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
end
