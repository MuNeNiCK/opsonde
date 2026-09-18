defmodule Opsonde.Accounts.User.Actions.IssueSession do
  use Ash.Resource.Actions.Implementation

  alias Opsonde.Accounts.User

  @impl true
  def run(input, _options, _context) do
    with {:ok, user} <- Ash.get(User, input.arguments.user_id, authorize?: false),
         %User{} = user <- user,
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user, %{}) do
      {:ok, token}
    else
      _error -> {:error, "session could not be issued"}
    end
  end
end
