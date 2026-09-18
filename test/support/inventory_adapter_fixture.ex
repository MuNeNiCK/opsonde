defmodule Opsonde.InventoryAdapterFixture do
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Inventory

  @impl Opsonde.Providers.Adapter
  def type, do: "fixture-inventory"

  @impl Opsonde.Providers.Adapter
  def kind, do: :inventory

  @impl Opsonde.Providers.Adapter
  def build(%{"source" => source}, %{"token" => token})
      when is_binary(source) and is_binary(token),
      do: {:ok, %{source: source, token: token}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Opsonde.Providers.Inventory
  def fetch_page(state, request, cursor, %{test_pid: pid, respond: respond}) do
    send(pid, {:page, state, request, cursor})
    respond.(cursor)
  end

  def fetch_page(_state, _request, nil, _invocation) do
    {:ok, %Opsonde.Providers.Inventory.Page{records: [], source_version: "fixture-v1"}}
  end
end
