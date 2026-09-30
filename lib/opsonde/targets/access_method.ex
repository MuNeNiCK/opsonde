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
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities
      ]

      validate Opsonde.Targets.AccessMethod.Validations.TargetProvider
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :target_id,
        :provider_id,
        :name,
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities
      ]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.AccessMethod.Validations.TargetProvider
      change Opsonde.Targets.AccessMethod.Changes.InvalidateCheck
      change optimistic_lock(:revision)
    end

    action :check, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :invocation, :map, allow_nil?: false, default: %{}
      run Opsonde.Targets.AccessMethod.Actions.Check
    end

    update :begin_check do
      public? false
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :attempt_id, :uuid, allow_nil?: false
      validate Opsonde.Validations.CurrentRevision
      validate attribute_equals(:active, true)
      change set_attribute(:check_attempt_id, arg(:attempt_id))
      change set_attribute(:check_status, :checking)
      change set_attribute(:checked_at, nil)
      change set_attribute(:check_message, nil)
      change set_attribute(:checked_connection_revision, nil)
      change set_attribute(:checked_target_revision, nil)
      change set_attribute(:observed_capabilities, [])
      change set_attribute(:operation_catalog, nil)
      change optimistic_lock(:revision)
    end

    update :record_check do
      public? false
      require_atomic? false
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :attempt_id, :uuid, allow_nil?: false
      argument :connection_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :target_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :status, :atom, allow_nil?: false, constraints: [one_of: [:passed, :failed]]
      argument :message, :string, constraints: [max_length: 500]

      argument :capability_catalog, :struct,
        constraints: Opsonde.Providers.Target.Capabilities.constraints()

      validate Opsonde.Validations.CurrentRevision
      validate Opsonde.Targets.AccessMethod.Validations.CheckSnapshot
      change set_attribute(:check_status, arg(:status))
      change set_attribute(:check_message, arg(:message))
      change set_attribute(:checked_connection_revision, arg(:connection_revision))
      change set_attribute(:checked_target_revision, arg(:target_revision))
      change set_attribute(:operation_catalog, arg(:capability_catalog))

      change fn changeset, _context ->
        catalog = Ash.Changeset.get_argument(changeset, :capability_catalog)

        capabilities =
          if catalog,
            do: Enum.uniq(Enum.map(catalog.observations ++ catalog.effects, & &1.capability)),
            else: []

        Ash.Changeset.change_attribute(changeset, :observed_capabilities, capabilities)
      end

      change atomic_update(:checked_at, expr(now()))
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
    policy action([:create, :update, :deactivate, :check]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:available_for_target, :available, :for_use, :begin_check, :record_check]) do
      forbid_if always()
    end

    policy action([:read, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  preparations do
    prepare build(load: [:check_current])
  end

  changes do
    change load(:check_current), on: [:create, :update]
  end

  attributes do
    uuid_primary_key :id

    attribute :connection_revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    attribute :check_attempt_id, :uuid

    attribute :check_status, :atom,
      public?: true,
      constraints: [one_of: [:checking, :passed, :failed]]

    attribute :checked_connection_revision, :integer, public?: true, constraints: [min: 1]
    attribute :checked_target_revision, :integer, public?: true, constraints: [min: 1]
    attribute :check_message, :string, public?: true, constraints: [max_length: 500]
    attribute :checked_at, :utc_datetime_usec, public?: true

    attribute :observed_capabilities, {:array, :string},
      allow_nil?: false,
      public?: true,
      default: [],
      constraints: [max_length: 100, items: [min_length: 1, max_length: 120]]

    attribute :operation_catalog, :struct,
      constraints: Opsonde.Providers.Target.Capabilities.constraints()

    attribute :name, :string do
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

  calculations do
    calculate :check_current,
              :boolean,
              expr(
                if(
                  active == true and target.active == true and provider.kind == :target and
                    provider.enabled == true and provider_revision == provider.revision and
                    is_nil(provider.retired_at) and check_status == :passed and
                    checked_connection_revision == connection_revision and
                    checked_target_revision == target.revision, do: true, else: false)
              ) do
      public? true
    end
  end

  identities do
    identity :unique_target_name, [:target_id, :name]
  end
end
