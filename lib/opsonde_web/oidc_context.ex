defmodule OpsondeWeb.OIDCContext do
  @moduledoc false

  import Plug.Conn

  alias Opsonde.Accounts.{OIDCRequest, User}

  def init(options), do: options

  def call(conn, _options) do
    with request_id when is_binary(request_id) <- get_session(conn, :opsonde_oidc_request_id),
         {:ok, %OIDCRequest{purpose: :link} = request} <-
           Ash.get(OIDCRequest, request_id, authorize?: false),
         true <- valid_link_request?(request),
         {:ok, %User{} = user} <- Ash.get(User, request.user_id, authorize?: false) do
      actor = Ash.Resource.set_metadata(user, %{oidc_link_request_id: request.id})
      Ash.PlugHelpers.set_actor(conn, actor)
    else
      _other -> conn
    end
  end

  defp valid_link_request?(request) do
    request.started_at && is_nil(request.completed_at) &&
      DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt
  end
end
