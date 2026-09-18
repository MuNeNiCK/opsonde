defmodule Opsonde.ProviderAdapterFixture do
  @behaviour Opsonde.Providers.Adapter

  @impl true
  def type, do: "fixture-target"

  @impl true
  def role, do: :target

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
end
