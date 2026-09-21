defmodule Opsonde.DownstreamDecisionRouteTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.Budget

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("downstream-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("downstream-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "downstream-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "downstream-target-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("downstream-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "downstream-ssh",
        "linux",
        "ssh",
        "ssh://downstream-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "Proposal keeps one exact source Turn for the authority owner", context do
    {incident, run} = open_case!("proposal", context.operator)
    evidence = evidence!(incident, run, "proposal")
    intent = proposal_intent(evidence.id, context)
    turn = completed_turn!(incident, run, "proposal", intent, :proposal)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    [proposal] = Cases.list_proposals!(actor: context.admin)

    assert proposal.status == :recommended
    assert routed.status == :needs_attention

    assert routed.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
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

  test "recovery conclusion cannot use ordinary Evidence as fresh verification", context do
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

    [started] = Cases.started_turns_for_run!(run.id, authorize?: false)

    turn =
      Cases.complete_turn!(
        started.id,
        started.revision,
        %{
          "outcome" => "decision",
          "intent" => intent,
          "resolver" => resolver_identity(),
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :source_change,
        %{"action" => "route_resolver_decision", "turn_id" => started.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, _error} = Cases.route_downstream_decision(turn.id, authorize?: false)
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "source_state" => "recovered",
             "turn_id" => turn.id
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
      |> proposal_intent(context)
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
        proposal_intent(conflict_evidence.id, context),
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
        :en,
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
        "resolver" => resolver_identity(),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      progress_kind,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp proposal_intent(evidence_id, context) do
    verification_tool_id = "observation-tool"
    target_id = context.target.id
    access_method_id = context.method.id
    provider_id = context.provider.id

    %{
      "type" => "proposal",
      "request_kind" => "effect",
      "tool_id" => "effect-tool",
      "target_id" => target_id,
      "target_revision" => context.target.revision,
      "access_method_id" => access_method_id,
      "access_method_revision" => context.method.revision,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the failed API service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "request_kind" => "effect",
        "id" => "effect-tool",
        "target_id" => target_id,
        "target_revision" => context.target.revision,
        "access_method_id" => access_method_id,
        "access_method_revision" => context.method.revision,
        "provider_id" => provider_id,
        "provider_revision" => context.provider.revision,
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
        "target_id" => target_id,
        "target_revision" => context.target.revision,
        "access_method_id" => access_method_id,
        "access_method_revision" => context.method.revision,
        "provider_id" => provider_id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp resolver_identity do
    %{
      "provider_id" => Ash.UUID.generate(),
      "provider_revision" => 1,
      "assignment_id" => Ash.UUID.generate(),
      "assignment_revision" => 1
    }
  end
end
