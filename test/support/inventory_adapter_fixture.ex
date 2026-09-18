defmodule Opsonde.InventoryAdapterFixture do
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Inventory

  @impl Opsonde.Providers.Adapter
  def type, do: "fixture-inventory"

  @impl Opsonde.Providers.Adapter
  def role, do: :inventory

  @impl Opsonde.Providers.Adapter
  def build(%{"source" => source}, %{"token" => token})
      when is_binary(source) and is_binary(token),
      do: {:ok, %{source: source, token: token}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Opsonde.Providers.Inventory
  def fetch_page(state, request, cursor, invocation) do
    send(invocation.test_pid, {:page, state, request, cursor})
    invocation.respond.(cursor)
  end
end
