defmodule Opsonde.NotificationAdapterFixture do
  @behaviour Opsonde.Providers.Adapter
  @behaviour Opsonde.Providers.Notification

  @impl Opsonde.Providers.Adapter
  def type, do: "fixture-notification"

  @impl Opsonde.Providers.Adapter
  def kind, do: :notification

  @impl Opsonde.Providers.Adapter
  def build(%{"destination" => destination}, %{"token" => token})
      when is_binary(destination) and is_binary(token),
      do: {:ok, %{destination: destination, token: token}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Opsonde.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Opsonde.Providers.Notification
  def deliver(state, request, invocation) do
    send(invocation.test_pid, {:delivery, state, request})
    invocation.respond.()
  end
end
