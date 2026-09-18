defmodule Opsonde.Cases.ResolutionRun do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "resolution_runs"
    repo Opsonde.Repo
    identity_wheres_to_sql one_active_run: "active = TRUE"

    custom_indexes do
      index [:resumed_by_id]
    end
  end

  actions do
    defaults [:read]

    read :active_for_case do
      get? true
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id) and active == true)
    end

    create :create_record do
      accept [
        :case_id,
        :generation,
        :active,
        :status,
        :authority_mode,
        :max_elapsed_seconds,
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :max_no_progress_turns,
        :turn_count,
        :target_request_count,
        :effect_count,
        :related_target_count,
        :ai_usage_units,
        :no_progress_turns,
        :started_at,
        :deadline_at,
        :resume_reason,
        :resumed_by_id
      ]
    end

    update :retire do
      accept [:status, :ended_at]
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate attribute_equals(:active, true)
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end

    update :pause do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate attribute_equals(:active, true)
      change set_attribute(:status, :needs_attention)
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:active_for_case, :create_record, :retire, :pause]) do
      forbid_if always()
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :needs_attention, :completed, :cancelled, :superseded]
    end

    attribute :authority_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:readonly, :ask, :auto, :full_access]
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

    attribute :turn_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :target_request_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :effect_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :related_target_count, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :ai_usage_units, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :no_progress_turns, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :deadline_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :ended_at, :utc_datetime_usec do
      public? true
    end

    attribute :resume_reason, :string do
      public? true
      constraints max_length: 500
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
    belongs_to :case, Opsonde.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resumed_by, Opsonde.Accounts.User do
      public? true
    end

    has_many :events, Opsonde.Cases.CaseEvent
  end

  identities do
    identity :unique_generation, [:case_id, :generation]

    identity :one_active_run, [:case_id] do
      where expr(active == true)
    end
  end
end
