defmodule Opsonde.Accounts.UserIdentity do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_identities"
    repo Opsonde.Repo
  end

  actions do
    defaults [:read]

    create :link do
      public? false
      accept [:strategy, :uid, :user_id]
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :strategy, :string do
      allow_nil? false
    end

    attribute :uid, :string do
      allow_nil? false
    end
  end

  relationships do
    belongs_to :user, Opsonde.Accounts.User do
      allow_nil? false
    end
  end

  identities do
    identity :unique_on_strategy_and_uid, [:strategy, :uid]
    identity :one_identity_per_strategy_and_user, [:strategy, :user_id]
  end
end
