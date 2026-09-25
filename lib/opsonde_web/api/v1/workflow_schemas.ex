defmodule OpsondeWeb.API.V1.WorkflowSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias OpsondeWeb.API.Schemas

  def components do
    %{
      "AuthoritySetting" => authority_setting(),
      "AuthoritySettingResponse" => Schemas.data(ref("AuthoritySetting")),
      "AuthoritySettingPage" => Schemas.page(ref("AuthoritySetting")),
      "UpdateAuthoritySettingRequest" => update_authority_request(),
      "Case" => case_record(),
      "CaseResponse" => Schemas.data(ref("Case")),
      "CasePage" => Schemas.page(ref("Case")),
      "CreateCaseRequest" => create_case_request(),
      "CaseRevisionRequest" => case_revision_request(),
      "HandoffCaseRequest" => handoff_request(),
      "ResumeCaseRequest" => resume_request(),
      "CaseSnapshot" => snapshot(),
      "CaseSnapshotResponse" => Schemas.data(ref("CaseSnapshot")),
      "ResolutionRun" => resolution_run(),
      "ResolutionRunResponse" => Schemas.data(ref("ResolutionRun")),
      "CaseEvent" => event(),
      "CaseEventPage" => Schemas.page(ref("CaseEvent")),
      "ResolverTurn" => turn(),
      "ResolverTurnPage" => Schemas.page(ref("ResolverTurn")),
      "Evidence" => evidence(),
      "EvidencePage" => Schemas.page(ref("Evidence")),
      "Approval" => approval(),
      "ApprovalPage" => Schemas.page(ref("Approval")),
      "ReviewDecision" => review_decision(),
      "ReviewDecisionPage" => Schemas.page(ref("ReviewDecision")),
      "Proposal" => proposal(),
      "ProposalResponse" => Schemas.data(ref("Proposal")),
      "DecideProposalRequest" => decide_proposal_request(),
      "Operation" => operation(),
      "OperationResponse" => Schemas.data(ref("Operation")),
      "VerificationAttempt" => verification_attempt(),
      "VerificationAttemptResponse" => Schemas.data(ref("VerificationAttempt")),
      "WorkflowLimits" => limits(),
      "ResolutionCounters" => counters()
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp authority_setting do
    object(
      %{
        id: Schemas.uuid(),
        authority_mode: authority_mode(),
        signal_automation_enabled: %Schema{type: :boolean},
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        setting_revision: positive_integer(),
        active: %Schema{type: :boolean},
        reason: string(1, 500),
        changed_by_id: nullable_uuid(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id authority_mode signal_automation_enabled max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns setting_revision active reason changed_by_id inserted_at updated_at)a,
      false
    )
  end

  defp update_authority_request do
    wrapped(
      :authority_setting,
      %{
        expected_setting_revision: positive_integer(),
        authority_mode: authority_mode(),
        signal_automation_enabled: %Schema{type: :boolean},
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        reason: string(1, 500)
      },
      ~w(expected_setting_revision authority_mode signal_automation_enabled max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns reason)a
    )
  end

  defp case_record do
    object(
      %{
        id: Schemas.uuid(),
        trigger_kind: enum(~w(manual signal audit)),
        source: string(1, 120),
        source_ref: string(1, 500),
        title: string(1, 200),
        severity: enum(~w(info warning error critical)),
        alert_state: enum(~w(firing recovered not_applicable)),
        report_language: enum(~w(en ja)),
        status: enum(~w(running needs_attention resolved cancelled)),
        operator_action: enum(~w(none decision_required input_required intervention_required)),
        initial_context: map(),
        authority_setting_id: Schemas.uuid(),
        authority_setting_revision: positive_integer(),
        authority_mode: authority_mode(),
        limits: ref("WorkflowLimits"),
        cancel_requested: %Schema{type: :boolean},
        stop_reason: nullable_string(500),
        required_human_input: nullable_string(1_000),
        source_recovered_at: nullable_timestamp(),
        initial_target_id: nullable_uuid(),
        selected_target_id: nullable_uuid(),
        selected_target_revision: nullable_positive_integer(),
        current_owner_id: nullable_uuid(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id trigger_kind source source_ref title severity alert_state report_language status operator_action initial_context authority_setting_id authority_setting_revision authority_mode limits cancel_requested stop_reason required_human_input source_recovered_at initial_target_id selected_target_id selected_target_revision current_owner_id revision inserted_at updated_at)a,
      false
    )
  end

  defp create_case_request do
    wrapped(
      :case,
      %{
        trigger_kind: enum(~w(manual signal audit)),
        source: string(1, 120),
        source_ref: string(1, 500),
        title: string(1, 200),
        severity: enum(~w(info warning error critical)),
        alert_state: enum(~w(firing not_applicable)),
        initial_context: map(),
        initial_target_id: nullable_uuid()
      },
      ~w(trigger_kind source source_ref title severity)a
    )
  end

  defp case_revision_request do
    wrapped(:case, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp handoff_request do
    wrapped(
      :case,
      %{expected_revision: positive_integer(), owner_id: Schemas.uuid()},
      [:expected_revision, :owner_id]
    )
  end

  defp resume_request do
    wrapped(
      :case,
      %{
        expected_case_revision: positive_integer(),
        resolution_run_id: Schemas.uuid(),
        expected_run_revision: positive_integer(),
        authority_mode: authority_mode(),
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        reason: string(1, 500)
      },
      ~w(expected_case_revision resolution_run_id expected_run_revision authority_mode max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns reason)a
    )
  end

  defp snapshot do
    object(
      %{
        case: ref("Case"),
        resolution_runs: array(ref("ResolutionRun")),
        proposals: array(ref("Proposal")),
        operations: array(ref("Operation")),
        verification_attempts: array(ref("VerificationAttempt")),
        reports: array(ref("Report"))
      },
      [:case, :resolution_runs, :proposals, :operations, :verification_attempts, :reports],
      false
    )
  end

  defp resolution_run do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        generation: positive_integer(),
        active: %Schema{type: :boolean},
        status: enum(~w(running needs_attention completed cancelled superseded)),
        authority_mode: authority_mode(),
        limits: ref("WorkflowLimits"),
        counters: ref("ResolutionCounters"),
        started_at: Schemas.timestamp(),
        deadline_at: Schemas.timestamp(),
        ended_at: nullable_timestamp(),
        resume_reason: nullable_string(500),
        resumed_by_id: nullable_uuid(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id generation active status authority_mode limits counters started_at deadline_at ended_at resume_reason resumed_by_id revision inserted_at updated_at)a,
      false
    )
  end

  defp event do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: nullable_uuid(),
        actor_id: nullable_uuid(),
        type: string(1, 80),
        inserted_at: Schemas.timestamp()
      },
      [:id, :case_id, :resolution_run_id, :actor_id, :type, :inserted_at],
      false
    )
  end

  defp turn do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        ordinal: positive_integer(),
        status: enum(~w(started completed)),
        intent: map(),
        outcome: nullable_string(),
        decision: nullable_map(),
        failure_category: nullable_string(),
        failure_message: nullable_string(),
        progress_kind:
          nullable_enum(~w(evidence hypothesis proposal source_change human_input none)),
        started_at: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id ordinal status intent outcome decision failure_category failure_message progress_kind started_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp evidence do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        turn_id: nullable_uuid(),
        kind: string(1, 80),
        source: string(1, 120),
        source_ref: string(1, 500),
        content: map(),
        observed_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id turn_id kind source source_ref content observed_at inserted_at updated_at)a,
      false
    )
  end

  defp approval do
    object(
      %{
        id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        decision: enum(~w(approved rejected)),
        source: enum(~w(human readonly full_access reviewer)),
        proposal_revision: positive_integer(),
        case_generation: positive_integer(),
        reason: string(1, 1_000),
        decided_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp()
      },
      ~w(id proposal_id case_id resolution_run_id actor_id decision source proposal_revision case_generation reason decided_at inserted_at)a,
      false
    )
  end

  defp review_decision do
    object(
      %{
        id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        provider_id: nullable_uuid(),
        outcome: enum(~w(decision delivery_failed)),
        verdict: enum(~w(approved rejected needs_human)),
        category: nullable_string(80),
        reason: string(1, 1_000),
        selection_source: nullable_enum(~w(assignment)),
        provider_revision: nullable_positive_integer(),
        input_tokens: non_negative_integer(),
        output_tokens: non_negative_integer(),
        decided_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp()
      },
      ~w(id proposal_id case_id resolution_run_id provider_id outcome verdict category reason selection_source provider_revision input_tokens output_tokens decided_at inserted_at)a,
      false
    )
  end

  defp proposal do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        source_turn_id: Schemas.uuid(),
        proposed_for_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status:
          enum(
            ~w(proposed blocked recommended awaiting_human reviewing authorized rejected invalidated)
          ),
        authority_mode: authority_mode(),
        case_generation: positive_integer(),
        target_revision: positive_integer(),
        access_method_revision: positive_integer(),
        provider_revision: positive_integer(),
        request_kind: enum(~w(observation effect)),
        tool_id: string(1, 200),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        reason: string(1, 500),
        evidence_ids: array(Schemas.uuid(), 0, 100),
        expected_result: map(),
        verification_intent: map(),
        verification_tool: map(),
        preflight_status: enum(~w(cleared blocked)),
        preflight_reason: nullable_string(500),
        proposal_digest: digest(),
        expires_at: Schemas.timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id source_turn_id proposed_for_id target_id access_method_id provider_id status authority_mode case_generation target_revision access_method_revision provider_revision request_kind tool_id capability operation selectors parameters reason evidence_ids expected_result verification_intent verification_tool preflight_status preflight_reason proposal_digest expires_at revision inserted_at updated_at)a,
      false
    )
  end

  defp decide_proposal_request do
    wrapped(
      :proposal,
      %{
        expected_revision: positive_integer(),
        proposal_digest: digest(),
        decision: enum(~w(approved rejected)),
        reason: string(1, 1_000)
      },
      [:expected_revision, :proposal_digest, :decision, :reason]
    )
  end

  defp operation do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        approval_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status: enum(~w(queued dispatching applied failed partial unknown)),
        case_generation: positive_integer(),
        authority_mode: authority_mode(),
        request_kind: enum(~w(observation effect)),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        dispatch_started_at: nullable_timestamp(),
        outcome_category: nullable_string(120),
        reference: nullable_string(500),
        result_details: map(),
        accepted_at: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id proposal_id approval_id actor_id target_id access_method_id provider_id status case_generation authority_mode request_kind capability operation selectors parameters dispatch_started_at outcome_category reference result_details accepted_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp verification_attempt do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        operation_id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status: enum(~w(queued dispatching verified not_verified unknown)),
        case_generation: positive_integer(),
        authority_mode: enum(~w(ask auto full_access)),
        tool_id: string(1, 500),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        expected: map(),
        operation_reference: nullable_string(500),
        dispatch_started_at: nullable_timestamp(),
        outcome_category: nullable_string(120),
        facts: map(),
        provider_evidence: map(),
        observed_at: nullable_timestamp(),
        accepted_at: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id operation_id proposal_id actor_id target_id access_method_id provider_id status case_generation authority_mode tool_id capability operation selectors parameters expected operation_reference dispatch_started_at outcome_category facts provider_evidence observed_at accepted_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp limits do
    object(
      %{
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100)
      },
      ~w(max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns)a,
      false
    )
  end

  defp counters do
    object(
      %{
        resolver_turns: non_negative_integer(),
        target_requests: non_negative_integer(),
        effects: non_negative_integer(),
        related_targets: non_negative_integer(),
        ai_usage_units: non_negative_integer(),
        no_progress_turns: non_negative_integer()
      },
      ~w(resolver_turns target_requests effects related_targets ai_usage_units no_progress_turns)a,
      false
    )
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp authority_mode, do: enum(~w(readonly ask auto full_access))
  defp digest, do: %Schema{type: :string, minLength: 64, maxLength: 64}
  defp enum(values), do: %Schema{type: :string, enum: values}
  defp nullable_enum(values), do: %Schema{type: :string, enum: values, nullable: true}

  defp string(min_length, max_length),
    do: %Schema{type: :string, minLength: min_length, maxLength: max_length}

  defp nullable_string(max_length \\ nil),
    do: %Schema{type: :string, maxLength: max_length, nullable: true}

  defp integer(minimum, maximum), do: %Schema{type: :integer, minimum: minimum, maximum: maximum}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp nullable_positive_integer, do: %Schema{type: :integer, minimum: 1, nullable: true}
  defp non_negative_integer, do: %Schema{type: :integer, minimum: 0}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_map, do: %Schema{type: :object, additionalProperties: true, nullable: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}
  defp array(items), do: %Schema{type: :array, items: items}

  defp array(items, min_items, max_items),
    do: %Schema{type: :array, items: items, minItems: min_items, maxItems: max_items}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
