defmodule OpsondeWeb.API.V1.OutcomeSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias OpsondeWeb.API.Schemas

  def components do
    %{
      "SignalWebhookPayload" => map(),
      "SignalWebhookAccepted" => webhook_accepted(),
      "SignalWebhookError" => webhook_error(),
      "SignalWebhookValidationError" => webhook_validation_error(),
      "SignalReceipt" => signal_receipt(),
      "SignalReceiptResponse" => Schemas.data(ref("SignalReceipt")),
      "SignalReceiptPage" => Schemas.page(ref("SignalReceipt")),
      "SignalEvent" => signal_event(),
      "SignalEventPage" => Schemas.page(ref("SignalEvent")),
      "AuditSchedule" => audit_schedule(),
      "AuditScheduleResponse" => Schemas.data(ref("AuditSchedule")),
      "AuditSchedulePage" => Schemas.page(ref("AuditSchedule")),
      "CreateAuditScheduleRequest" => create_audit_schedule_request(),
      "DeactivateAuditScheduleRequest" => deactivate_audit_schedule_request(),
      "AuditRun" => audit_run(),
      "AuditRunResponse" => Schemas.data(ref("AuditRun")),
      "AuditRunPage" => Schemas.page(ref("AuditRun")),
      "Report" => report(),
      "ReportResponse" => Schemas.data(ref("Report")),
      "ReportPage" => Schemas.page(ref("Report")),
      "GenerateReportRequest" => generate_report_request(),
      "Delivery" => delivery(),
      "DeliveryResponse" => Schemas.data(ref("Delivery")),
      "DeliveryPage" => Schemas.page(ref("Delivery")),
      "CreateDeliveryRequest" => create_delivery_request()
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp webhook_accepted do
    object(%{receipt_id: string(1, 500)}, [:receipt_id], false)
  end

  defp webhook_error do
    object(
      %{errors: object(%{detail: %Schema{type: :string}}, [:detail], false)},
      [:errors],
      false
    )
  end

  defp webhook_validation_error do
    %Schema{oneOf: [ref("SignalWebhookError"), Schemas.reference("ErrorResponse")]}
  end

  defp signal_receipt do
    object(
      %{
        id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        receipt_id: string(1, 500),
        source: string(1, 120),
        received_at: Schemas.timestamp(),
        event_count: %Schema{type: :integer, minimum: 1, maximum: 1_000},
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id provider_id provider_revision receipt_id source received_at event_count inserted_at updated_at)a,
      false
    )
  end

  defp signal_event do
    object(
      %{
        id: Schemas.uuid(),
        signal_receipt_id: Schemas.uuid(),
        event_key: string(1, 500),
        incident_key: nullable_string(500),
        state: enum(~w(firing recovered)),
        source_sequence: nullable_string(500),
        occurred_at: Schemas.timestamp(),
        target_ref: nullable_map(),
        case_id: nullable_uuid(),
        target_id: nullable_uuid(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id signal_receipt_id event_key incident_key state source_sequence occurred_at target_ref case_id target_id inserted_at updated_at)a,
      false
    )
  end

  defp audit_schedule do
    object(
      %{
        id: Schemas.uuid(),
        name: string(1, 120),
        objective: string(1, 2_000),
        timezone: string(1, 120),
        cron_expression: string(1, 120),
        report_language: enum(~w(en ja)),
        target_ids: %Schema{type: :array, items: Schemas.uuid()},
        management_boundary_id: nullable_uuid(),
        active: %Schema{type: :boolean},
        next_run_at: Schemas.timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id name objective timezone cron_expression report_language target_ids management_boundary_id active next_run_at revision inserted_at updated_at)a,
      false
    )
  end

  defp create_audit_schedule_request do
    wrapped(
      :audit_schedule,
      %{
        name: string(1, 120),
        objective: string(1, 2_000),
        timezone: string(1, 120),
        cron_expression: string(1, 120),
        report_language: enum(~w(en ja)),
        target_ids: %Schema{type: :array, items: Schemas.uuid()},
        management_boundary_id: nullable_uuid()
      },
      ~w(name objective timezone cron_expression report_language)a
    )
  end

  defp deactivate_audit_schedule_request do
    wrapped(:audit_schedule, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp audit_run do
    object(
      %{
        id: Schemas.uuid(),
        audit_schedule_id: Schemas.uuid(),
        schedule_revision: positive_integer(),
        target_key: string(1, 160),
        target_id: nullable_uuid(),
        target_revision: nullable_positive_integer(),
        case_id: nullable_uuid(),
        case_revision: nullable_positive_integer(),
        scheduled_for: Schemas.timestamp(),
        status: enum(~w(queued running case_opened skipped cancelled failed)),
        reason: nullable_string(1_000),
        started_at: nullable_timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id audit_schedule_id schedule_revision target_key target_id target_revision case_id case_revision scheduled_for status reason started_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp report do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        case_revision: positive_integer(),
        language: enum(~w(en ja)),
        outcome: enum(~w(resolved needs_attention cancelled)),
        content: map(),
        content_digest: digest(),
        generated_at: Schemas.timestamp(),
        revision: positive_integer()
      },
      ~w(id case_id case_revision language outcome content content_digest generated_at revision)a,
      false
    )
  end

  defp generate_report_request do
    wrapped(:report, %{expected_case_revision: positive_integer()}, [:expected_case_revision])
  end

  defp delivery do
    object(
      %{
        id: Schemas.uuid(),
        report_id: Schemas.uuid(),
        report_revision: positive_integer(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        destination_id: Schemas.uuid(),
        destination_revision: positive_integer(),
        status: enum(~w(queued dispatching accepted delivered failed unknown)),
        reference: nullable_string(1_024),
        details: map(),
        enqueued_at: Schemas.timestamp(),
        dispatch_started_at: nullable_timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer()
      },
      ~w(id report_id report_revision provider_id provider_revision destination_id destination_revision status reference details enqueued_at dispatch_started_at completed_at revision)a,
      false
    )
  end

  defp create_delivery_request do
    wrapped(
      :delivery,
      %{
        report_id: Schemas.uuid(),
        report_revision: positive_integer(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        idempotency_key: string(1, 1_024)
      },
      [:report_id, :report_revision, :provider_id, :provider_revision, :idempotency_key]
    )
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp digest, do: %Schema{type: :string, minLength: 64, maxLength: 64}
  defp enum(values), do: %Schema{type: :string, enum: values}

  defp string(min_length, max_length),
    do: %Schema{type: :string, minLength: min_length, maxLength: max_length}

  defp nullable_string(max_length),
    do: %Schema{type: :string, maxLength: max_length, nullable: true}

  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp nullable_positive_integer, do: %Schema{type: :integer, minimum: 1, nullable: true}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_map, do: %Schema{type: :object, additionalProperties: true, nullable: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
