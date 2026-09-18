defmodule Opsonde.Providers.Provider do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Providers,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  cloak do
    vault(Opsonde.Providers.Vault)
    attributes([:credentials])
  end

  postgres do
    table "providers"
    repo Opsonde.Repo
  end

  field_policies do
    private_fields :include

    field_policy :credentials do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name, :role, :adapter_type, :configuration, :credentials]
      change Opsonde.Providers.Provider.Changes.ValidateAdapter
    end

    update :update do
      primary? true
      accept [:name, :configuration, :credentials]

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Opsonde.Providers.Provider.Validations.CurrentRevision
      change set_attribute(:enabled, false)
      change set_attribute(:checked_revision, nil)
      change set_attribute(:check_status, nil)
      change set_attribute(:check_category, nil)
      change set_attribute(:check_message, nil)
      change set_attribute(:checked_at, nil)
      change optimistic_lock(:revision)
    end

    action :check, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :id, :uuid, allow_nil?: false

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :input, :map, allow_nil?: false, default: %{}
      run Opsonde.Providers.Provider.Actions.Check
    end

    update :record_check do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :check_status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:passed, :failed]]

      argument :check_category, :atom,
        constraints: [
          one_of: [
            :invalid_configuration,
            :authentication,
            :unreachable,
            :capability,
            :provider_failure
          ]
        ]

      argument :check_message, :string

      validate Opsonde.Providers.Provider.Validations.CurrentRevision
      change set_attribute(:checked_revision, arg(:expected_revision))
      change set_attribute(:check_status, arg(:check_status))
      change set_attribute(:check_category, arg(:check_category))
      change set_attribute(:check_message, arg(:check_message))
      change atomic_update(:checked_at, expr(now()))

      change atomic_update(
               :enabled,
               expr(if ^arg(:check_status) == :failed, do: false, else: enabled)
             )
    end

    update :enable do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate attribute_equals(:check_status, :passed),
        message: "has not passed its current check"

      validate compare(:checked_revision, is_equal: {:ref, :revision}),
        message: "does not have a current check"

      validate Opsonde.Providers.Provider.Validations.CurrentRevision
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Opsonde.Providers.Provider.Validations.CurrentRevision
      change set_attribute(:enabled, false)
    end
  end

  policies do
    policy action([:create, :update, :check, :enable, :disable]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:record_check) do
      forbid_if always()
    end

    policy action_type(:read) do
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

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ai, :signal, :target, :inventory, :notification]
    end

    attribute :adapter_type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :configuration, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :credentials, :map do
      allow_nil? false
      sensitive? true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :checked_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :check_status, :atom do
      public? true
      constraints one_of: [:passed, :failed]
    end

    attribute :check_category, :atom do
      public? true

      constraints one_of: [
                    :invalid_configuration,
                    :authentication,
                    :unreachable,
                    :capability,
                    :provider_failure
                  ]
    end

    attribute :check_message, :string do
      public? true
    end

    attribute :checked_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name]
  end
end
