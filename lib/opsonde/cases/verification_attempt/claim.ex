defmodule Opsonde.Cases.VerificationAttempt.Claim do
  @moduledoc false

  @enforce_keys [:state, :attempt]
  defstruct @enforce_keys

  @type t :: %__MODULE__{state: :claimed | :terminal, attempt: struct()}
end
