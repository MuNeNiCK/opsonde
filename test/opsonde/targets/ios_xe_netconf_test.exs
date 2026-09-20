defmodule Opsonde.Targets.IOSXENETCONFTest do
  use ExUnit.Case, async: true

  alias Opsonde.Targets.IOSXE.NETCONF
  alias Opsonde.Transports.SSH

  test "NETCONF accepts a full protocol message by default and preserves an explicit bound" do
    assert {:ok, %SSH.Config{max_output_bytes: 60_000}} =
             NETCONF.build(configuration(), credentials())

    assert {:ok, %SSH.Config{max_output_bytes: 40_000}} =
             NETCONF.build(Map.put(configuration(), "max_output_bytes", 40_000), credentials())

    assert {:ok, %SSH.Config{max_output_bytes: 32_768}} =
             SSH.build(configuration(), credentials())
  end

  defp configuration do
    %{
      "host_key_fingerprints" => %{
        "ssh://ios-xe.example:830" => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      }
    }
  end

  defp credentials do
    %{"username" => "operator", "auth_method" => "password", "password" => "secret"}
  end
end
