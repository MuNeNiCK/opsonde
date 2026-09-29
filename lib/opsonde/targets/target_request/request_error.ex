defmodule Opsonde.Targets.TargetRequest.RequestError do
  @moduledoc false

  use Splode.Error, class: :forbidden, fields: [:category, :message]

  @impl true
  def message(error), do: error.message
end
