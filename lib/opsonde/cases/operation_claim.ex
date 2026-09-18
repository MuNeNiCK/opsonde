defmodule Opsonde.Cases.OperationClaim do
  @moduledoc false

  @enforce_keys [:state, :operation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :claimed | :terminal,
          operation: struct()
        }
end
