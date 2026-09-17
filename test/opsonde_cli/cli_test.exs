defmodule OpsondeCLI.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints fixed-English help" do
    assert capture_io(fn -> assert OpsondeCLI.CLI.run([]) == 0 end) =~ "Usage:"
  end

  test "prints the product version" do
    assert capture_io(fn -> assert OpsondeCLI.CLI.run(["--version"]) == 0 end) ==
             "opsonde 0.1.0\n"
  end

  test "rejects an unknown command" do
    assert capture_io(:stderr, fn -> assert OpsondeCLI.CLI.run(["unknown"]) == 1 end) ==
             "Unknown command. Run opsonde --help for usage.\n"
  end
end
