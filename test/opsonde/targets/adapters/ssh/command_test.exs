defmodule Opsonde.Targets.Adapters.SSH.CommandTest do
  use ExUnit.Case, async: true

  alias Opsonde.Targets.Adapters.SSH.Command

  test "readonly classification accepts observations and rejects mutation or shell composition" do
    assert Command.readonly?("uname -a")
    assert Command.readonly?("systemctl status sshd.service")
    assert Command.readonly?("ps aux | grep beam.smp")

    refute Command.readonly?("systemctl restart sshd.service")
    refute Command.readonly?("sed -i s/old/new/ /etc/example.conf")
    refute Command.readonly?("sed 'e id' /etc/os-release")
    refute Command.readonly?("find /tmp -name stale -delete")
    refute Command.readonly?("find /tmp -fls /tmp/result")
    refute Command.readonly?("hostname -F /tmp/hostname")
    refute Command.readonly?("dmesg -n 1")
    refute Command.readonly?("ethtool -E eth0 magic 0x1234 offset 0 value 1")
    refute Command.readonly?("ip -batch /tmp/commands")
    refute Command.readonly?("journalctl --setup-keys")
    refute Command.readonly?("rg --pre 'touch /tmp/unsafe' pattern .")
    refute Command.readonly?("ss -K dst 192.0.2.1")
    refute Command.readonly?("cat /etc/os-release > /tmp/os-release")
    refute Command.readonly?("sh -c 'uname -a'")
  end
end
