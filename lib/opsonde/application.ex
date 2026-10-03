defmodule Opsonde.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = server_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Opsonde.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp server_children do
    [
      OpsondeWeb.Telemetry,
      Opsonde.Repo,
      {Oban, Application.fetch_env!(:opsonde, Oban)},
      Opsonde.Vault,
      {Finch, name: Opsonde.Transports.HTTP},
      Opsonde.Accounts.OIDC.Client.child_spec(),
      {DNSCluster, query: Application.get_env(:opsonde, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Opsonde.PubSub},
      OpsondeWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpsondeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
