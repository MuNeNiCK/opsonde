defmodule Opsonde.Cases.AIInvocation.Validations.Unsent do
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, _opts, _context) do
    if Opsonde.Cases.AIInvocation.retryable_unsent?(
         Ash.Changeset.get_argument(changeset, :before_send_failure)
       ) do
      :ok
    else
      {:error,
       field: :before_send_failure, message: "does not establish a retryable unsent request"}
    end
  end
end
