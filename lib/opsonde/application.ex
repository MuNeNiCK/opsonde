defmodule Opsonde.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = if standalone_cli?(), do: cli_children(), else: server_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Opsonde.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp cli_children do
    [{Task, fn -> System.halt(OpsondeCLI.CLI.run(Burrito.Util.Args.argv())) end}]
  end

  defp server_children do
    [
      OpsondeWeb.Telemetry,
      Opsonde.Repo,
      {Oban, Application.fetch_env!(:opsonde, Oban)},
      Opsonde.Providers.Vault,
      {DNSCluster, query: Application.get_env(:opsonde, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Opsonde.PubSub},
      OpsondeWeb.Endpoint
    ]
  end

  defp standalone_cli?, do: Burrito.Util.running_standalone?()

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OpsondeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
