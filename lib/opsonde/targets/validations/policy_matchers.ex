defmodule Opsonde.Targets.Validations.PolicyMatchers do
  use Ash.Resource.Validation

  alias Opsonde.Targets.PolicyMatcher

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    Enum.reduce_while([:selector_match, :parameter_match], :ok, fn attribute, :ok ->
      value = Ash.Changeset.get_attribute(changeset, attribute)

      case PolicyMatcher.validate(value) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, field: attribute, message: message}}
      end
    end)
  end
end
