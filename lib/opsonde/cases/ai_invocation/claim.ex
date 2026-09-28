defmodule Opsonde.Cases.AIInvocation.Claim do
  @moduledoc false

  @enforce_keys [:state, :invocation]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :claimed | :interrupted | :terminal,
          invocation: struct()
        }
end
