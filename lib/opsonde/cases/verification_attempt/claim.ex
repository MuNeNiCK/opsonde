defmodule Opsonde.Cases.VerificationAttempt.Claim do
  @moduledoc false

  @enforce_keys [:state, :attempt]
  defstruct @enforce_keys ++ [actor: nil, clearance: nil, invocation_context: nil]

  @type t :: %__MODULE__{
          state: :claimed | :terminal,
          attempt: struct(),
          actor: struct() | nil,
          clearance: Opsonde.Targets.TargetRequest.Clearance.t() | nil,
          invocation_context: Opsonde.Cases.Case.InvocationContext.t() | nil
        }
end
