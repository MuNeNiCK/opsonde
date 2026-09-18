defmodule Opsonde.Providers.AIUsageRoleAssignment do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Providers,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ai_usage_role_assignments"
    repo Opsonde.Repo
  end

  actions do
    defaults [:read]

    read :eligible do
      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:resolver, :reviewer]]

      filter expr(
               role == ^arg(:role) and enabled == true and provider.kind == :ai and
                 provider.enabled == true and provider.check_status == :passed and
                 provider.checked_revision == provider.revision
             )

      prepare build(sort: [priority: :asc, inserted_at: :asc, id: :asc], load: [:provider])
    end

    read :resolver_fallback do
      get? true

      argument :id, :uuid, allow_nil?: false

      argument :expected_assignment_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :expected_provider_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_assignment_revision) and
                 role == :resolver and enabled == true and provider.kind == :ai and
                 provider.enabled == true and provider.check_status == :passed and
                 provider.checked_revision == provider.revision and
                 provider.revision == ^arg(:expected_provider_revision)
             )

      prepare build(load: [:provider])
    end

    create :create do
      primary? true
      accept [:provider_id, :role, :priority]
      validate Opsonde.Providers.AIUsageRoleAssignment.Validations.AIProvider
    end

    update :update do
      primary? true
      accept [:priority, :enabled]

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Opsonde.Providers.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :select_resolver, :struct do
      constraints instance_of: Opsonde.Providers.AI.Selection
      run {Opsonde.Providers.AIUsageRoleAssignment.Actions.Select, role: :resolver}
    end

    action :select_reviewer, :struct do
      constraints instance_of: Opsonde.Providers.AI.Selection

      argument :resolver_assignment_id, :uuid, allow_nil?: false

      argument :resolver_assignment_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :resolver_provider_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      run {Opsonde.Providers.AIUsageRoleAssignment.Actions.Select, role: :reviewer}
    end
  end

  policies do
    policy action([:create, :update]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:eligible, :resolver_fallback]) do
      forbid_if always()
    end

    policy action([:select_resolver, :select_reviewer]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:resolver, :reviewer]
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0, max: 10_000
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

    timestamps()
  end

  relationships do
    belongs_to :provider, Opsonde.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_provider_role, [:provider_id, :role]
  end
end
