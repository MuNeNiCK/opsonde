defmodule Opsonde.OperationDeliveryTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}

  alias Opsonde.Cases.{
    OperationAcceptanceWorker,
    OperationDelivery,
    OperationWorker,
    ResolverDelivery,
    ResolverProjection,
    VerificationDelivery,
    VerificationWorker
  }

  alias Opsonde.Providers.{AI, Target}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("operation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operation-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "operation-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "operation-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("operation-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "operation-ssh",
        "linux",
        "ssh",
        "ssh://operation-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    resolver_provider =
      Providers.create_provider!(
        "operation-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    resolver_assignment =
      Providers.create_ai_usage_role_assignment!(resolver_provider.id, :resolver, 10,
        actor: admin
      )

    configure_mode!(admin, :full_access)

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment
    }
  end

  test "accepting an authorized Proposal is atomic and idempotent", context do
    {_incident, run, proposal} = authorized_proposal!("accept", context)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    duplicate = Cases.accept_operation!(proposal.id, authorize?: false)

    assert duplicate.id == operation.id
    assert operation.id == proposal.reserved_operation_id
    assert operation.status == :queued
    assert operation.proposal_revision == proposal.revision
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1
    assert operation_jobs(operation.id) == 1

    assert %{"operation_id" => operation.id} == operation_job(operation.id).args
    refute_receive {:effect, _, _}
  end

  test "Operation actions enforce only the declared state transitions", context do
    {_incident, _run, proposal} = authorized_proposal!("state-machine", context)
    queued = Cases.accept_operation!(proposal.id, authorize?: false)
    completed_at = DateTime.utc_now()

    assert {:error, error} =
             Cases.record_operation_outcome(
               queued,
               queued.revision,
               %{
                 status: :applied,
                 outcome_category: "target_applied",
                 result_details: %{},
                 completed_at: completed_at
               },
               authorize?: false
             )

    assert Exception.message(error) =~
             "from queued to applied in action record_outcome"

    assert Cases.get_operation!(queued.id, authorize?: false).status == :queued

    claim = Cases.claim_operation_dispatch!(queued.id, authorize?: false)
    dispatching = claim.operation
    assert dispatching.status == :dispatching

    assert {:error, error} =
             Cases.record_operation_no_send(
               dispatching,
               dispatching.revision,
               %{
                 outcome_category: "cancelled_before_dispatch",
                 result_details: %{},
                 completed_at: completed_at
               },
               authorize?: false
             )

    assert Exception.message(error) =~
             "from dispatching to failed in action record_no_send"

    applied =
      Cases.record_operation_outcome!(
        dispatching,
        dispatching.revision,
        %{
          status: :applied,
          outcome_category: "target_applied",
          result_details: %{},
          completed_at: completed_at
        },
        authorize?: false
      )

    assert {:error, error} =
             Cases.mark_operation_dispatching(
               applied,
               applied.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             )

    assert Exception.message(error) =~
             "from applied to dispatching in action mark_dispatching"

    assert Cases.get_operation!(applied.id, authorize?: false).status == :applied
  end

  test "revoked approval authority creates no Operation, job or budget charge", context do
    {incident, run, proposal} = authorized_proposal!("revoked", context)
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}

    assert :ok =
             OperationAcceptanceWorker.perform(%Oban.Job{
               args: %{"proposal_id" => proposal.id}
             })

    attention = Cases.get_case!(incident.id, authorize?: false)
    assert attention.status == :needs_attention
    assert attention.pending_intent["action"] == "dispatch_operation"
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  test "a Target Policy added after approval prevents acceptance", context do
    {_incident, run, proposal} = authorized_proposal!("policy-before-accept", context)

    Targets.create_target_policy!(
      context.target.id,
      "deny-operation-acceptance",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "The API service must not be restarted",
      actor: context.admin
    )

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}
  end

  test "effect exhaustion persists attention without an Operation or job", context do
    configure_mode!(context.admin, :full_access, 0)
    {incident, run, proposal} = authorized_proposal!("exhausted", context)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert operation_jobs(proposal.reserved_operation_id) == 0

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "review_effect_limit"
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "each normalized Target outcome is sent and persisted once", context do
    for status <- [:applied, :failed, :partial, :unknown] do
      {incident, _run, proposal} = authorized_proposal!("outcome-#{status}", context)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      result = %Target.EffectResult{
        status: status,
        reference: "remote-#{status}",
        details: %{"status" => to_string(status)}
      }

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, result})
               )

      assert_receive {:effect, _state, request}
      assert request.operation_id == operation.id
      assert request.idempotency_key == operation.idempotency_key

      stored = Cases.get_operation!(operation.id, authorize?: false)
      assert stored.status == status
      assert stored.reference == "remote-#{status}"
      assert stored.result_details == %{"status" => to_string(status)}

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("terminal Operation was resent") end)
               )

      refute_receive {:effect, _, _}

      assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
               "verify_operation"

      assert operation_evidence(operation.id) == 1
    end
  end

  test "a lost adapter response becomes unknown and is never resent", context do
    {_incident, _run, proposal} = authorized_proposal!("lost-response", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> raise "remote response lost" end)
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("unknown Operation was resent") end)
             )

    refute_receive {:effect, _, _}
  end

  test "authorization changed after acceptance fails before Target dispatch", context do
    {_incident, _run, proposal} = authorized_proposal!("policy-before-dispatch", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Targets.create_target_policy!(
      context.target.id,
      "deny-operation-dispatch",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "The API service must not be restarted",
      actor: context.admin
    )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("invalidated Operation was sent") end)
             )

    invalidated = Cases.get_operation!(operation.id, authorize?: false)
    assert invalidated.status == :failed
    assert invalidated.outcome_category == "authorization_invalidated"
    refute_receive {:effect, _, _}
  end

  test "restart after the dispatch marker converges to unknown without a send", context do
    {_incident, _run, proposal} = authorized_proposal!("restart", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
    assert claim.state == :claimed
    assert claim.operation.status == :dispatching

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("recovered dispatch was resent") end)
             )

    recovered = Cases.get_operation!(operation.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    refute_receive {:effect, _, _}
    assert operation_evidence(operation.id) == 1
  end

  test "cancellation before claim records no-send failure", context do
    {incident, _run, proposal} = authorized_proposal!("cancel", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("cancelled Operation was sent") end)
             )

    cancelled = Cases.get_operation!(operation.id, authorize?: false)
    assert cancelled.status == :failed
    assert cancelled.outcome_category == "cancelled_before_dispatch"
    refute_receive {:effect, _, _}
  end

  test "terminal Operation automatically creates one exact VerificationAttempt and job",
       context do
    {_incident, run, proposal} = authorized_proposal!("verification-accept", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation({:ok, %Target.EffectResult{status: :applied, reference: "remote-1"}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    duplicate = Cases.accept_verification!(operation.id, authorize?: false)

    assert duplicate.id == attempt.id
    assert attempt.status == :queued
    assert attempt.operation_reference == "remote-1"
    assert attempt.parameters == %{"service" => "api"}
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
    assert verification_jobs(attempt.id) == 1
    assert %{"verification_attempt_id" => attempt.id} == verification_job(attempt.id).args
    refute_receive {:verify, _, _}
  end

  test "fresh verification outcomes are called and persisted once with parameters", context do
    for status <- [:verified, :not_verified, :unknown] do
      {incident, _run, proposal} = authorized_proposal!("verification-#{status}", context)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
               )

      assert_receive {:effect, _, _}
      attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

      result = %Target.Verification{
        status: status,
        observed_at: DateTime.utc_now(),
        facts: %{"service" => to_string(status)},
        evidence: [%{"check" => "service"}]
      }

      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation({:ok, result})
               )

      assert_receive {:verify, _state, request}
      assert request.operation_id == operation.id
      assert request.parameters == %{"service" => "api"}

      stored = Cases.get_verification_attempt!(attempt.id, authorize?: false)
      assert stored.status == status
      assert stored.facts == %{"service" => to_string(status)}

      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("terminal verification repeated") end)
               )

      refute_receive {:verify, _, _}

      pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
      assert pending["action"] == "resolve_turn"
      assert pending["verification_attempt_id"] == attempt.id

      assessment = Cases.get_turn!(pending["turn_id"], authorize?: false)
      assert assessment.status == :started
      assert assessment.intent["verification_attempt_id"] == attempt.id
      assert assessment.intent["verification_status"] == to_string(status)
      assert verification_evidence(attempt.id) == 1
    end
  end

  test "lost verification response and restart after marker never repeat the Target call",
       context do
    {_incident, _run, proposal} = authorized_proposal!("verification-lost", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :unknown}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    claim = Cases.claim_verification_dispatch!(attempt.id, authorize?: false)
    assert claim.state == :claimed

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("recovered verification repeated") end)
             )

    recovered = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "verification_interrupted"
    refute_receive {:verify, _, _}
    assert verification_evidence(attempt.id) == 1
  end

  test "a lost verification response is unknown and never repeated", context do
    {_incident, _run, proposal} = authorized_proposal!("verification-response-lost", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> raise "verification response lost" end)
             )

    assert_receive {:verify, _, _}
    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :unknown

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("unknown verification repeated") end)
             )

    refute_receive {:verify, _, _}
  end

  test "policy change after VerificationAttempt acceptance prevents Target dispatch", context do
    {_incident, _run, proposal} = authorized_proposal!("verification-policy", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    Targets.create_target_policy!(
      context.target.id,
      "deny-verification-dispatch",
      [:observation],
      ["observe.service"],
      ["service.inspect"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "Fresh service verification is temporarily forbidden",
      actor: context.admin
    )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("invalidated verification was sent") end)
             )

    invalidated = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert invalidated.status == :unknown
    assert invalidated.outcome_category == "authorization_invalidated"
    refute_receive {:verify, _, _}
  end

  test "cancellation before verification claim prevents Target dispatch", context do
    {incident, _run, proposal} = authorized_proposal!("verification-cancel", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("cancelled verification was sent") end)
             )

    cancelled = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert cancelled.status == :unknown
    assert cancelled.outcome_category == "cancelled_before_verification"
    refute_receive {:verify, _, _}
  end

  test "verification budget exhaustion persists attention without attempt or Target call",
       context do
    {incident, run, proposal} = authorized_proposal!("verification-exhausted", context)

    Cases.charge_resolution_run!(
      incident.id,
      run.id,
      :target_request,
      run.max_target_requests,
      "consume-verification-budget",
      %{"action" => "test"},
      "test",
      authorize?: false
    )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.list_verification_attempts!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    refute_receive {:verify, _, _}
  end

  test "verified Evidence lets a Resolver conclusion resolve a manual Case exactly once",
       context do
    {incident, run, proposal} = authorized_proposal!("manual-recovery", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    assert_receive {:verify, _, _}
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => %{
            "type" => "recovery_conclusion",
            "reason" => "Fresh verification satisfies the declared recovery condition",
            "evidence_ids" => [pending["verification_evidence_id"]]
          },
          "resolver" => %{},
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :source_change,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    resolved = Cases.route_downstream_decision!(completed.id, authorize?: false)
    replayed = Cases.route_downstream_decision!(completed.id, authorize?: false)

    assert resolved.status == :resolved
    assert replayed.id == resolved.id
    assert resolved.alert_state == :not_applicable
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :completed
    refute Cases.get_resolution_run!(run.id, authorize?: false).active
    refute_receive {:effect, _, _}
  end

  test "a Signal Case cannot resolve until its monitoring source also recovers", context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal} =
      authorized_proposal!("signal-recovery", context,
        trigger_kind: :signal,
        alert_state: :firing
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    assert_receive {:verify, _, _}
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => %{
            "type" => "recovery_conclusion",
            "reason" => "Target state is healthy after the effect",
            "evidence_ids" => [pending["verification_evidence_id"]]
          },
          "resolver" => %{},
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :source_change,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, _error} = Cases.route_downstream_decision(completed.id, authorize?: false)
    refute Cases.get_case!(incident.id, authorize?: false).status == :resolved

    current = Cases.get_case!(incident.id, authorize?: false)

    recovered =
      Cases.record_case_source_recovery!(current.id, current.revision, actor: context.operator)

    assert recovered.alert_state == :recovered

    source_recovery =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.case_id == incident.id and &1.kind == "source_recovery"))

    assert source_recovery.source_ref == incident.source_ref
    assert source_recovery.content["alert_state"] == "recovered"

    resolved = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert resolved.status == :resolved
    assert resolved.alert_state == :recovered
    refute_receive {:effect, _, _}
  end

  test "a resumed run can conclude recovery from prior verified Target Evidence", context do
    {incident, run, proposal} = authorized_proposal!("resume-verification", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    pending_case = Cases.get_case!(incident.id, authorize?: false)
    verification_id = pending_case.pending_intent["verification_evidence_id"]
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending_case.id,
        pending_case.revision,
        current_run.id,
        current_run.revision,
        "resume-after-verification",
        "Resolver delivery failed after verification",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        paused_run.authority_mode,
        paused_run.max_elapsed_seconds,
        paused_run.max_resolver_turns,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "Continue after verified Target recovery",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert :ok =
             ResolverDelivery.run(resumed_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :not_applicable
                   assert AI.recovery_ready?(request)
                   assert AI.recovery_evidence_ids(request) == [verification_id]

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The prior verified Target state remains current after resume",
                        evidence_ids: [verification_id]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(resumed_turn.id, authorize?: false)
    resolved = Cases.route_downstream_decision!(completed.id, authorize?: false)
    replayed = Cases.route_downstream_decision!(completed.id, authorize?: false)

    assert resolved.status == :resolved
    assert replayed.id == resolved.id
    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false).status == :completed

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1
  end

  test "a resumed firing Case receives verified continuity without stale observations",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal} =
      authorized_proposal!("resume-investigation", context,
        trigger_kind: :signal,
        alert_state: :firing
      )

    stale_source =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "resume-investigation-stale-source",
        "signal_event",
        "alertmanager",
        incident.source_ref,
        %{
          "current" => false,
          "state" => "recovered",
          "attributes" => %{"annotations" => %{"description" => "stale"}}
        },
        DateTime.add(DateTime.utc_now(), -60, :second),
        authorize?: false
      )

    source =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "resume-investigation-current-source",
        "signal_event",
        "alertmanager",
        incident.source_ref,
        %{
          "current" => true,
          "state" => "firing",
          "attributes" => %{
            "annotations" => %{"description" => "Restore the service to running"}
          }
        },
        DateTime.utc_now(),
        authorize?: false
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    pending_case = Cases.get_case!(incident.id, authorize?: false)
    verification_id = pending_case.pending_intent["verification_evidence_id"]
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending_case.id,
        pending_case.revision,
        current_run.id,
        current_run.revision,
        "resume-firing-after-verification",
        "Resolver delivery failed after verification",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        paused_run.authority_mode,
        paused_run.max_elapsed_seconds,
        paused_run.max_resolver_turns,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "Continue investigation after verified Target progress",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    capabilities = %Target.Capabilities{
      observations: [
        %Target.Operation{
          capability: "observe.service",
          operation: "service.inspect",
          description: "Inspect service state",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "selectors" => %{"type" => "object"},
              "parameters" => %{"type" => "object"}
            },
            "required" => ["selectors", "parameters"]
          },
          output_schema: %{"type" => "object"},
          verification_schema: %{"type" => "object"}
        }
      ],
      effects: []
    }

    assert {:ok, request} =
             ResolverProjection.build(
               resumed_turn.id,
               %AI.Selection{
                 role: :resolver,
                 provider_id: context.resolver_provider.id,
                 provider_revision: context.resolver_provider.revision,
                 source: :assignment
               },
               invocation({:ok, capabilities})
             )

    assert request.alert_state == :firing

    assert [
             %AI.Evidence{id: ^verification_id, kind: "target_verification"},
             %AI.Evidence{id: source_id, kind: "signal_event", content: source_content}
           ] = request.evidence

    assert source_id == source.id
    refute source_id == stale_source.id

    assert get_in(source_content, ["attributes", "annotations", "description"]) ==
             "Restore the service to running"

    assert request.proposal_tools == []
    assert [%AI.ObservationTool{operation: "service.inspect"}] = request.observation_tools
  end

  test "remaining symptoms create a new Proposal without replaying the prior Operation",
       context do
    {incident, run, proposal} = authorized_proposal!("compound-cause", context)
    first_operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first_operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(first_operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Verification{
                      status: :not_verified,
                      observed_at: DateTime.utc_now(),
                      facts: %{"service" => "degraded"}
                    }}
                 )
             )

    assert_receive {:verify, _, _}
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(pending["verification_evidence_id"], context),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    routed = Cases.route_downstream_decision!(completed.id, authorize?: false)
    second_proposal_id = routed.pending_intent["proposal_id"]
    second_proposal = Cases.get_proposal!(second_proposal_id, authorize?: false)
    second_operation = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert second_operation.id != first_operation.id
    assert Cases.get_operation!(first_operation.id, authorize?: false).status == :applied
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 2

    assert :ok =
             OperationDelivery.run(first_operation.id,
               target_invocation: invocation(fn -> flunk("prior effect was replayed") end)
             )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("prior verification was replayed") end)
             )

    refute_receive {:effect, _, _}
    refute_receive {:verify, _, _}
  end

  defp authorized_proposal!(suffix, context, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, :manual)
    alert_state = Keyword.get(opts, :alert_state, :not_applicable)

    incident =
      Cases.open_case!(
        trigger_kind,
        "test",
        "operation-#{suffix}",
        "Operation #{suffix}",
        :warning,
        alert_state,
        %{},
        context.target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "operation-evidence-#{suffix}",
        "observation",
        "fixture",
        "observation-#{suffix}",
        %{"service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "operation-turn-#{suffix}",
        %{"objective" => "Restore the service"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(evidence.id, context),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    authorized = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    {incident, run, authorized}
  end

  defp proposal_intent(evidence_id, context) do
    tool = %{
      "id" => "effect-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "effect.service",
      "operation" => "service.restart"
    }

    %{
      "type" => "proposal",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{"service" => "running"},
      "tool" => tool,
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "verification-tool",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp configure_mode!(admin, mode, max_effects \\ nil) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      max_effects || current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "test #{mode} Operation delivery",
      actor: admin
    )
  end

  defp enable_signal_automation!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

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
      "enable Signal recovery test",
      actor: admin
    )
  end

  defp invocation(response) when is_function(response, 0),
    do: %{test_pid: self(), respond: response}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response end}

  defp verified_result(facts) do
    %Target.Verification{
      status: :verified,
      observed_at: DateTime.utc_now(),
      facts: facts,
      evidence: [%{"check" => "fresh"}]
    }
  end

  defp operation_jobs(operation_id) do
    Opsonde.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      ),
      :count
    )
  end

  defp operation_job(operation_id) do
    Opsonde.Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      )
    )
  end

  defp operation_evidence(operation_id) do
    Opsonde.Repo.aggregate(
      from(evidence in Opsonde.Cases.Evidence,
        where: evidence.idempotency_key == ^"operation:outcome:#{operation_id}"
      ),
      :count
    )
  end

  defp verification_jobs(attempt_id) do
    Opsonde.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(VerificationWorker) and
            fragment("?->>'verification_attempt_id'", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp verification_job(attempt_id) do
    Opsonde.Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(VerificationWorker) and
            fragment("?->>'verification_attempt_id'", job.args) == ^attempt_id
      )
    )
  end

  defp verification_evidence(attempt_id) do
    Opsonde.Repo.aggregate(
      from(evidence in Opsonde.Cases.Evidence,
        where: evidence.idempotency_key == ^"verification:outcome:#{attempt_id}"
      ),
      :count
    )
  end
end
