defmodule Opsonde.Cases.VerificationClaim do
  @moduledoc false

  @enforce_keys [:state, :attempt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{state: :claimed | :terminal, attempt: struct()}
end
