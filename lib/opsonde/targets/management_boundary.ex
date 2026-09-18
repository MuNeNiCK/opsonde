defmodule Opsonde.Targets.ManagementBoundary do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "management_boundaries"
    repo Opsonde.Repo
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :kind, :facts]
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
    end

    update :update do
      primary? true
      accept [:name, :kind, :facts]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate {Opsonde.Validations.BoundedMap, attribute: :facts}
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

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :facts, :map do
      allow_nil? false
      public? true
      default %{}
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

  identities do
    identity :unique_name, [:name]
  end
end
