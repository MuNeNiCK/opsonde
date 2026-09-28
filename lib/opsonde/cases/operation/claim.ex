defmodule Opsonde.Cases.Operation.Claim do
  @moduledoc false

  @enforce_keys [:state, :operation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :claimed | :deferred | :terminal,
          operation: struct()
        }
end
