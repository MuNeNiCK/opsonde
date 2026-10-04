defmodule Opsonde.Cases.Case.ReconnectSnapshot do
  @moduledoc false

  @enforce_keys [
    :case,
    :ai_usage,
    :conditions,
    :condition_history,
    :condition_context,
    :resolution_runs,
    :proposals,
    :operations,
    :verification_attempts,
    :reports
  ]
  defstruct @enforce_keys
end
