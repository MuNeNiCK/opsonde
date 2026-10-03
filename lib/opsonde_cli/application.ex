defmodule OpsondeCLI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task, fn -> System.halt(OpsondeCLI.CLI.run(Burrito.Util.Args.argv())) end}],
      strategy: :one_for_one,
      name: OpsondeCLI.Supervisor
    )
  end
end
