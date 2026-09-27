defmodule Opsonde.ProviderAdapterFixture do
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Target

  alias Opsonde.Providers.Target
  alias Opsonde.Targets.ResourceScope

  @impl true
  def type, do: "fixture-target"

  @impl true
  def kind, do: :target

  @impl Opsonde.Providers.Target
  def resource_scope(operation, capability, selectors)
      when operation in ["service.restart", "service.inspect"] and
             capability in ["effect.service", "observe.service"] and is_map(selectors) do
    case selectors do
      %{"unit" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      %{"service" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      _other -> "target"
    end
  end

  def resource_scope(_operation, _capability, _selectors), do: "target"

  @impl true
  def build(%{"endpoint" => endpoint}, %{"token" => token})
      when is_binary(endpoint) and is_binary(token) do
    {:ok, %{endpoint: endpoint, token: token}}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl true
  def check(%{endpoint: "reachable"}, %{"fail" => true}),
    do: {:error, :unreachable, "fixture unreachable"}

  def check(%{endpoint: "reachable"}, _input), do: :ok

  def check(%{endpoint: "echo", token: token}, _input),
    do: {:error, :authentication, "credential #{token} was rejected"}

  def check(%{endpoint: "invalid_response"}, _input), do: :invalid

  def check(%{endpoint: category}, _input)
      when category in ["authentication", "unreachable", "capability"] do
    {:error, String.to_existing_atom(category), "fixture #{category}"}
  end

  def check(_state, _input), do: {:error, :capability, "unsupported fixture endpoint"}

  @impl Opsonde.Providers.Target
  def capabilities(state, invocation) do
    notify(invocation, {:capabilities, state})
    respond(invocation)
  end

  @impl Opsonde.Providers.Target
  def observe(state, request, invocation) do
    notify(invocation, {:observe, state, request})
    respond(invocation)
  end

  @impl Opsonde.Providers.Target
  def effect(state, request, invocation) do
    notify(invocation, {:effect, state, request})
    respond(invocation)
  end

  @impl Opsonde.Providers.Target
  def verify(state, request, invocation) do
    notify(invocation, {:verify, state, request})
    respond(invocation)
  end

  defp notify(%{test_pid: pid}, message), do: send(pid, message)
  defp notify(_invocation, _message), do: :ok

  defp respond(%{respond: respond}) when is_function(respond, 0), do: respond.()

  defp respond(_invocation),
    do: {:ok, %Target.Capabilities{observations: [], effects: []}}
end
