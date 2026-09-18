defmodule Opsonde.AIAdapterFixture do
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.AI

  @impl Opsonde.Providers.Adapter
  def type, do: "fixture-ai"

  @impl Opsonde.Providers.Adapter
  def kind, do: :ai

  @impl Opsonde.Providers.Adapter
  def build(%{"model" => model}, %{"api_key" => api_key})
      when is_binary(model) and is_binary(api_key),
      do: {:ok, %{model: model, api_key: api_key}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Opsonde.Providers.AI
  def resolve(state, request, invocation) do
    send(invocation.test_pid, {:resolve, state, request})
    invocation.respond.(request)
  end

  @impl Opsonde.Providers.AI
  def review(state, request, invocation) do
    send(invocation.test_pid, {:review, state, request})
    invocation.respond.(request)
  end
end
