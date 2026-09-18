defmodule OpsondeWeb.API.V1.WorkflowJSON do
  @moduledoc false

  def authority(setting) do
    %{
      id: setting.id,
      authority_mode: setting.authority_mode,
      signal_automation_enabled: setting.signal_automation_enabled,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      setting_revision: setting.setting_revision,
      active: setting.active,
      reason: setting.reason,
      changed_by_id: setting.changed_by_id,
      inserted_at: setting.inserted_at,
      updated_at: setting.updated_at
    }
  end

  def case_record(incident) do
    %{
      id: incident.id,
      trigger_kind: incident.trigger_kind,
      source: incident.source,
      source_ref: incident.source_ref,
      title: incident.title,
      severity: incident.severity,
      alert_state: incident.alert_state,
      report_language: incident.report_language,
      status: incident.status,
      initial_context: incident.initial_context,
      authority_setting_id: incident.authority_setting_id,
      authority_setting_revision: incident.authority_setting_revision,
      authority_mode: incident.authority_mode,
      limits: limits(incident),
      cancel_requested: incident.cancel_requested,
      stop_reason: incident.stop_reason,
      required_human_input: incident.required_human_input,
      source_recovered_at: incident.source_recovered_at,
      initial_target_id: incident.initial_target_id,
      selected_target_id: incident.selected_target_id,
      selected_target_revision: incident.selected_target_revision,
      current_owner_id: incident.current_owner_id,
      revision: incident.revision,
      inserted_at: incident.inserted_at,
      updated_at: incident.updated_at
    }
  end

  def snapshot(snapshot) do
    %{
      case: case_record(snapshot.case),
      resolution_runs: Enum.map(snapshot.resolution_runs, &resolution_run/1),
      proposals: Enum.map(snapshot.proposals, &proposal/1),
      operations: Enum.map(snapshot.operations, &operation/1),
      verification_attempts: Enum.map(snapshot.verification_attempts, &verification_attempt/1)
    }
  end

  def resolution_run(run) do
    %{
      id: run.id,
      case_id: run.case_id,
      generation: run.generation,
      active: run.active,
      status: run.status,
      authority_mode: run.authority_mode,
      limits: limits(run),
      counters: %{
        resolver_turns: run.turn_count,
        target_requests: run.target_request_count,
        effects: run.effect_count,
        related_targets: run.related_target_count,
        ai_usage_units: run.ai_usage_units,
        no_progress_turns: run.no_progress_turns
      },
      started_at: run.started_at,
      deadline_at: run.deadline_at,
      ended_at: run.ended_at,
      resume_reason: run.resume_reason,
      resumed_by_id: run.resumed_by_id,
      revision: run.revision,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def event(event) do
    %{
      id: event.id,
      case_id: event.case_id,
      resolution_run_id: event.resolution_run_id,
      actor_id: event.actor_id,
      type: event.event_type,
      inserted_at: event.inserted_at
    }
  end

  def proposal(proposal) do
    %{
      id: proposal.id,
      case_id: proposal.case_id,
      resolution_run_id: proposal.resolution_run_id,
      source_turn_id: proposal.source_turn_id,
      proposed_for_id: proposal.proposed_for_id,
      target_id: proposal.target_id,
      access_method_id: proposal.access_method_id,
      provider_id: proposal.provider_id,
      status: proposal.status,
      authority_mode: proposal.authority_mode,
      case_generation: proposal.case_generation,
      target_revision: proposal.target_revision,
      access_method_revision: proposal.access_method_revision,
      provider_revision: proposal.provider_revision,
      tool_id: proposal.tool_id,
      capability: proposal.capability,
      operation: proposal.operation,
      selectors: proposal.selectors,
      parameters: proposal.parameters,
      reason: proposal.reason,
      evidence_ids: proposal.evidence_ids,
      expected_result: proposal.expected_result,
      verification_intent: proposal.verification_intent,
      verification_tool: proposal.verification_tool,
      preflight_status: proposal.preflight_status,
      preflight_reason: proposal.preflight_reason,
      proposal_digest: proposal.proposal_digest,
      expires_at: proposal.expires_at,
      revision: proposal.revision,
      inserted_at: proposal.inserted_at,
      updated_at: proposal.updated_at
    }
  end

  def operation(operation) do
    %{
      id: operation.id,
      case_id: operation.case_id,
      resolution_run_id: operation.resolution_run_id,
      proposal_id: operation.proposal_id,
      approval_id: operation.approval_id,
      actor_id: operation.actor_id,
      target_id: operation.target_id,
      access_method_id: operation.access_method_id,
      provider_id: operation.provider_id,
      status: operation.status,
      case_generation: operation.case_generation,
      authority_mode: operation.authority_mode,
      capability: operation.capability,
      operation: operation.operation,
      selectors: operation.selectors,
      parameters: operation.parameters,
      dispatch_started_at: operation.dispatch_started_at,
      outcome_category: operation.outcome_category,
      reference: operation.reference,
      result_details: operation.result_details,
      accepted_at: operation.accepted_at,
      completed_at: operation.completed_at,
      revision: operation.revision,
      inserted_at: operation.inserted_at,
      updated_at: operation.updated_at
    }
  end

  def verification_attempt(attempt) do
    %{
      id: attempt.id,
      case_id: attempt.case_id,
      resolution_run_id: attempt.resolution_run_id,
      operation_id: attempt.operation_id,
      proposal_id: attempt.proposal_id,
      actor_id: attempt.actor_id,
      target_id: attempt.target_id,
      access_method_id: attempt.access_method_id,
      provider_id: attempt.provider_id,
      status: attempt.status,
      case_generation: attempt.case_generation,
      authority_mode: attempt.authority_mode,
      tool_id: attempt.tool_id,
      capability: attempt.capability,
      operation: attempt.operation,
      selectors: attempt.selectors,
      parameters: attempt.parameters,
      expected: attempt.expected,
      operation_reference: attempt.operation_reference,
      dispatch_started_at: attempt.dispatch_started_at,
      outcome_category: attempt.outcome_category,
      facts: attempt.facts,
      provider_evidence: attempt.provider_evidence,
      observed_at: attempt.observed_at,
      accepted_at: attempt.accepted_at,
      completed_at: attempt.completed_at,
      revision: attempt.revision,
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at
    }
  end

  defp limits(value) do
    %{
      max_elapsed_seconds: value.max_elapsed_seconds,
      max_resolver_turns: value.max_resolver_turns,
      max_target_requests: value.max_target_requests,
      max_effects: value.max_effects,
      max_related_targets: value.max_related_targets,
      max_ai_usage_units: value.max_ai_usage_units,
      max_no_progress_turns: value.max_no_progress_turns
    }
  end
end
