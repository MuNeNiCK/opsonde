defmodule Opsonde.Targets.PolicyError do
  @moduledoc false

  use Splode.Error, class: :forbidden, fields: [:category, :message, :policy_id]

  @impl true
  def message(error), do: error.message
end
