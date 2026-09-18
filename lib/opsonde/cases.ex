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
      define :active_unresolved_signal_cases, action: :active_unresolved_signals
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

      define :route_observation,
        action: :route_observation,
        args: [:turn_id, :invocation]

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

      define :case_target_history,
        action: :target_history,
        args: [:case_id, :resolution_run_id]

      define :create_case_event_record, action: :create_record
    end

    resource Opsonde.Cases.Turn do
      define :list_turns, action: :read
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
      define :get_evidence, action: :read, get_by: [:id]

      define :resolver_evidence_window,
        action: :projection_window,
        args: [:case_id, :resolution_run_id]

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

      define :decide_proposal,
        action: :decide,
        args: [:proposal_id, :expected_revision, :proposal_digest, :decision, :reason]
    end

    resource Opsonde.Cases.Approval do
      define :list_approvals, action: :read
      define :approval_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_approval_record, action: :create_record
    end

    resource Opsonde.Cases.ReviewDecision do
      define :list_review_decisions, action: :read
      define :review_decision_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_review_decision_record, action: :create_record
    end

    resource Opsonde.Cases.Operation do
      define :list_operations, action: :read
      define :get_operation, action: :read, get_by: [:id]
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

    resource Opsonde.Cases.SignalReceipt do
      define :list_signal_receipts, action: :read

      define :signal_receipt_by_source_identity,
        action: :by_source_identity,
        args: [:provider_id, :receipt_id]

      define :create_signal_receipt_record, action: :create_record

      define :ingest_signal,
        action: :ingest,
        args: [:provider_id, :provider_revision, :envelope, :invocation]
    end

    resource Opsonde.Cases.SignalEvent do
      define :list_signal_events, action: :read

      define :signal_event_by_receipt,
        action: :by_receipt_event,
        args: [:signal_receipt_id, :event_key]

      define :create_signal_event_record, action: :create_record
    end

    resource Opsonde.Cases.SignalCorrelation do
      define :list_signal_correlations, action: :read

      define :signal_correlation_by_source,
        action: :by_source_identity,
        args: [:provider_id, :source, :event_key]

      define :create_signal_correlation_record, action: :create_record
      define :update_signal_correlation_record, action: :update_record, args: [:expected_revision]
    end
  end
end
