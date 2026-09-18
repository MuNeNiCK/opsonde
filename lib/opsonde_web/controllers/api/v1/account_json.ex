defmodule OpsondeWeb.API.V1.AccountJSON do
  @moduledoc false

  def data(user) do
    %{
      id: user.id,
      email: to_string(user.email),
      role: user.role,
      role_version: user.role_version,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
