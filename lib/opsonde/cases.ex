defmodule Opsonde.Cases do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Cases.AuthoritySetting do
      define :list_authority_settings, action: :read
      define :page_authority_settings, action: :page
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

      define :page_cases,
        action: :page,
        args: [:query, :status, :alert_state, :sort]

      define :get_case, action: :read, get_by: [:id]
      define :case_reconnect_snapshot, action: :reconnect, args: [:id]
      define :case_by_trigger, action: :by_trigger, args: [:trigger_kind, :source, :source_ref]

      define :active_case_by_incident_key,
        action: :active_by_incident_key,
        args: [:incident_key]

      define :unresolved_signal_cases_without_target,
        action: :unresolved_signals_without_target

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
          :initial_target_id,
          :report_language
        ]

      define :open_correlated_signal_case,
        action: :open,
        args: [
          :trigger_kind,
          :source,
          :source_ref,
          :title,
          :severity,
          :alert_state,
          :initial_context,
          :initial_target_id,
          :report_language,
          :incident_key
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

      define :resume_case_after_target_registration,
        action: :resume_after_target_registration,
        args: [:id, :external_identity_id, :expected_identity_revision]

      define :search_case_targets,
        action: :search_targets,
        args: [
          :id,
          :resolution_run_id,
          :idempotency_key,
          :query,
          :max_results,
          :pending_intent,
          :required_human_input
        ]

      define :select_case_target,
        action: :select_target,
        args: [
          :id,
          :expected_revision,
          :resolution_run_id,
          :evidence_ids,
          :target_id,
          :target_revision,
          :reason,
          :idempotency_key
        ]

      define :route_target_discovery,
        action: :route_target_discovery,
        args: [:turn_id]

      define :route_related_target,
        action: :route_related_target,
        args: [:turn_id]

      define :route_downstream_decision,
        action: :route_downstream_decision,
        args: [:turn_id]
    end

    resource Opsonde.Cases.ResolutionRun do
      define :list_resolution_runs, action: :read
      define :get_resolution_run, action: :read, get_by: [:id]
      define :resolution_runs_for_case, action: :for_case, args: [:case_id]
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

      define :page_case_events,
        action: :page_for_case,
        args: [:case_id]

      define :case_event_by_idempotency,
        action: :by_idempotency,
        args: [:case_id, :idempotency_key]

      define :case_target_history,
        action: :target_history,
        args: [:case_id, :resolution_run_id]

      define :create_case_event_record, action: :create_record
    end

    resource Opsonde.Cases.Turn do
      define :list_turns, action: :read
      define :page_case_turns, action: :page_for_case, args: [:case_id]
      define :get_turn, action: :read, get_by: [:id]

      define :turn_by_idempotency,
        action: :by_idempotency,
        args: [:resolution_run_id, :idempotency_key]

      define :started_turns_for_run,
        action: :started_for_run,
        args: [:resolution_run_id]

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
      define :page_case_evidence, action: :page_for_case, args: [:case_id]
      define :get_evidence, action: :read, get_by: [:id]

      define :resolver_evidence_window,
        action: :projection_window,
        args: [:case_id, :resolution_run_id]

      define :source_context_evidence,
        action: :source_context,
        args: [:case_id, :source_ref]

      define :target_continuity_evidence,
        action: :target_continuity,
        args: [:case_id]

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

    resource Opsonde.Cases.Proposal do
      define :list_proposals, action: :read
      define :get_proposal, action: :read, get_by: [:id]
      define :proposals_for_case, action: :for_case, args: [:case_id]

      define :proposal_by_source_turn,
        action: :by_source_turn,
        args: [:source_turn_id]

      define :create_proposal_record, action: :create_record
      define :transition_proposal, action: :transition, args: [:expected_revision]
      define :materialize_proposal, action: :materialize, args: [:turn_id]
      define :route_proposal_authority, action: :route_authority, args: [:proposal_id]

      define :apply_proposal_review,
        action: :apply_review,
        args: [:proposal_id, :review_decision_id]

      define :fail_proposal_review_delivery,
        action: :fail_review_delivery,
        args: [:proposal_id, :category, :reason]

      define :decide_proposal,
        action: :decide,
        args: [:proposal_id, :expected_revision, :proposal_digest, :decision, :reason]
    end

    resource Opsonde.Cases.Approval do
      define :list_approvals, action: :read
      define :page_case_approvals, action: :page_for_case, args: [:case_id]
      define :approval_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_approval_record, action: :create_record
    end

    resource Opsonde.Cases.ReviewDecision do
      define :list_review_decisions, action: :read
      define :page_case_review_decisions, action: :page_for_case, args: [:case_id]
      define :review_decision_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_review_decision_record, action: :create_record
    end

    resource Opsonde.Cases.Operation do
      define :list_operations, action: :read
      define :get_operation, action: :read, get_by: [:id]
      define :operations_for_case, action: :for_case, args: [:case_id]
      define :operation_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_operation_record, action: :create_record
      define :mark_operation_dispatching, action: :mark_dispatching, args: [:expected_revision]
      define :record_operation_outcome, action: :record_outcome, args: [:expected_revision]
      define :record_operation_no_send, action: :record_no_send, args: [:expected_revision]
      define :accept_operation, action: :accept, args: [:proposal_id]
      define :claim_operation_dispatch, action: :claim_dispatch, args: [:id]
    end

    resource Opsonde.Cases.VerificationAttempt do
      define :list_verification_attempts, action: :read
      define :get_verification_attempt, action: :read, get_by: [:id]
      define :verification_attempts_for_case, action: :for_case, args: [:case_id]

      define :verification_attempt_by_operation,
        action: :by_operation,
        args: [:operation_id]

      define :create_verification_attempt_record, action: :create_record

      define :mark_verification_dispatching,
        action: :mark_dispatching,
        args: [:expected_revision]

      define :record_verification_outcome, action: :record_outcome, args: [:expected_revision]
      define :record_verification_no_send, action: :record_no_send, args: [:expected_revision]
      define :accept_verification, action: :accept, args: [:operation_id]
      define :claim_verification_dispatch, action: :claim_dispatch, args: [:id]
      define :evaluate_verification, action: :evaluate, args: [:id]
    end

    resource Opsonde.Cases.AIInvocation do
      define :list_ai_invocations, action: :read

      define :ai_invocation_by_idempotency,
        action: :by_idempotency,
        args: [:idempotency_key]

      define :create_ai_invocation_record, action: :create_record

      define :record_ai_invocation_outcome,
        action: :record_outcome,
        args: [:expected_revision]

      define :claim_ai_invocation,
        action: :claim,
        args: [
          :role,
          :case_id,
          :expected_case_revision,
          :resolution_run_id,
          :turn_id,
          :expected_turn_revision,
          :proposal_id,
          :expected_proposal_revision,
          :provider_id,
          :assignment_id,
          :provider_revision,
          :assignment_revision,
          :selection_source,
          :request_digest
        ]
    end
  end
end
