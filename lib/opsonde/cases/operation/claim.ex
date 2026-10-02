defmodule Opsonde.Cases.Operation.Claim do
  @moduledoc false

  @enforce_keys [:state, :operation]
  defstruct @enforce_keys ++ [actor: nil, clearance: nil]

  @type t :: %__MODULE__{
          state: :claimed | :deferred | :terminal,
          operation: struct(),
          actor: struct() | nil,
          clearance: Opsonde.Targets.TargetRequest.Clearance.t() | nil
        }
end
