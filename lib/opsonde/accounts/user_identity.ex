defmodule Opsonde.Accounts.UserIdentity do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.UserIdentity]

  user_identity do
    user_resource Opsonde.Accounts.User
  end

  postgres do
    table "user_identities"
    repo Opsonde.Repo
  end

  actions do
    defaults [:read]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  identities do
    identity :one_identity_per_strategy_and_user, [:strategy, :user_id]
  end
end
