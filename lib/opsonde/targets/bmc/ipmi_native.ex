defmodule Opsonde.Targets.BMC.IPMINative do
  @moduledoc false

  use Rustler, otp_app: :opsonde, crate: :ipmi_nif

  def send_command(_address, _username, _password, _timeout_ms, _netfn, _command, _data),
    do: :erlang.nif_error(:nif_not_loaded)
end
