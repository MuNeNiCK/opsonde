defmodule OpsondeCLI.CLI do
  @moduledoc false

  def run(["--version"]) do
    IO.puts("opsonde #{version()}")
    0
  end

  def run([]) do
    IO.puts("""
    Usage:
      opsonde --help
      opsonde --version
    """)

    0
  end

  def run(["--help"]), do: run([])

  def run(_args) do
    IO.puts(:stderr, "Unknown command. Run opsonde --help for usage.")
    1
  end

  defp version do
    :opsonde
    |> Application.spec(:vsn)
    |> to_string()
  end
end
