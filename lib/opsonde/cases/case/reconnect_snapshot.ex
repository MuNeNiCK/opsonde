defmodule Opsonde.Cases.Case.ReconnectSnapshot do
  @moduledoc false

  @enforce_keys [
    :case,
    :conditions,
    :condition_history,
    :resolution_runs,
    :proposals,
    :operations,
    :verification_attempts,
    :reports
  ]
  defstruct @enforce_keys
end
