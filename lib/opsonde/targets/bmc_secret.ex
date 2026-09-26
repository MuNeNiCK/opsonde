defmodule Opsonde.Targets.BMCSecret do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  cloak do
    vault(Opsonde.Vault)
    attributes([:value])
  end

  postgres do
    table "bmc_secrets"
    repo Opsonde.Repo
  end

  field_policies do
    private_fields :include

    field_policy :value do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :for_use do
      get? true
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :access_method_id, :uuid, allow_nil?: false

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_revision) and
                 access_method_id == ^arg(:access_method_id) and active == true and
                 access_method.active == true
             )

      prepare build(load: [:value])
    end

    create :create do
      primary? true
      accept [:access_method_id, :name, :value]
      validate Opsonde.Targets.BMCSecret.Validations.BoundMethod
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:name, :value]
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.BMCSecret.Validations.BoundMethod
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:for_use) do
      forbid_if always()
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :value, :string do
      allow_nil? false
      sensitive? true
      constraints min_length: 1, max_length: 4_096
    end

    attribute :active, :boolean do
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

    timestamps()
  end

  relationships do
    belongs_to :access_method, Opsonde.Targets.AccessMethod do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_method_name, [:access_method_id, :name]
  end
end
