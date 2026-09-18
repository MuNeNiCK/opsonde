defmodule Opsonde.Cases.Case do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cases"
    repo Opsonde.Repo

    custom_indexes do
      index [:authority_setting_id]
      index [:initial_target_id]
      index [:current_owner_id]
    end
  end

  actions do
    defaults [:read]

    read :by_trigger do
      get? true
      argument :trigger_kind, :atom, allow_nil?: false
      argument :source, :string, allow_nil?: false
      argument :source_ref, :string, allow_nil?: false

      filter expr(
               trigger_kind == ^arg(:trigger_kind) and source == ^arg(:source) and
                 source_ref == ^arg(:source_ref)
             )
    end

    create :create_record do
      accept [
        :trigger_kind,
        :source,
        :source_ref,
        :title,
        :severity,
        :alert_state,
        :status,
        :initial_context,
        :authority_setting_id,
        :authority_setting_revision,
        :authority_mode,
        :max_elapsed_seconds,
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :max_no_progress_turns,
        :cancel_requested,
        :pending_intent,
        :stop_reason,
        :required_human_input,
        :initial_target_id,
        :current_owner_id
      ]

      validate {Opsonde.Validations.BoundedMap, attribute: :initial_context}
      validate {Opsonde.Validations.BoundedMap, attribute: :pending_intent}
    end

    update :update_record do
      accept [
        :current_owner_id,
        :status,
        :cancel_requested,
        :alert_state,
        :source_recovered_at,
        :stop_reason,
        :pending_intent,
        :required_human_input
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Opsonde.Validations.CurrentRevision
      validate {Opsonde.Validations.BoundedMap, attribute: :pending_intent}
      change optimistic_lock(:revision)
    end

    action :open, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :trigger_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:manual, :signal, :audit]]

      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :source_ref, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :title, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      argument :severity, :atom,
        allow_nil?: false,
        constraints: [one_of: [:info, :warning, :error, :critical]]

      argument :alert_state, :atom,
        allow_nil?: false,
        constraints: [one_of: [:firing, :not_applicable]]

      argument :initial_context, :map, allow_nil?: false, default: %{}
      argument :initial_target_id, :uuid

      run {Opsonde.Cases.Case.Actions.Open, []}
    end

    action :claim, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :claim}
    end

    action :handoff, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :owner_id, :uuid, allow_nil?: false
      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :handoff}
    end

    action :request_cancellation, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :request_cancellation}
    end

    action :record_source_recovery, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :record_source_recovery}
    end

    action :require_attention, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :expected_run_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :pending_intent, :map, allow_nil?: false, default: %{}

      argument :required_human_input, :string, constraints: [min_length: 1, max_length: 1_000]

      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :require_attention}
    end

    action :resume, :struct do
      constraints instance_of: Opsonde.Cases.ResolutionRun
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :expected_run_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :authority_mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:readonly, :ask, :auto, :full_access]]

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

      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :resume}
    end
  end

  policies do
    policy action([
             :open,
             :claim,
             :handoff,
             :request_cancellation,
             :record_source_recovery,
             :resume
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:by_trigger, :create_record, :update_record, :require_attention]) do
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

    attribute :trigger_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:manual, :signal, :audit]
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :source_ref, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :severity, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:info, :warning, :error, :critical]
    end

    attribute :alert_state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:firing, :recovered, :not_applicable]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :needs_attention, :resolved, :cancelled]
    end

    attribute :initial_context, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :authority_setting_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
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

    attribute :cancel_requested, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :stop_reason, :string do
      public? true
      constraints max_length: 500
    end

    attribute :pending_intent, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :required_human_input, :string do
      public? true
      constraints max_length: 1_000
    end

    attribute :source_recovered_at, :utc_datetime_usec do
      public? true
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
    belongs_to :authority_setting, Opsonde.Cases.AuthoritySetting do
      allow_nil? false
      public? true
    end

    belongs_to :initial_target, Opsonde.Targets.Target do
      public? true
    end

    belongs_to :current_owner, Opsonde.Accounts.User do
      public? true
    end

    has_many :resolution_runs, Opsonde.Cases.ResolutionRun
    has_many :events, Opsonde.Cases.CaseEvent
  end

  identities do
    identity :unique_trigger, [:trigger_kind, :source, :source_ref]
  end
end
