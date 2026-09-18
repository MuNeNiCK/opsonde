defmodule Opsonde.Cases do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Cases.AuthoritySetting do
      define :list_authority_settings, action: :read
      define :current_authority_setting, action: :current
      define :create_authority_setting_revision, action: :create_revision
      define :retire_authority_setting, action: :retire, args: [:expected_revision]

      define :configure_authority_setting,
        action: :configure,
        args: [
          :expected_setting_revision,
          :authority_mode,
          :signal_automation_enabled,
          :max_elapsed_seconds,
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units,
          :max_no_progress_turns,
          :reason
        ]
    end

    resource Opsonde.Cases.Case do
      define :list_cases, action: :read
      define :get_case, action: :read, get_by: [:id]
      define :case_by_trigger, action: :by_trigger, args: [:trigger_kind, :source, :source_ref]
      define :create_case_record, action: :create_record
      define :update_case_record, action: :update_record, args: [:expected_revision]

      define :open_case,
        action: :open,
        args: [
          :trigger_kind,
          :source,
          :source_ref,
          :title,
          :severity,
          :alert_state,
          :initial_context,
          :initial_target_id
        ]

      define :claim_case, action: :claim, args: [:id, :expected_revision]
      define :handoff_case, action: :handoff, args: [:id, :expected_revision, :owner_id]

      define :request_case_cancellation,
        action: :request_cancellation,
        args: [:id, :expected_revision]

      define :record_case_source_recovery,
        action: :record_source_recovery,
        args: [:id, :expected_revision]

      define :require_case_attention,
        action: :require_attention,
        args: [
          :id,
          :expected_revision,
          :resolution_run_id,
          :expected_run_revision,
          :idempotency_key,
          :reason,
          :pending_intent,
          :required_human_input
        ]

      define :resume_case,
        action: :resume,
        args: [
          :id,
          :expected_case_revision,
          :resolution_run_id,
          :expected_run_revision,
          :authority_mode,
          :max_elapsed_seconds,
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units,
          :max_no_progress_turns,
          :reason
        ]
    end

    resource Opsonde.Cases.ResolutionRun do
      define :list_resolution_runs, action: :read
      define :get_resolution_run, action: :read, get_by: [:id]
      define :active_resolution_run, action: :active_for_case, args: [:case_id]
      define :create_resolution_run_record, action: :create_record
      define :retire_resolution_run, action: :retire, args: [:expected_revision]
      define :pause_resolution_run, action: :pause, args: [:expected_revision]

      define :update_resolution_run_counters,
        action: :update_counters,
        args: [:expected_revision]

      define :charge_resolution_run,
        action: :charge,
        args: [
          :case_id,
          :resolution_run_id,
          :kind,
          :amount,
          :idempotency_key,
          :pending_intent,
          :required_human_input
        ]
    end

    resource Opsonde.Cases.CaseEvent do
      define :list_case_events, action: :timeline

      define :case_event_by_idempotency,
        action: :by_idempotency,
        args: [:case_id, :idempotency_key]

      define :create_case_event_record, action: :create_record
    end

    resource Opsonde.Cases.Turn do
      define :list_turns, action: :read
      define :get_turn, action: :read, get_by: [:id]

      define :turn_by_idempotency,
        action: :by_idempotency,
        args: [:resolution_run_id, :idempotency_key]

      define :create_turn_record, action: :create_record
      define :complete_turn_record, action: :complete_record, args: [:expected_revision]

      define :start_turn,
        action: :start,
        args: [
          :case_id,
          :resolution_run_id,
          :idempotency_key,
          :intent,
          :pending_intent,
          :required_human_input
        ]

      define :complete_turn,
        action: :complete,
        args: [
          :id,
          :expected_revision,
          :result,
          :progress_kind,
          :pending_intent,
          :required_human_input
        ]
    end

    resource Opsonde.Cases.Evidence do
      define :list_evidence, action: :read

      define :evidence_by_idempotency,
        action: :by_idempotency,
        args: [:case_id, :idempotency_key]

      define :create_evidence_record, action: :create_record

      define :append_evidence,
        action: :append,
        args: [
          :case_id,
          :resolution_run_id,
          :turn_id,
          :idempotency_key,
          :kind,
          :source,
          :source_ref,
          :content,
          :observed_at
        ]
    end
  end
end
