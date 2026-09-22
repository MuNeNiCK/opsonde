defmodule Opsonde.Cases.Case do
  use Ash.Resource,
    otp_app: :opsonde,
    domain: Opsonde.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Opsonde.Cases.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "cases"
    repo Opsonde.Repo

    custom_indexes do
      index [:authority_setting_id]
      index [:initial_target_id]
      index [:selected_target_id]
      index [:current_owner_id]

      index [:incident_key],
        unique: true,
        name: "cases_active_incident_key_index",
        where: "incident_key IS NOT NULL AND status IN ('running', 'needs_attention')"
    end

    check_constraints do
      check_constraint [:selected_target_id, :selected_target_revision],
                       "cases_selected_target_pair",
                       check:
                         "(selected_target_id IS NULL AND selected_target_revision IS NULL) OR " <>
                           "(selected_target_id IS NOT NULL AND selected_target_revision IS NOT NULL)",
                       message: "must be set together"
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      argument :query, :ci_string, constraints: [min_length: 1, max_length: 200]

      argument :status, :atom,
        constraints: [one_of: [:running, :needs_attention, :resolved, :cancelled]]

      argument :alert_state, :atom, constraints: [one_of: [:firing, :recovered, :not_applicable]]

      argument :sort, :atom,
        allow_nil?: false,
        default: :updated_desc,
        constraints: [one_of: [:updated_desc, :updated_asc, :severity_desc]]

      filter expr(
               (is_nil(^arg(:query)) or contains(title, ^arg(:query)) or
                  contains(source, ^arg(:query)) or contains(source_ref, ^arg(:query))) and
                 (is_nil(^arg(:status)) or status == ^arg(:status)) and
                 (is_nil(^arg(:alert_state)) or alert_state == ^arg(:alert_state))
             )

      prepare Opsonde.Cases.Case.Preparations.Queue
    end

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

    read :active_by_incident_key do
      get? true

      argument :incident_key, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      filter expr(incident_key == ^arg(:incident_key) and status in [:running, :needs_attention])
    end

    read :unresolved_signals_without_target do
      filter expr(
               trigger_kind == :signal and alert_state == :firing and
                 status in [:running, :needs_attention] and is_nil(selected_target_id)
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create_record do
      accept [
        :trigger_kind,
        :source,
        :source_ref,
        :incident_key,
        :title,
        :severity,
        :alert_state,
        :report_language,
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
        :selected_target_id,
        :selected_target_revision,
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
        :required_human_input,
        :selected_target_id,
        :selected_target_revision
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

      argument :report_language, :atom, constraints: [one_of: [:en, :ja]]

      argument :initial_context, :map, allow_nil?: false, default: %{}
      argument :initial_target_id, :uuid

      argument :incident_key, :string, constraints: [min_length: 64, max_length: 64]

      run {Opsonde.Cases.Case.Actions.Open, []}
    end

    action :reconnect, :struct do
      constraints instance_of: Opsonde.Cases.ReconnectSnapshot
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Opsonde.Cases.Case.Actions.Reconnect
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

    action :resume_after_target_registration, :struct do
      constraints instance_of: Opsonde.Cases.ResolutionRun
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :external_identity_id, :uuid, allow_nil?: false

      argument :expected_identity_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      run {Opsonde.Cases.Case.Actions.Lifecycle, operation: :resume_after_target_registration}
    end

    action :search_targets, :struct do
      constraints instance_of: Opsonde.Cases.BudgetResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      argument :max_results, :integer,
        allow_nil?: false,
        default: 20,
        constraints: [min: 1, max: 50]

      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Opsonde.Cases.Case.Actions.TargetSearch
    end

    action :select_target, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :evidence_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 100]

      argument :target_id, :uuid, allow_nil?: false
      argument :target_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      run Opsonde.Cases.Case.Actions.TargetSelection
    end

    action :route_target_discovery, :struct do
      constraints instance_of: Opsonde.Cases.BudgetResult
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Opsonde.Cases.Case.Actions.TargetDiscoveryRoute
    end

    action :route_related_target, :struct do
      constraints instance_of: Opsonde.Cases.BudgetResult
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Opsonde.Cases.Case.Actions.RelatedTargetRoute
    end

    action :route_downstream_decision, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Opsonde.Cases.Case.Actions.DownstreamDecisionRoute
    end
  end

  policies do
    policy action([
             :open,
             :claim,
             :handoff,
             :request_cancellation,
             :record_source_recovery,
             :resume,
             :search_targets,
             :select_target
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([
             :by_trigger,
             :active_by_incident_key,
             :unresolved_signals_without_target,
             :create_record,
             :update_record,
             :require_attention,
             :resume_after_target_registration,
             :route_target_discovery,
             :route_related_target,
             :route_downstream_decision
           ]) do
      forbid_if always()
    end

    policy action([:read, :page, :reconnect]) do
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

    attribute :incident_key, :string do
      public? false
      constraints min_length: 64, max_length: 64
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

    attribute :report_language, :atom do
      allow_nil? false
      public? true
      default :en
      constraints one_of: [:en, :ja]
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

    attribute :selected_target_revision, :integer do
      public? true
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

    belongs_to :selected_target, Opsonde.Targets.Target do
      public? true
    end

    belongs_to :current_owner, Opsonde.Accounts.User do
      public? true
    end

    has_many :resolution_runs, Opsonde.Cases.ResolutionRun
    has_many :events, Opsonde.Cases.CaseEvent
    has_many :reports, Opsonde.Reports.Report
  end

  calculations do
    calculate :severity_rank,
              :integer,
              expr(
                cond do
                  severity == :critical -> 4
                  severity == :error -> 3
                  severity == :warning -> 2
                  true -> 1
                end
              )
  end

  identities do
    identity :unique_trigger, [:trigger_kind, :source, :source_ref]
  end
end
