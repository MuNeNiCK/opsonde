defmodule Opsonde.DownstreamDecisionRouteTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases}
  alias Opsonde.Cases.Budget

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("downstream-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("downstream-operator@example.com", @password, :operator, actor: admin)

    %{admin: admin, operator: operator}
  end

  test "Proposal keeps one exact source Turn for the authority owner", context do
    {incident, run} = open_case!("proposal", context.operator)
    evidence = evidence!(incident, run, "proposal")
    intent = proposal_intent(evidence.id)
    turn = completed_turn!(incident, run, "proposal", intent, :proposal)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert routed.status == :running

    assert routed.pending_intent == %{
             "action" => "authorize_proposal",
             "source_turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert Cases.get_turn!(turn.id, authorize?: false).result["intent"] == intent

    key = Budget.key("resolver-route:downstream", turn.id)
    event = Cases.case_event_by_idempotency!(incident.id, key, authorize?: false)
    assert event.event_type == "resolver_decision_routed"
    assert event.data["source_turn_id"] == turn.id
    assert event.data["result_digest"] == turn.result_digest
    assert event.data["intent_type"] == "proposal"

    assert {:ok, replayed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert replayed.id == routed.id

    assert Enum.count(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "resolver_decision_routed")
           ) == 1
  end

  test "recovery conclusion remains pending and cannot resolve the Case", context do
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      true,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "enable Signal resolution for recovery routing",
      actor: context.admin
    )

    {incident, run} = open_case!("recovery", context.operator, :firing, :signal)

    recovered =
      Cases.record_case_source_recovery!(incident.id, incident.revision, actor: context.operator)

    evidence = evidence!(recovered, run, "recovery")

    intent = %{
      "type" => "recovery_conclusion",
      "reason" => "The fresh observation and monitoring source both recovered",
      "evidence_ids" => [evidence.id]
    }

    turn = completed_turn!(recovered, run, "recovery", intent, :source_change)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert routed.status == :running

    assert routed.pending_intent == %{
             "action" => "evaluate_recovery",
             "source_turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running
  end

  test "handoff pauses the Case once with exact requested human input", context do
    {incident, run} = open_case!("handoff", context.operator)

    intent = %{
      "type" => "handoff",
      "reason" => "The registered methods cannot observe the failed storage path",
      "required_input" => "Attach a storage management Access Method"
    }

    turn = completed_turn!(incident, run, "handoff", intent, :human_input)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert routed.status == :needs_attention
    assert routed.stop_reason == intent["reason"]
    assert routed.required_human_input == intent["required_input"]

    assert routed.pending_intent == %{
             "action" => "provide_human_input",
             "source_turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    assert {:ok, replayed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert replayed.id == routed.id

    assert Enum.count(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_needs_attention")
           ) == 1
  end

  test "malformed decisions and another pending owner fail without overwrite", context do
    {malformed_case, malformed_run} = open_case!("malformed", context.operator)
    evidence = evidence!(malformed_case, malformed_run, "malformed")

    malformed =
      evidence.id
      |> proposal_intent()
      |> Map.delete("verification_tool")

    malformed_turn =
      completed_turn!(malformed_case, malformed_run, "malformed", malformed, :proposal)

    assert {:error, _error} =
             Cases.route_downstream_decision(malformed_turn.id, authorize?: false)

    assert Cases.get_case!(malformed_case.id, authorize?: false).pending_intent == %{}

    {conflict_case, conflict_run} = open_case!("conflict", context.operator)
    conflict_evidence = evidence!(conflict_case, conflict_run, "conflict")

    conflict_turn =
      completed_turn!(
        conflict_case,
        conflict_run,
        "conflict",
        proposal_intent(conflict_evidence.id),
        :proposal
      )

    existing = %{"action" => "another_owner", "reference" => "keep-me"}

    Cases.update_case_record!(
      conflict_case,
      conflict_case.revision,
      %{pending_intent: existing},
      authorize?: false
    )

    assert {:error, _error} =
             Cases.route_downstream_decision(conflict_turn.id, authorize?: false)

    assert Cases.get_case!(conflict_case.id, authorize?: false).pending_intent == existing
  end

  defp open_case!(source_ref, actor, alert_state \\ :not_applicable, trigger_kind \\ :manual) do
    incident =
      Cases.open_case!(
        trigger_kind,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        alert_state,
        %{},
        nil,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "downstream-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"status" => "observed", "service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp completed_turn!(incident, run, suffix, intent, progress_kind) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "downstream-turn-#{suffix}",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    Cases.complete_turn!(
      started.value.id,
      started.value.revision,
      %{
        "outcome" => "decision",
        "intent" => intent,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      progress_kind,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp proposal_intent(evidence_id) do
    verification_tool_id = "observation-tool"
    target_id = Ash.UUID.generate()
    access_method_id = Ash.UUID.generate()
    provider_id = Ash.UUID.generate()
    verification_target_id = Ash.UUID.generate()
    verification_method_id = Ash.UUID.generate()
    verification_provider_id = Ash.UUID.generate()

    %{
      "type" => "proposal",
      "tool_id" => "effect-tool",
      "target_id" => target_id,
      "target_revision" => 3,
      "access_method_id" => access_method_id,
      "access_method_revision" => 2,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the failed API service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "id" => "effect-tool",
        "target_id" => target_id,
        "target_revision" => 3,
        "access_method_id" => access_method_id,
        "access_method_revision" => 2,
        "provider_id" => provider_id,
        "provider_revision" => 6,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
      "verification_intent" => %{
        "tool_id" => verification_tool_id,
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => verification_tool_id,
        "target_id" => verification_target_id,
        "target_revision" => 4,
        "access_method_id" => verification_method_id,
        "access_method_revision" => 5,
        "provider_id" => verification_provider_id,
        "provider_revision" => 7,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end
end
