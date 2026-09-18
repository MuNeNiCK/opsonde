defmodule Opsonde.Accounts.User.Preparations.ResolveOIDC do
  use Ash.Resource.Preparation

  alias AshAuthentication.Strategy.OAuth2
  alias AshAuthentication.Strategy.OAuth2.UserResolver
  alias AshAuthentication.UserIdentity
  alias Opsonde.Accounts.{OIDCRequest, User}

  require Ash.Query

  @missing_id "00000000-0000-0000-0000-000000000000"

  @impl true
  def prepare(query, _options, context) do
    with {:ok, strategy} <- AshAuthentication.Info.find_strategy(query, context, []),
         user_info when is_map(user_info) <- Ash.Query.get_argument(query, :user_info),
         uid when is_binary(uid) <- OAuth2.uid_from_user_info(user_info) do
      resolve(query, context, strategy, uid, user_info)
    else
      _error -> Ash.Query.filter(query, id == ^@missing_id)
    end
  end

  defp resolve(query, context, strategy, uid, user_info) do
    options = [tenant: context.tenant, actor: context.actor]

    case UserResolver.fetch_identity(strategy, uid, options) do
      {:ok, identity} ->
        Ash.Query.filter(query, id == ^identity.user_id)

      :error ->
        explicitly_link(query, context, strategy, user_info)
    end
  end

  defp explicitly_link(
         query,
         %{actor: %User{} = actor} = context,
         strategy,
         user_info
       ) do
    with request_id when is_binary(request_id) <-
           Ash.Resource.get_metadata(actor, :oidc_link_request_id),
         {:ok, %OIDCRequest{} = request} <-
           Ash.get(OIDCRequest, request_id, authorize?: false),
         true <- link_request_valid?(request, actor),
         false <-
           UserResolver.has_identity_for_strategy?(strategy, actor,
             tenant: context.tenant,
             actor: context.actor
           ) do
      oauth_tokens = Ash.Query.get_argument(query, :oauth_tokens)

      query
      |> Ash.Query.filter(id == ^actor.id)
      |> Ash.Query.after_action(fn _query, [user] ->
        link_identity(request, actor, strategy, user_info, oauth_tokens, context, user)
      end)
    else
      _error -> Ash.Query.filter(query, id == ^@missing_id)
    end
  end

  defp explicitly_link(query, _context, _strategy, _user_info),
    do: Ash.Query.filter(query, id == ^@missing_id)

  defp link_identity(request, actor, strategy, user_info, oauth_tokens, context, user) do
    Ash.transact([strategy.identity_resource, OIDCRequest], fn ->
      with {:ok, _identity} <-
             UserIdentity.Actions.upsert(
               strategy.identity_resource,
               %{
                 user_info: user_info,
                 oauth_tokens: oauth_tokens,
                 strategy: strategy.name,
                 user_id: actor.id
               },
               actor: actor,
               tenant: context.tenant,
               authorize?: false
             ),
           {:ok, _completed} <-
             Opsonde.Accounts.complete_oidc_request(
               request,
               request.revision,
               actor.id,
               nil,
               authorize?: false
             ) do
        [user]
      end
    end)
  end

  defp link_request_valid?(request, actor) do
    ((request.purpose == :link and request.user_id == actor.id and request.started_at) &&
       is_nil(request.completed_at)) and
      DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt
  end
end
