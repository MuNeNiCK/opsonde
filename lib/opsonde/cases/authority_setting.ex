defmodule Opsonde.Cases.AuthoritySetting do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "authority_settings"
    repo Opsonde.Repo
    identity_wheres_to_sql one_current: "active = TRUE"

    custom_indexes do
      index [:changed_by_id]
    end
  end

  actions do
    defaults [:read]

    read :current do
      get? true
      filter expr(active == true)
    end

    create :create_revision do
      accept [
        :authority_mode,
        :signal_automation_enabled,
        :max_elapsed_seconds,
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :max_no_progress_turns,
        :setting_revision,
        :active,
        :reason,
        :changed_by_id
      ]
    end

    update :retire do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate attribute_equals(:active, true)
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end

    action :configure, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :expected_setting_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :authority_mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:readonly, :ask, :auto, :full_access]]

      argument :signal_automation_enabled, :boolean, allow_nil?: false

      argument :max_elapsed_seconds, :integer,
        allow_nil?: false,
        constraints: [min: 60, max: 2_592_000]

      argument :max_resolver_turns, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 1_000]

      argument :max_target_requests, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 10_000]

      argument :max_effects, :integer,
        allow_nil?: false,
        constraints: [min: 0, max: 1_000]

      argument :max_related_targets, :integer,
        allow_nil?: false,
        constraints: [min: 0, max: 1_000]

      argument :max_ai_usage_units, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 1_000_000_000]

      argument :max_no_progress_turns, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 100]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      run Opsonde.Cases.AuthoritySetting.Actions.Configure
    end
  end

  policies do
    policy action(:configure) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create_revision, :retire]) do
      forbid_if always()
    end

    policy action([:read, :current]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :string do
      allow_nil? false
      default "global"
      constraints min_length: 1, max_length: 40
    end

    attribute :authority_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:readonly, :ask, :auto, :full_access]
    end

    attribute :signal_automation_enabled, :boolean do
      allow_nil? false
      public? true
    end

    attribute :max_elapsed_seconds, :integer do
      allow_nil? false
      public? true
      constraints min: 60, max: 2_592_000
    end

    attribute :max_resolver_turns, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 1_000
    end

    attribute :max_target_requests, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 10_000
    end

    attribute :max_effects, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :max_related_targets, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :max_ai_usage_units, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 1_000_000_000
    end

    attribute :max_no_progress_turns, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 100
    end

    attribute :setting_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :changed_by, Opsonde.Accounts.User do
      public? true
    end
  end

  identities do
    identity :one_current, [:scope] do
      where expr(active == true)
    end

    identity :unique_setting_revision, [:scope, :setting_revision]
  end
end
