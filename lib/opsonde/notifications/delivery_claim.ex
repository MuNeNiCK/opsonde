defmodule Opsonde.Notifications.DeliveryClaim do
  @moduledoc false
  @enforce_keys [:state, :delivery]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end
