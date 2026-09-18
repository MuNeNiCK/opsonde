defmodule Opsonde.Accounts.OIDCProvider do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "oidc_providers"
    repo Opsonde.Repo
  end

  field_policies do
    private_fields :include

    field_policy :client_secret do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  cloak do
    vault(Opsonde.Vault)
    attributes([:client_secret])
  end

  actions do
    defaults [:read]

    read :current do
      get? true
      filter expr(singleton == "oidc")
    end

    create :create_configuration do
      public? false
      accept [:issuer, :client_id, :client_secret, :enabled]
      change set_attribute(:singleton, "oidc")
    end

    update :update_configuration do
      public? false
      accept [:issuer, :client_id, :client_secret, :enabled]

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :configure, :struct do
      constraints instance_of: __MODULE__

      argument :issuer, :string, allow_nil?: false
      argument :client_id, :string, allow_nil?: false
      argument :client_secret, :string, allow_nil?: false, sensitive?: true
      argument :enabled, :boolean, allow_nil?: false, default: true

      run Opsonde.Accounts.OIDCProvider.Configure
    end
  end

  policies do
    policy action(:configure) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :issuer, :string do
      allow_nil? false
      public? true
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
    end

    attribute :client_secret, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :singleton, :string do
      allow_nil? false
      default "oidc"
    end

    timestamps()
  end

  identities do
    identity :one_oidc_provider, [:singleton]
  end
end
