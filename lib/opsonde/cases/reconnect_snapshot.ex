defmodule Opsonde.Cases.ReconnectSnapshot do
  @moduledoc false

  @enforce_keys [:case, :resolution_runs, :proposals, :operations, :verification_attempts]
  defstruct @enforce_keys
end
