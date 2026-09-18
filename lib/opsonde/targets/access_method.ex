defmodule Opsonde.Targets.AccessMethod do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "access_methods"
    repo Opsonde.Repo

    custom_indexes do
      index [:target_id]
      index [:provider_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :available_for_target do
      argument :target_id, :uuid, allow_nil?: false

      filter expr(
               target_id == ^arg(:target_id) and active == true and target.active == true and
                 provider.kind == :target and provider.enabled == true and
                 provider.check_status == :passed and
                 provider.checked_revision == provider.revision and
                 provider_revision == provider.revision
             )

      prepare build(sort: [priority: :asc, inserted_at: :asc, id: :asc], limit: 100)
    end

    read :available do
      argument :target_id, :uuid, allow_nil?: false

      argument :capability, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      filter expr(
               target_id == ^arg(:target_id) and active == true and target.active == true and
                 provider.kind == :target and provider.enabled == true and
                 provider.check_status == :passed and
                 provider.checked_revision == provider.revision and
                 provider_revision == provider.revision and has(capabilities, ^arg(:capability))
             )

      prepare build(sort: [priority: :asc, inserted_at: :asc, id: :asc])
    end

    read :for_use do
      get? true

      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :capability, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_revision) and active == true and
                 target.active == true and provider.kind == :target and provider.enabled == true and
                 provider.check_status == :passed and
                 provider.checked_revision == provider.revision and
                 provider_revision == provider.revision and has(capabilities, ^arg(:capability))
             )
    end

    create :create do
      primary? true

      accept [
        :target_id,
        :provider_id,
        :name,
        :platform,
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities
      ]

      validate Opsonde.Targets.Validations.TargetProvider
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :target_id,
        :provider_id,
        :name,
        :platform,
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities
      ]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.Validations.TargetProvider
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

    policy action([:available_for_target, :available, :for_use]) do
      forbid_if always()
    end

    policy action([:read, :page]) do
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

    attribute :platform, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :method, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :endpoint, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1_024
    end

    attribute :provider_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0, max: 10_000
    end

    attribute :capabilities, {:array, :string} do
      allow_nil? false
      public? true
      default []
      constraints max_length: 100, items: [min_length: 1, max_length: 120]
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
    belongs_to :target, Opsonde.Targets.Target do
      allow_nil? false
      public? true
    end

    belongs_to :provider, Opsonde.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_target_name, [:target_id, :name]
  end
end
