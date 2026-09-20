defmodule Opsonde.Targets.NativeShellTest do
  use ExUnit.Case, async: true

  alias Opsonde.Targets.NativeShell

  test "readonly classification accepts observations and rejects mutation or shell composition" do
    assert NativeShell.readonly?("uname -a")
    assert NativeShell.readonly?("journalctl -u sshd.service --since today")
    assert NativeShell.readonly?("ps aux | grep beam.smp")

    refute NativeShell.readonly?("systemctl restart sshd.service")
    refute NativeShell.readonly?("sed -i s/old/new/ /etc/example.conf")
    refute NativeShell.readonly?("sed 'e id' /etc/os-release")
    refute NativeShell.readonly?("find /tmp -name stale -delete")
    refute NativeShell.readonly?("find /tmp -fls /tmp/result")
    refute NativeShell.readonly?("hostname -F /tmp/hostname")
    refute NativeShell.readonly?("dmesg -n 1")
    refute NativeShell.readonly?("ethtool -E eth0 magic 0x1234 offset 0 value 1")
    refute NativeShell.readonly?("ip -batch /tmp/commands")
    refute NativeShell.readonly?("cat /etc/os-release > /tmp/os-release")
    refute NativeShell.readonly?("sh -c 'uname -a'")
  end
end
