defmodule Opsonde.Signals do
  use Ash.Domain,
    otp_app: :opsonde

  resources do
    resource Opsonde.Signals.SignalReceipt do
      define :list_signal_receipts, action: :read
      define :page_signal_receipts, action: :page
      define :get_signal_receipt, action: :read, get_by: [:id]

      define :signal_receipt_by_source_identity,
        action: :by_source_identity,
        args: [:provider_id, :receipt_id]

      define :create_signal_receipt_record, action: :create_record

      define :ingest_signal,
        action: :ingest,
        args: [:provider_id, :provider_revision, :envelope, :invocation]
    end

    resource Opsonde.Signals.SignalEvent do
      define :list_signal_events, action: :read

      define :page_signal_events_for_receipt,
        action: :page_for_receipt,
        args: [:signal_receipt_id]

      define :signal_event_by_receipt,
        action: :by_receipt_event,
        args: [:signal_receipt_id, :event_key]

      define :create_signal_event_record, action: :create_record
    end

    resource Opsonde.Signals.SignalCorrelation do
      define :list_signal_correlations, action: :read

      define :signal_correlation_by_source,
        action: :by_source_identity,
        args: [:provider_id, :source, :event_key]

      define :signal_correlations_for_case, action: :for_case, args: [:case_id]

      define :create_signal_correlation_record, action: :create_record
      define :update_signal_correlation_record, action: :update_record, args: [:expected_revision]
    end

    resource Opsonde.Signals.Condition do
      define :list_conditions, action: :read
      define :get_condition, action: :read, get_by: [:id]

      define :latest_condition_for_correlation,
        action: :latest_for_correlation,
        args: [:signal_correlation_id]

      define :previous_condition_for_correlation,
        action: :previous_for_correlation,
        args: [:signal_correlation_id, :occurrence]

      define :same_subject_conditions,
        action: :same_subject,
        args: [:subject_key, :predicate]

      define :create_condition_record, action: :create_record
      define :record_condition_state, action: :record_state, args: [:expected_revision]

      define :record_condition_source_event,
        action: :record_source_event,
        args: [
          :signal_correlation_id,
          :state,
          :occurred_at,
          :source_sequence,
          :target_id,
          :subject_ref,
          :subject_key,
          :predicate,
          :current
        ]
    end
  end
end
