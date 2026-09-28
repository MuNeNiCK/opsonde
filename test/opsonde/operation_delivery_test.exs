defmodule Opsonde.OperationDeliveryTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Reports, Signals, Targets}

  alias Opsonde.Cases.Turn.ResolverDelivery, as: ResolverDelivery
  alias Opsonde.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Opsonde.Cases.Operation.AcceptanceWorker, as: OperationAcceptanceWorker
  alias Opsonde.Cases.Operation.Delivery, as: OperationDelivery
  alias Opsonde.Cases.Operation.Worker, as: OperationWorker
  alias Opsonde.Cases.VerificationAttempt.Delivery, as: VerificationDelivery
  alias Opsonde.Cases.VerificationAttempt.Worker, as: VerificationWorker

  alias Opsonde.Cases.Case.ConditionContext, as: ConditionContext
  alias Opsonde.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Opsonde.Cases.Case.SignalRecoveryCheckWorker, as: SignalRecoveryCheckWorker

  alias Opsonde.Cases.CaseDispatch.Worker, as: CaseDispatchWorker
  alias Opsonde.Targets.ResourceScope

  alias Opsonde.Providers.{AI, Signal, Target}
  alias Opsonde.Reports.Report.GenerationWorker

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
      Opsonde.TestAIUsage.configure!(resolver_provider.id, :resolver, 10, admin)
      |> Map.fetch!(:resolver)

    reviewer_provider =
      Providers.create_provider!(
        "operation-reviewer",
        :ai,
        "fixture-ai",
        %{"model" => "reviewer-model"},
        %{"api_key" => "reviewer-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Opsonde.TestAIUsage.configure!(reviewer_provider.id, :reviewer, 10, admin)

    configure_mode!(admin, :full_access)

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment,
      reviewer_provider: reviewer_provider
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

  test "competing Cases defer a Target effect and an interrupted send blocks blind retry",
       context do
    {_first_case, _first_run, first_proposal} = authorized_proposal!("conflict-first", context)
    {second_case, _second_run, second_proposal} = authorized_proposal!("conflict-second", context)
    first = Cases.accept_operation!(first_proposal.id, authorize?: false)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert Cases.claim_operation_dispatch!(first.id, authorize?: false).state == :claimed
    assert Cases.claim_operation_dispatch!(second.id, authorize?: false).state == :deferred

    assert {:snooze, 5} =
             OperationDelivery.run(second.id,
               target_invocation: invocation(fn -> flunk("competing effect was sent") end)
             )

    assert Cases.get_operation!(second.id, authorize?: false).status == :queued
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation(fn -> flunk("interrupted effect was resent") end)
             )

    assert Cases.get_operation!(first.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation:
                 invocation(fn -> flunk("effect after unknown outcome was sent") end)
             )

    blocked = Cases.get_operation!(second.id, authorize?: false)
    assert blocked.status == :failed
    assert blocked.outcome_category == "prior_effect_unknown"
    assert blocked.dispatch_started_at == nil
    assert Cases.get_case!(second_case.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "canonical service selectors separate unrelated resources on one Target", context do
    {_api_case, _api_run, api_proposal} = authorized_proposal!("scope-api", context)

    {_db_case, _db_run, db_proposal} =
      authorized_proposal!("scope-db", context, service: "db")

    api = Cases.accept_operation!(api_proposal.id, authorize?: false)
    db = Cases.accept_operation!(db_proposal.id, authorize?: false)

    assert api.resource_scope == "service:api.service"
    assert db.resource_scope == "service:db.service"
    method = Targets.get_access_method!(api.access_method_id, authorize?: false)

    assert ResourceScope.key(method, "effect.service", "service.restart", %{
             "unit" => "api.service"
           }) ==
             api.resource_scope

    assert ResourceScope.key(method, "effect.power", "bmc.power.cycle", %{"outlet" => "1"}) ==
             "target"

    assert Cases.claim_operation_dispatch!(api.id, authorize?: false).state == :claimed
    assert Cases.claim_operation_dispatch!(db.id, authorize?: false).state == :claimed
  end

  test "a later Case must cite a fresh Target observation after a conflicting effect", context do
    {_first_case, _first_run, first_proposal} = authorized_proposal!("effect-first", context)
    {stale_case, stale_run, stale_proposal} = authorized_proposal!("effect-stale", context)

    {_observed_case, observed_run, observation_proposal} =
      authorized_proposal!("effect-reobserve", context, request_kind: :observation)

    first = Cases.accept_operation!(first_proposal.id, authorize?: false)
    stale = Cases.accept_operation!(stale_proposal.id, authorize?: false)
    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(stale.id,
               target_invocation: invocation(fn -> flunk("stale effect was sent") end)
             )

    stopped = Cases.get_operation!(stale.id, authorize?: false)
    assert stopped.status == :failed
    assert stopped.outcome_category == "target_effect_changed"
    assert stopped.dispatch_started_at == nil

    assert Cases.get_case!(stale_case.id, authorize?: false).pending_intent["action"] ==
             "resolve_turn"

    assert [_reassessment] = Cases.started_turns_for_run!(stale_run.id, authorize?: false)
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation({
                   :ok,
                   %Target.Observation{
                     facts: %{"service" => "api"},
                     observed_at: DateTime.utc_now()
                   }
                 })
             )

    assert_receive {:observe, _, _}
    evidence = operation_evidence_record(observation.id)
    [turn] = Cases.started_turns_for_run!(observed_run.id, authorize?: false)

    resolved_turn =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(evidence.id, context, :effect),
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

    Cases.route_downstream_decision!(resolved_turn.id, authorize?: false)
    authorized = Cases.proposal_by_source_turn!(resolved_turn.id, authorize?: false)
    fresh = Cases.accept_operation!(authorized.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(fresh.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(fresh.id, authorize?: false).status == :applied
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

  test "Case action rejects a conflicting observation handoff without charging a Turn", context do
    {incident, run, proposal} =
      authorized_proposal!("conflicting-observation-handoff", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
    assert claim.state == :claimed

    Cases.record_operation_outcome!(
      claim.operation,
      claim.operation.revision,
      %{
        status: :applied,
        outcome_category: "target_observed",
        result_details: %{"facts" => %{"active_state" => "active"}},
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.update_case_record!(
      current,
      current.revision,
      %{pending_intent: %{"action" => "verify_operation", "operation_id" => operation.id}},
      authorize?: false
    )

    turns_before = Cases.list_turns!(actor: context.admin) |> length()
    count_before = Cases.get_resolution_run!(run.id, authorize?: false).turn_count

    assert {:error, _error} = OperationDelivery.run(operation.id)
    assert length(Cases.list_turns!(actor: context.admin)) == turns_before
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == count_before
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
      case_context = separate_target!(context, "outcome-#{status}")
      {incident, _run, proposal} = authorized_proposal!("outcome-#{status}", case_context)
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

      evidence = operation_evidence_record(operation.id)
      assert evidence.content["request_kind"] == "effect"
      assert evidence.content["capability"] == "effect.service"
      assert evidence.content["operation"] == "service.restart"
      assert evidence.content["selectors"] == %{"service" => "api"}
      assert evidence.content["parameters"] == %{"service" => "api"}
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

  test "failed observations persist the bounded Target error and exact request", context do
    {incident, _run, proposal} =
      authorized_proposal!("observation-failure", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation({:error, :failed, "service observation failed without a stack trace"})
             )

    assert_receive {:observe, _, _}
    failed = Cases.get_operation!(operation.id, authorize?: false)
    assert failed.status == :failed

    assert failed.result_details == %{
             "message" => "service observation failed without a stack trace",
             "provider_category" => "failed"
           }

    evidence = operation_evidence_record(operation.id)
    assert evidence.case_id == incident.id
    assert evidence.content["request_kind"] == "observation"
    assert evidence.content["operation"] == "service.inspect"
    assert evidence.content["selectors"] == %{"service" => "api"}
    assert evidence.content["details"] == failed.result_details
    assert evidence.content["access_method_revision"] == context.method.revision

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert run.no_progress_turns == 0

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("failed observation was resent") end)
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0
  end

  test "observation continuation carries the relationship used to enter its Target", context do
    relationship_id = Ecto.UUID.generate()

    {incident, _run, proposal} =
      authorized_proposal!("observation-relationship", context,
        request_kind: :observation,
        turn_intent: %{
          "objective" => "Inspect the related Target",
          "source" => "target_relationship",
          "relationship_id" => relationship_id
        }
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(operation, %{"service" => "api", "state" => "active"})

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    continued = Cases.get_turn!(pending["turn_id"], authorize?: false)
    assert continued.intent["source"] == "observation"
    assert continued.intent["prior_relationship_id"] == relationship_id
  end

  test "only a new observation result resets the no-progress budget", context do
    {incident, run, proposal} =
      authorized_proposal!("observation-progress", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(first, %{"service" => "api", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    duplicate = continue_observation!(incident, context, first.id)
    assert :ok = deliver_observation(duplicate, %{"service" => "api", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    changed = continue_observation!(incident, context, duplicate.id)
    assert :ok = deliver_observation(changed, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    repeated = continue_observation!(incident, context, changed.id)
    assert :ok = deliver_observation(repeated, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    changed_input = continue_observation!(incident, Map.put(context, :service, "db"), repeated.id)
    assert :ok = deliver_observation(changed_input, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    assert :ok =
             OperationDelivery.run(changed_input.id,
               target_invocation: invocation(fn -> flunk("completed observation was resent") end)
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0
  end

  test "novel failed probes remain available but repeated input stops before another paid Turn",
       context do
    {incident, run, proposal} =
      authorized_proposal!("observation-no-progress", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:error, :failed, "Target read failed"})
             )

    failed = Cases.get_operation!(first.id, authorize?: false)
    assert failed.result_details["provider_category"] == "failed"
    assert failed.access_method_revision == context.method.revision

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    different = continue_observation!(incident, Map.put(context, :service, "db"), first.id)

    assert :ok =
             OperationDelivery.run(different.id,
               target_invocation: invocation({:error, :failed, "Different Target read failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    second = continue_observation!(incident, context, different.id)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:error, :failed, "Target read failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    third = continue_observation!(incident, context, second.id)

    assert :ok =
             OperationDelivery.run(third.id,
               target_invocation: invocation({:error, :failed, "Target read still failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 2

    fourth = continue_observation!(incident, context, third.id)

    assert :ok =
             OperationDelivery.run(fourth.id,
               target_invocation: invocation({:error, :failed, "Target read still failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 3
    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "No-progress turn limit exhausted"
  end

  test "repeated transport failures with one Access Method remove its tools from the next AI request",
       context do
    {incident, run, proposal} =
      authorized_proposal!("method-unreachable", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:error, :retryable, "endpoint unavailable"})
             )

    second = continue_observation!(incident, Map.put(context, :service, "db"), first.id)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:error, :timeout, "endpoint timed out"})
             )

    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "unrelated-success-after-failure",
      "operation_outcome",
      "target",
      Ecto.UUID.generate(),
      %{"status" => "applied", "target_id" => Ecto.UUID.generate()},
      DateTime.utc_now(),
      authorize?: false
    )

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    next_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert {:ok, request} =
             ResolverProjection.build(
               next_turn.id,
               %AI.Selection{
                 role: :resolver,
                 provider_id: context.resolver_provider.id,
                 provider_revision: context.resolver_provider.revision,
                 source: :assignment
               },
               invocation(fn ->
                 flunk("unrelated Target outcome reopened the failed Access Method")
               end)
             )

    assert request.observation_tools == []
    assert request.proposal_tools == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running

    assert Cases.get_operation!(first.id, authorize?: false).result_details["provider_category"] ==
             "retryable"
  end

  test "interleaved new reads do not hide repeated identical observations", context do
    {incident, run, proposal} =
      authorized_proposal!("observation-cumulative-repeat", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(first, %{"service" => "api", "state" => "active"})

    second = continue_observation!(incident, context, first.id)
    assert :ok = deliver_observation(second, %{"service" => "api", "state" => "active"})

    other = continue_observation!(incident, Map.put(context, :service, "db"), second.id)
    assert :ok = deliver_observation(other, %{"service" => "db", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    third = continue_observation!(incident, context, other.id)
    assert :ok = deliver_observation(third, %{"service" => "api", "state" => "active"})

    another = continue_observation!(incident, Map.put(context, :service, "cache"), third.id)
    assert :ok = deliver_observation(another, %{"service" => "cache", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    fourth = continue_observation!(incident, context, another.id)
    assert :ok = deliver_observation(fourth, %{"service" => "api", "state" => "active"})

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Repeated identical Target observation limit exhausted"

    assert :ok =
             OperationDelivery.run(fourth.id,
               target_invocation: invocation(fn -> flunk("repeated observation was resent") end)
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
  end

  test "the same Target state across Access Methods does not reset progress", context do
    alternate =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "operation-alternate-ssh",
        "linux",
        "ssh",
        "ssh://operation-linux-alternate",
        context.provider.revision,
        9,
        ["observe.service"],
        actor: context.admin
      )

    alternate_context = %{context | method: alternate}

    {incident, run, proposal} =
      authorized_proposal!("observation-cross-method", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(
               first,
               %{"system_id" => "method-a", "state" => "active"},
               %{"state" => "active"}
             )

    second = continue_observation!(incident, alternate_context, first.id)

    assert :ok =
             deliver_observation(
               second,
               %{"system_id" => "method-b", "state" => "active"},
               %{"state" => "active"}
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    assert Cases.get_operation!(second.id, authorize?: false).result_details["facts"][
             "system_id"
           ] == "method-b"

    third = continue_observation!(incident, context, second.id)

    assert :ok =
             deliver_observation(
               third,
               %{"system_id" => "method-a", "state" => "active"},
               %{"state" => "active"}
             )

    fourth = continue_observation!(incident, alternate_context, third.id)

    assert :ok =
             deliver_observation(
               fourth,
               %{"system_id" => "method-b", "state" => "active"},
               %{"state" => "active"}
             )

    assert Cases.get_case!(incident.id, authorize?: false).stop_reason ==
             "Repeated identical Target observation limit exhausted"

    progress_events =
      Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
        event.case_id == incident.id and
          event.event_type in ["observation_progress", "limit_exhausted"]
      end)

    assert Cases.account_observation_progress!(fourth.id, authorize?: false).status == :exhausted

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and
               event.event_type in ["observation_progress", "limit_exhausted"]
           end) == progress_events
  end

  test "denied observation returns its reason to Resolver without authorizing an Operation",
       context do
    configure_mode!(context.admin, :auto)

    Targets.create_target_policy!(
      context.target.id,
      "deny-observation-input",
      [:observation],
      ["observe.service"],
      ["service.inspect"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "This exact Target observation is unsupported",
      actor: context.admin
    )

    {incident, run, proposal} =
      authorized_proposal!("denied-observation-retry", context, request_kind: :observation)

    assert proposal.status == :blocked
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    assert pending["action"] == "resolve_turn"
    next_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)
    assert next_turn.intent["rejection_reason"] == "This exact Target observation is unsupported"
    assert next_turn.intent["rejected_operation"] == "service.inspect"
    assert Cases.operations_for_case!(incident.id, authorize?: false) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    assert Cases.route_proposal_authority!(proposal.id, authorize?: false).id == proposal.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == 2

    initial_result = Cases.get_turn!(proposal.source_turn_id, authorize?: false).result

    for count <- [2, 3] do
      pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
      retry_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

      completed =
        Cases.complete_turn!(
          retry_turn.id,
          retry_turn.revision,
          initial_result,
          :observation_pending,
          %{"action" => "route_resolver_decision", "turn_id" => retry_turn.id},
          "Review the Resolver decision",
          authorize?: false
        ).value

      Cases.route_downstream_decision!(completed.id, authorize?: false)
      retry_proposal = Cases.proposal_by_source_turn!(completed.id, authorize?: false)
      assert retry_proposal.status == :blocked
      assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == count
    end

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "No-progress turn limit exhausted"
    assert Cases.operations_for_case!(incident.id, authorize?: false) == []
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

  test "native Signal change after acceptance stops the Target send and starts one reassessment",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("condition-before-send", context, trigger_kind: :signal)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    event_key = incident.initial_context["signal_event_key"]

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "condition-before-send-recovered",
      DateTime.utc_now()
    )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("stale Target request was sent") end)
             )

    stopped = Cases.get_operation!(operation.id, authorize?: false)
    assert stopped.status == :failed
    assert stopped.outcome_category == "source_context_changed"
    assert stopped.dispatch_started_at == nil
    assert Cases.list_verification_attempts!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.pending_intent["action"] == "resolve_turn"
    assert current.pending_intent["source_operation_id"] == operation.id
    assert [_reassessment] = Cases.started_turns_for_run!(run.id, authorize?: false)

    assert %{kind: "operation_outcome"} =
             Cases.evidence_by_idempotency!(
               incident.id,
               "operation:outcome:#{operation.id}",
               authorize?: false
             )

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
      case_context = separate_target!(context, "verification-#{status}")
      {incident, _run, proposal} = authorized_proposal!("verification-#{status}", case_context)
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

      current = Cases.get_case!(incident.id, authorize?: false)

      assert {:error, _} =
               Cases.handoff_case_verification(
                 current,
                 current.revision,
                 attempt.id,
                 pending["verification_evidence_id"],
                 :evaluate,
                 nil,
                 authorize?: false
               )

      assert Cases.get_case!(incident.id, authorize?: false).revision == current.revision

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("terminal effect repeated") end)
               )

      assert Cases.get_case!(incident.id, authorize?: false).pending_intent == pending

      assert Cases.verification_attempt_by_operation!(operation.id, authorize?: false).id ==
               attempt.id
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

  test "verified Target Evidence starts investigation without automatically resolving a Signal Case",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("signal-multilingual-recovery", context,
        trigger_kind: :signal,
        additional_event_key: "operation-signal-multilingual-recovery:secondary"
      )

    first_event_key = incident.initial_context["signal_event_key"]
    second_event_key = first_event_key <> ":secondary"

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    turns_before = length(Cases.list_turns!(actor: context.admin))

    recover_signal!(signal_provider, context, first_event_key, "primary-recovered")
    still_firing = Cases.get_case!(incident.id, authorize?: false)
    assert still_firing.status == :running
    assert Enum.count(Signals.list_conditions!(actor: context.admin), &(&1.state == :firing)) == 1

    recovered_at = DateTime.utc_now()

    recover_signal!(
      signal_provider,
      context,
      second_event_key,
      "secondary-recovered",
      recovered_at
    )

    recover_signal!(
      signal_provider,
      context,
      second_event_key,
      "secondary-recovered",
      recovered_at
    )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert_receive {:verify, _, _}

    current = Cases.get_case!(incident.id, authorize?: false)
    assert report_jobs(current.id) == []
    assert Reports.list_reports!(actor: context.admin) == []

    assert current.status == :running
    assert Enum.all?(Signals.list_conditions!(actor: context.admin), &(&1.state == :recovered))
    assert length(Cases.list_turns!(actor: context.admin)) == turns_before + 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).active
    refute_receive {:effect, _, _}
  end

  test "a Signal Case cannot resolve until its monitoring source also recovers", context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, signal_provider} =
      authorized_proposal!("signal-recovery", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    recover_signal!(signal_provider, context, event_key, "recovered-before-verification")
    before_verification = Cases.get_case!(incident.id, authorize?: false)
    assert before_verification.status == :running
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert_receive {:verify, _, _}

    assert Enum.any?(
             Cases.list_evidence!(actor: context.admin),
             &(&1.case_id == incident.id and &1.kind == "signal_event" and
                 &1.content["state"] == "recovered")
           )

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running

    assert [_turn] =
             Cases.started_turns_for_run!(
               Cases.active_resolution_run!(current.id, authorize?: false).id,
               authorize?: false
             )

    refute_receive {:effect, _, _}
  end

  test "two recovered Conditions stay open for Resolver assessment after one Target verification",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("two-service-conditions", context,
        trigger_kind: :signal,
        additional_event_key: "operation-two-service-conditions:db",
        additional_subject: "db.service"
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "api-recovered"
    )

    signal_event!(
      signal_provider,
      context,
      "operation-two-service-conditions:db",
      "db-recovered",
      :recovered,
      DateTime.utc_now(),
      %{"labels" => %{"service" => "db.service", "alertname" => "ServiceUnavailable"}}
    )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert report_jobs(incident.id) == []
    assert [_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
  end

  test "a later effect on one Condition does not stale another recovered Condition",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, signal_provider} =
      authorized_proposal!("scoped-effect-recovery", context,
        trigger_kind: :signal,
        additional_event_key: "operation-scoped-effect-recovery:db",
        additional_subject: "db.service",
        affected_event_key: "operation-scoped-effect-recovery"
      )

    assert length(proposal.affected_conditions) == 1

    other_key = "operation-scoped-effect-recovery:db"
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}

    signal_event!(
      signal_provider,
      context,
      other_key,
      "delayed-db-recovery-before-effect",
      :recovered,
      DateTime.add(operation.accepted_at, -1, :microsecond),
      %{"labels" => %{"service" => "db.service", "alertname" => "ServiceUnavailable"}}
    )

    other_correlation =
      Enum.find(
        Signals.list_signal_correlations!(actor: context.admin),
        &(&1.event_key == other_key)
      )

    other =
      Enum.find(
        Signals.list_conditions!(actor: context.admin),
        &(&1.signal_correlation_id == other_correlation.id)
      )

    assert other.state == :recovered

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "api-recovered-after-effect"
    )

    {:ok, assessments} = ConditionRecovery.assess_current(incident)
    by_id = Map.new(assessments, &{&1.condition_id, &1.status})
    assert by_id[other.id] == :needs_observation
    assert Enum.all?(assessments, &(&1.status != :stale_source))

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    current = Cases.get_case!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(current.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => revisions,
        "intent" => %{"type" => "handoff", "reason" => "Separate the independent service"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)

    child =
      Cases.split_case_conditions!(
        current.id,
        current.revision,
        [other.id],
        revisions,
        "The other service needs its own investigation",
        actor: context.admin
      )

    assert child.split_parent_id == incident.id

    assert {:ok, [%{condition_id: condition_id, status: :needs_observation}]} =
             ConditionRecovery.assess_current(child)

    assert condition_id == other.id
  end

  for terminal_status <- [:failed, :partial, :unknown] do
    @tag terminal_status: terminal_status
    test "a terminal #{terminal_status} effect needs post-outcome Target evidence", context do
      enable_signal_automation!(context.admin)
      status = context.terminal_status

      {incident, run, proposal, signal_provider} =
        authorized_proposal!("terminal-recovery-#{status}", context, trigger_kind: :signal)

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, %Target.EffectResult{status: status}})
               )

      assert_receive {:effect, _, _}

      {:ok, [condition]} = ConditionContext.current_conditions(incident)

      assert {:ok, nil} =
               ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

      recover_signal!(
        signal_provider,
        context,
        incident.initial_context["signal_event_key"],
        "post-#{status}-recovery"
      )

      assert {:ok, [%{status: :needs_observation}]} =
               ConditionRecovery.assess_current(incident)
    end
  end

  test "a partial manual Target effect cannot close the Case without observed symptom recovery",
       context do
    {incident, _run, proposal} = authorized_proposal!("manual-partial-effect", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :partial}})
             )

    assert Cases.get_operation!(operation.id, authorize?: false).status == :partial
    assert Cases.get_case!(incident.id, authorize?: false).status != :resolved

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a second effect rejected before send does not stale source recovery", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("second-effect-recovery", context, trigger_kind: :signal)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    first_attempt = Cases.verification_attempt_by_operation!(first.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(first_attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "await_source_recovery"

    Repo.update_all(
      from(item in Opsonde.Cases.VerificationAttempt, where: item.id == ^first_attempt.id),
      set: [completed_at: DateTime.add(DateTime.utc_now(), -31, :second)]
    )

    [check_job] = recovery_check_jobs(incident.id)
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    current = Cases.get_case!(incident.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)
    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" =>
            signal_proposal_intent(source.id, context, :effect)
            |> Map.put(
              "affected_conditions",
              Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
                %{"condition_id" => id, "revision" => revision}
              end)
            ),
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

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    second_proposal = Cases.materialize_proposal!(completed.id, authorize?: false)
    second_proposal = Cases.route_proposal_authority!(second_proposal.id, authorize?: false)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "recovery-before-second-send",
      DateTime.add(second.accepted_at, -1, :microsecond)
    )

    assert {:error, "Relevant Target effect is not complete"} =
             ConditionRecovery.assess_current(incident)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation(fn -> flunk("stale effect was sent") end)
             )

    rejected = Cases.get_operation!(second.id, authorize?: false)
    assert rejected.status == :failed
    assert rejected.dispatch_started_at == nil
    refute_receive {:effect, _, _}

    assert {:ok, [%{status: :needs_observation}]} =
             ConditionRecovery.assess_current(incident)
  end

  test "a later dispatched effect on one Condition invalidates earlier source recovery",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, initial_proposal, signal_provider} =
      authorized_proposal!("later-dispatched-effect", context, trigger_kind: :signal)

    first = Cases.accept_operation!(initial_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    first_attempt = Cases.verification_attempt_by_operation!(first.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(first_attempt.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Verification{
                      status: :not_verified,
                      observed_at: DateTime.utc_now(),
                      facts: %{"active_state" => "inactive"}
                    }}
                 )
             )

    assert_receive {:verify, _, _}
    [observation_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    observation_intent = signal_proposal_intent(source.id, context, :observation)

    observation_proposal =
      complete_signal_proposal!(observation_turn, observation_intent, incident, context)

    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation({
                   :ok,
                   %Target.Observation{
                     facts: %{"unit" => "api.service", "active_state" => "inactive"},
                     observed_at: DateTime.utc_now()
                   }
                 })
             )

    assert_receive {:observe, _, _}
    observation_evidence = operation_evidence_record(observation.id)
    [effect_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    second_intent =
      signal_proposal_intent(observation_evidence.id, context, :effect)
      |> Map.put(
        "affected_conditions",
        Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
          %{"condition_id" => id, "revision" => revision}
        end)
      )

    second_proposal = complete_signal_proposal!(effect_turn, second_intent, incident, context)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(second.id, authorize?: false).status == :applied

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "recovered-before-second-effect",
      DateTime.add(second.accepted_at, -1, :microsecond)
    )

    assert {:ok, [%{status: :stale_source}]} = ConditionRecovery.assess_current(incident)

    second_attempt = Cases.verification_attempt_by_operation!(second.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(second_attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert {:ok, [%{status: :ready_for_review, evidence_ids: [evidence_id]}]} =
             ConditionRecovery.assess_current(incident)

    assert is_binary(evidence_id)
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a verified Signal effect waits, then investigates once if monitoring stays firing",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("signal-wait-expired", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    waiting = Cases.get_case!(incident.id, authorize?: false)
    assert waiting.status == :running
    assert waiting.pending_intent["action"] == "await_source_recovery"
    [check_job] = recovery_check_jobs(incident.id)
    assert DateTime.compare(check_job.scheduled_at, DateTime.utc_now()) == :gt
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             waiting.pending_intent

    # Move only the test fixture's completion clock past the wait boundary.
    Repo.update_all(
      from(item in Opsonde.Cases.VerificationAttempt, where: item.id == ^attempt.id),
      set: [completed_at: DateTime.add(DateTime.utc_now(), -31, :second)]
    )

    assert :ok = SignalRecoveryCheckWorker.perform(check_job)
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    investigating = Cases.get_case!(incident.id, authorize?: false)
    assert investigating.status == :running
    assert investigating.pending_intent["action"] == "resolve_turn"
    assert investigating.pending_intent["verification_attempt_id"] == attempt.id

    assert Enum.count(Cases.list_turns!(actor: context.admin), &(&1.resolution_run_id == run.id)) ==
             2

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1

    recover_signal!(signal_provider, context, event_key, "recovered-after-reinvestigation")
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1
  end

  test "a delayed pre-effect recovery event cannot settle a verified Signal Case", context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, signal_provider} =
      authorized_proposal!("signal-stale-recovery", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "await_source_recovery"

    recovered_before_effect = DateTime.add(operation.accepted_at, -1, :second)

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "late-old-recovery",
      recovered_before_effect
    )

    current = Cases.get_case!(incident.id, authorize?: false)
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)
    assert current.status == :running
    assert current.pending_intent["action"] == "await_source_recovery"

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
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
                   assert AI.recovery_evidence_ids(request) == [verification_id]

                   assert Enum.any?(
                            request.historical_evidence,
                            &(&1.kind == "operation_outcome")
                          )

                   refute Enum.any?(request.historical_evidence, &(&1.id == verification_id))

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The prior verified Target state remains current after resume",
                        evidence_ids: [verification_id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => verification_id,
                            "fact_keys" => ["service"],
                            "reason" => "The verified service is running"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(resumed_turn.id, authorize?: false)
    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    assert requested.pending_intent["action"] == "review_recovery"

    assert {:error, _reason} =
             Opsonde.Cases.Turn.RecoveryReviewDelivery.run(completed.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error,
                    %AI.Error{
                      category: :invalid_output,
                      message: "Reviewer response does not match schema",
                      failure_code: "schema_validation",
                      dispatched?: true,
                      usage: %AI.Usage{input_tokens: 5, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    approve_recovery!(completed, context, delivery_attempt: 2, max_delivery_attempts: 3)
    resolved = Cases.get_case!(incident.id, authorize?: false)
    replayed = Cases.route_downstream_decision!(completed.id, authorize?: false)

    assert resolved.status == :resolved
    assert replayed.id == resolved.id
    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false).status == :completed

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1
  end

  test "a native recovered Condition with a fresh exact observation can conclude without an effect",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("observation-recovery", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    observed_at = DateTime.utc_now()

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: observed_at,
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "fresh"}]
                    }}
                 )
             )

    assert_receive {:observe, _, _}
    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered
                   assert AI.recovery_evidence_ids(request) == [evidence.id]
                   assert [%AI.Condition{} = condition] = request.conditions
                   assert condition.recovery_status == :ready_for_review
                   assert condition.recovery_evidence_ids == [evidence.id]

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "Native source and exact service observation are healthy",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)

    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    approve_recovery!(completed, context)
    resolved = Cases.get_case!(incident.id, authorize?: false)
    assert resolved.status == :resolved
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :completed
    assert Cases.get_operation!(operation.id, authorize?: false).request_kind == :observation
    assert Enum.count(Cases.list_operations!(actor: context.admin)) == 1

    assert [job] = report_jobs(resolved.id)
    assert job.args["case_revision"] == resolved.revision
    assert :ok = GenerationWorker.perform(job)
    assert :ok = GenerationWorker.perform(job)

    report = Reports.report_by_case_revision!(resolved.id, resolved.revision, authorize?: false)
    assert report.case_id == resolved.id
    assert Enum.count(Reports.list_reports!(actor: context.admin)) == 1
  end

  test "related Target effect needs both direct observations and a current relationship at dispatch",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, _signal_provider} =
      authorized_proposal!("related-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    symptom_observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(symptom_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    symptom_evidence = operation_evidence_record(symptom_observation.id)
    effect_context = separate_target!(context, "related-effect-target")

    relation =
      Targets.create_relationship!(
        context.target.id,
        effect_context.target.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.update_case_record!(
      current,
      current.revision,
      %{
        selected_target_id: effect_context.target.id,
        selected_target_revision: effect_context.target.revision
      },
      authorize?: false
    )

    turn =
      incident.id
      |> Cases.get_case!(authorize?: false)
      |> Map.fetch!(:pending_intent)
      |> Map.fetch!("turn_id")
      |> then(&Cases.get_turn!(&1, authorize?: false))

    effect_target_observation_proposal =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(symptom_evidence.id, effect_context, :observation),
        incident,
        context
      )

    effect_target_observation =
      Cases.accept_operation!(effect_target_observation_proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(effect_target_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    target_evidence = operation_evidence_record(effect_target_observation.id)
    [condition] = ConditionContext.current_conditions(incident) |> elem(1)

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    action = signal_proposal_intent(target_evidence.id, effect_context, :effect)
    evidence_ids = [symptom_evidence.id, target_evidence.id]

    assert {:ok, true} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               evidence_ids,
               action
             )

    for {claims, ids} <- [
          {[%{"condition_id" => condition.id, "revision" => condition.revision}], evidence_ids},
          {[%{claim | "relationship_revision" => relation.revision + 1}], evidence_ids},
          {[claim], [symptom_evidence.id]},
          {[claim], [target_evidence.id]}
        ] do
      assert {:ok, false} =
               ConditionContext.affected_current?(
                 incident,
                 :effect,
                 claims,
                 ids,
                 action
               )
    end

    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    effect_proposal =
      complete_signal_proposal!(
        turn,
        action
        |> Map.put("evidence_ids", evidence_ids)
        |> Map.put("affected_conditions", [claim]),
        incident,
        context
      )

    effect = Cases.accept_operation!(effect_proposal.id, authorize?: false)

    Targets.deactivate_relationship!(relation, relation.revision, actor: context.admin)

    assert %{state: :terminal} = Cases.claim_operation_dispatch!(effect.id, authorize?: false)
    assert Cases.get_operation!(effect.id, authorize?: false).dispatch_started_at == nil
    refute_receive {:effect, _, _}
  end

  test "a failed native symptom observation supports investigation but never recovery",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("failed-related-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    symptom_operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(symptom_operation.id,
               target_invocation: invocation({:error, :retryable, "Guest is unreachable"})
             )

    symptom = operation_evidence_record(symptom_operation.id)
    assert symptom.content["category"] == "observation_failed"

    assert {:ok,
            [
              %{
                status: :needs_observation,
                evidence_ids: [],
                failed_observation_ids: [failed_id]
              }
            ]} = ConditionRecovery.assess_current(incident)

    assert failed_id == symptom.id
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    second_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    second_proposal =
      complete_signal_proposal!(
        second_turn,
        signal_proposal_intent(symptom.id, context, :observation),
        incident,
        context
      )

    second_operation = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(second_operation.id,
               target_invocation: invocation({:error, :timeout, "Guest still unreachable"})
             )

    symptom = operation_evidence_record(second_operation.id)
    failed_id = symptom.id

    selection = %AI.Selection{
      role: :resolver,
      provider_id: context.resolver_provider.id,
      provider_revision: context.resolver_provider.revision,
      assignment_id: context.resolver_assignment.id,
      assignment_revision: context.resolver_assignment.revision,
      source: :assignment
    }

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    pre_effect_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert {:ok, suppressed} =
             ResolverProjection.build(
               pre_effect_turn.id,
               selection,
               invocation(fn -> flunk("twice-failed method was queried before effect") end)
             )

    assert suppressed.observation_tools == []

    effect_context = separate_target!(context, "failed-related-effect-target")

    relation =
      Targets.create_relationship!(
        context.target.id,
        effect_context.target.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.update_case_record!(
      current,
      current.revision,
      %{
        selected_target_id: effect_context.target.id,
        selected_target_revision: effect_context.target.revision
      },
      authorize?: false
    )

    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert {:ok, request} =
             ResolverProjection.build(
               turn.id,
               selection,
               invocation({:ok, %Target.Capabilities{observations: [], effects: []}})
             )

    assert [%AI.Condition{failed_observation_ids: [^failed_id]}] = request.conditions
    assert request.recovery_evidence_ids == []
    assert failed_id in Enum.map(request.evidence, & &1.id)
    assert relation.id in Enum.map(request.target_relations, & &1.id)
    assert failed_id in AI.proposal_evidence_ids(request)

    effect_target_observation_proposal =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(symptom.id, effect_context, :observation),
        incident,
        context
      )

    effect_target_observation =
      Cases.accept_operation!(effect_target_observation_proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(effect_target_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    target_evidence = operation_evidence_record(effect_target_observation.id)
    [condition] = ConditionContext.current_conditions(incident) |> elem(1)

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    assert {:ok, nil} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

    action = signal_proposal_intent(target_evidence.id, effect_context, :effect)

    assert {:ok, true} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               [symptom.id, target_evidence.id],
               action
             )

    assert {:ok, false} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               [symptom.id],
               action
             )

    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    effect_proposal =
      complete_signal_proposal!(
        turn,
        action
        |> Map.put("evidence_ids", [symptom.id, target_evidence.id])
        |> Map.put("affected_conditions", [claim]),
        incident,
        context
      )

    assert effect_proposal.affected_conditions == [claim]
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    effect = Cases.accept_operation!(effect_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(effect.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert {:ok, %DateTime{}} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

    assert {:ok, nil} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [Ecto.UUID.generate()])
  end

  test "Resolver receives a current failed observation after Signal recovery", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("failed-recovered-resolver", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation: invocation({:error, :failed, "Guest is unreachable"})
             )

    evidence = operation_evidence_record(observation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered

                   assert [%AI.Condition{failed_observation_ids: [evidence_id]}] =
                            request.conditions

                   assert evidence_id == evidence.id

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Handoff{
                        reason: "The current Linux observation failed",
                        required_input: "Investigate the host"
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result["outcome"] == "decision"
    refute completed.result["outcome"] == "context_changed"
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
  end

  test "a recovered Signal with a still-failing Target observation persists a nonterminal assessment",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, _signal_provider} =
      authorized_proposal!("still-failing-assessment", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "inactive"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered
                   assert [%AI.Condition{} = condition] = request.conditions
                   assert evidence.id in condition.recovery_evidence_ids

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Handoff{
                        reason: "Service remains inactive despite monitoring recovery",
                        required_input: "Check the monitoring rule and service"
                      },
                      condition_assessments: [
                        %{
                          "condition_id" => condition.id,
                          "revision" => condition.revision,
                          "status" => "still_failing",
                          "evidence_ids" => [evidence.id],
                          "reason" => "Direct service inspection reports inactive"
                        }
                      ],
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)

    assert [%{"status" => "still_failing", "evidence_ids" => [evidence_id]}] =
             completed.result["condition_assessments"]

    assert [%{"status" => "still_failing"}] =
             OpsondeWeb.API.V1.WorkflowJSON.turn(completed).condition_assessments

    assert evidence_id == evidence.id

    assert Cases.route_downstream_decision!(completed.id, authorize?: false).status ==
             :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a recovered Signal with a cited current failing observation admits an effect proposal",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, observation_proposal, _signal_provider} =
      authorized_proposal!("premature-recovery-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "inactive"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(observation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    {:ok, [condition]} = ConditionContext.current_conditions(current)

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}
    effect_intent = signal_proposal_intent(evidence.id, context)

    assert {:ok, true} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               [evidence.id],
               effect_intent
             )

    assert {:ok, false} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               ["unrelated"],
               effect_intent
             )

    unrelated_service = Map.put(effect_intent, "selectors", %{"unit" => "other.service"})

    assert {:ok, false} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               [evidence.id],
               unrelated_service
             )

    proposal =
      effect_intent
      |> Map.put("affected_conditions", [claim])
      |> then(&complete_signal_proposal!(turn, &1, current, context))

    assert proposal.request_kind == :effect
    assert proposal.evidence_ids == [evidence.id]
    assert proposal.affected_conditions == [claim]

    effect = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(effect.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert Cases.get_operation!(effect.id, authorize?: false).status == :applied

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a manual Case can conclude from a real current-run Target observation", context do
    {incident, run, proposal} =
      authorized_proposal!("manual-observation-recovery", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :not_applicable
                   assert AI.recovery_evidence_ids(request) == [evidence.id]

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The requested service is active after direct inspection",
                        evidence_ids: [evidence.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => evidence.id,
                            "fact_keys" => ["active_state"],
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    requested = Cases.route_downstream_decision!(turn.id, authorize?: false)
    assert requested.status == :running
    approve_recovery!(turn, context)
    resolved = Cases.get_case!(incident.id, authorize?: false)
    assert resolved.status == :resolved
    assert %DateTime{} = resolved.resolved_at
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :completed
  end

  test "an interrupted Recovery Reviewer is charged once and cannot approve on replay", context do
    {incident, run, proposal} =
      authorized_proposal!("interrupted-recovery-review", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(operation, %{
               "unit" => "api.service",
               "active_state" => "active"
             })

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The service is active in a direct observation",
                        evidence_ids: [evidence.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => evidence.id,
                            "fact_keys" => ["active_state"],
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent["action"] ==
             "review_recovery"

    before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
    selection = Providers.select_reviewer_ai!([], authorize?: false)
    current = Cases.get_case!(incident.id, authorize?: false)
    completed = Cases.get_turn!(turn.id, authorize?: false)

    claim =
      Cases.claim_ai_invocation!(
        :reviewer,
        incident.id,
        current.revision,
        run.id,
        turn.id,
        completed.revision,
        nil,
        nil,
        selection.provider_id,
        selection.assignment_id,
        selection.provider_revision,
        selection.assignment_revision,
        selection.source,
        Opsonde.Cases.AIInvocation.request_digest({turn.id, :simulated_interruption}),
        1,
        authorize?: false
      )

    assert claim.state == :claimed

    assert :ok =
             Opsonde.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ -> flunk("interrupted review was sent again") end
               }
             )

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Recovery Reviewer response is unknown"

    [reviewer] =
      Enum.filter(Cases.list_ai_invocations!(authorize?: false), fn invocation ->
        invocation.case_id == incident.id and invocation.role == :reviewer
      end)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + reviewer.reserved_units

    refute Enum.any?(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "case_resolved"
           end)
  end

  test "Case admission rejects a manual recovery claim for a fact absent from current Evidence",
       context do
    {incident, _run, proposal} =
      authorized_proposal!("manual-missing-fact", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"active_state" => "active"},
                      evidence: []
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" => %{
            "type" => "recovery_conclusion",
            "reason" => "The service is active",
            "evidence_ids" => [evidence.id],
            "condition_claims" => [],
            "desired_outcome_claims" => [
              %{
                "symptom_id" => Opsonde.Cases.Case.Symptom.current(current).id,
                "evidence_id" => evidence.id,
                "fact_keys" => ["unobserved_state"],
                "reason" => "Claimed state"
              }
            ]
          }
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, error} = Cases.route_downstream_decision(completed.id, authorize?: false)
    assert Exception.message(error) =~ "Case symptom claim"
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a resumed recovered Signal Case keeps a still-current prior-run observation eligible",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("resumed-recovered-observation", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "fresh after monitoring recovery"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending.id,
        pending.revision,
        current_run.id,
        current_run.revision,
        "pause-before-current-proof:#{incident.id}",
        "Interrupt Resolver after fresh observation",
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
        "Continue with still-current symptom evidence",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert Opsonde.Cases.Evidence.Citation.valid?(
             evidence,
             Cases.get_case!(incident.id, authorize?: false),
             resumed_run
           )

    assert :ok =
             ResolverDelivery.run(resumed_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert AI.recovery_evidence_ids(request) == [evidence.id]
                   assert Enum.any?(request.evidence, &(&1.id == evidence.id))
                   refute Enum.any?(request.historical_evidence, &(&1.id == evidence.id))
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The native symptom cleared and the selected service is active",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The observed service is active after source recovery"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(resumed_turn.id, authorize?: false)
    assert Cases.route_downstream_decision!(completed.id, authorize?: false).status == :running
    approve_recovery!(completed, context)
    assert Cases.get_case!(incident.id, authorize?: false).status == :resolved
  end

  test "a resumed Signal Case can cite current prior-run observation to request a fresh observation",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("resumed-observation-citation", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "current source symptom"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        current.id,
        current.revision,
        current_run.id,
        current_run.revision,
        "pause-before-new-observation:#{incident.id}",
        "Continue direct observation after resume",
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
        "Request a fresh symptom observation",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    intent = signal_proposal_intent(evidence.id, context, :observation)
    routed = complete_signal_proposal!(resumed_turn, intent, incident, context)

    assert routed.evidence_ids == [evidence.id]
    assert routed.resolution_run_id == resumed_run.id
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a Reviewer rejection of unrelated observation facts keeps recovered Signal Conditions open",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("unrelated-recovery-proof", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"machine_id" => "unrelated-machine", "kernel" => "6.8"},
                      evidence: [%{"check" => "host identity only"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "Machine identity proves service recovered",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "Machine identity proves service is running"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    assert requested.pending_intent["action"] == "review_recovery"

    assert :ok =
             Opsonde.Cases.Turn.RecoveryReviewDelivery.run(completed.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert [%AI.Evidence{content: %{"facts" => facts}}] =
                            request.cited_evidence

                   assert facts["machine_id"] == "unrelated-machine"

                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :rejected,
                      reason: "Machine identity does not establish service availability",
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review_recovery, %{model: "reviewer-model"}, _request}
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running
    assert current.pending_intent["action"] == "resolve_turn"
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )

    assert :ok = Opsonde.Cases.Turn.RecoveryReviewDelivery.run(completed.id)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             current.pending_intent

    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "uncited-identity-after-rejection:#{incident.id}",
      "observation",
      "fixture",
      "uncited-identity:#{incident.id}",
      %{
        "target_id" => context.target.id,
        "operation" => "linux.identity.inspect",
        "status" => "applied",
        "facts" => %{"kernel" => "Linux"}
      },
      DateTime.utc_now(),
      authorize?: false
    )

    retry_turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(retry_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert %{
                            "last_rejected_recovery_review" => %{
                              "verdict" => "rejected",
                              "evidence_ids" => [rejected_id],
                              "reason" => review_reason
                            }
                          } = Jason.decode!(request.objective)

                   assert rejected_id == evidence.id
                   assert review_reason =~ "Machine identity does not establish"
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The same machine identity appears to show recovery",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The same identity observation is cited"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    stopped = Cases.route_downstream_decision!(retry_turn.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Recovery Review rejected this unchanged evidence"

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "recovery_review_decided"
           end) == 1

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        stopped.id,
        stopped.revision,
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
        "Continue investigation with Reviewer feedback",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert {:ok, request} =
             ResolverProjection.build(
               resumed_turn.id,
               %AI.Selection{
                 role: :resolver,
                 provider_id: context.resolver_provider.id,
                 provider_revision: context.resolver_provider.revision,
                 source: :assignment
               },
               invocation({:ok, %Target.Capabilities{observations: [], effects: []}})
             )

    assert get_in(Jason.decode!(request.objective), [
             "last_rejected_recovery_review",
             "evidence_ids"
           ]) == [evidence.id]

    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    proposal =
      complete_signal_proposal!(
        resumed_turn,
        signal_proposal_intent(source.id, context, :observation),
        incident,
        context
      )

    observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(observation, %{
               "unit" => "api.service",
               "active_state" => "active"
             })

    fresh = operation_evidence_record(observation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    fresh_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(fresh_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert fresh.id in request.recovery_evidence_ids
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The service is active in a fresh direct observation",
                        evidence_ids: [fresh.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => fresh.id,
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(fresh_turn.id, authorize?: false).pending_intent[
             "action"
           ] == "review_recovery"

    approve_recovery!(fresh_turn, context)

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "recovery_review_decided"
           end) == 2
  end

  test "a missing recovery Reviewer stops a manual Case without claiming resolution", context do
    {incident, run, proposal} =
      authorized_proposal!("missing-recovery-reviewer", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The current service is active",
                        evidence_ids: [evidence.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => evidence.id,
                            "fact_keys" => ["active_state"],
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent ==
             %{"action" => "review_recovery", "turn_id" => turn.id}

    Providers.disable_provider!(
      context.reviewer_provider,
      context.reviewer_provider.revision,
      actor: context.admin
    )

    assert :ok = Opsonde.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id}
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a new firing Condition invalidates a pending recovery review", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("stale-recovery-review", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "before refire"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The service was active at the prior observation",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The prior service inspection was active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent ==
             %{"action" => "review_recovery", "turn_id" => turn.id}

    fire_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "refired-before-recovery-review",
      DateTime.add(DateTime.utc_now(), 1, :second)
    )

    assert :ok = Opsonde.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and
                 &1.event_type in ["recovery_review_decided", "case_resolved"])
           )
  end

  test "a resumed firing Case receives verified continuity without stale observations",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("resume-investigation", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "resume-investigation-stale-source",
      DateTime.add(DateTime.utc_now(), -60, :second)
    )

    signal_event!(
      signal_provider,
      context,
      event_key,
      "resume-investigation-current-source",
      :firing,
      DateTime.utc_now(),
      %{
        "labels" => %{"service" => "api.service", "alertname" => "ServiceUnavailable"},
        "annotations" => %{"description" => "Restore the service to running"}
      }
    )

    [source] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    assert {:error, stale} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Exception.message(stale) =~ "Conditions changed"
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0

    [reassessment] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    replacement =
      Cases.complete_turn!(
        reassessment.id,
        reassessment.revision,
        %{
          "outcome" => "decision",
          "intent" =>
            Map.put(
              signal_proposal_intent(source.id, context),
              "affected_conditions",
              Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
                %{"condition_id" => id, "revision" => revision}
              end)
            ),
          "condition_revisions" => revisions,
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => reassessment.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(replacement.id, authorize?: false)
    authorized = Cases.proposal_by_source_turn!(replacement.id, authorize?: false)

    operation = Cases.accept_operation!(authorized.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
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
             %AI.Evidence{id: source_id, kind: "signal_event", content: source_content},
             %AI.Evidence{id: ^verification_id, kind: "target_verification"}
           ] = request.evidence

    assert source_id == source.id
    refute Enum.any?(request.evidence, &(&1.content["state"] == "recovered"))
    assert Enum.any?(request.historical_evidence, &(&1.kind == "operation_outcome"))
    refute Enum.any?(request.historical_evidence, &(&1.id == verification_id))

    assert get_in(source_content, ["attributes", "annotations", "description"]) ==
             "Restore the service to running"

    assert [%AI.ProposalTool{request_kind: :observation}] = request.proposal_tools
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

  defp complete_signal_proposal!(turn, intent, incident, context) do
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" => intent,
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

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    Cases.proposal_by_source_turn!(completed.id, authorize?: false)
  end

  defp deliver_observation(operation, facts, state_facts \\ nil) do
    OperationDelivery.run(operation.id,
      target_invocation:
        invocation({
          :ok,
          %Target.Observation{
            facts: facts,
            state_facts: state_facts,
            observed_at: DateTime.utc_now()
          }
        })
    )
  end

  defp continue_observation!(incident, context, prior_operation_id) do
    evidence = operation_evidence_record(prior_operation_id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    result = %{
      "outcome" => "decision",
      "intent" => proposal_intent(evidence.id, context, :observation),
      "resolver" => %{
        "provider_id" => context.resolver_provider.id,
        "provider_revision" => context.resolver_provider.revision,
        "assignment_id" => context.resolver_assignment.id,
        "assignment_revision" => context.resolver_assignment.revision
      },
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        result,
        :observation_pending,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    proposal = Cases.proposal_by_source_turn!(completed.id, authorize?: false)
    Cases.accept_operation!(proposal.id, authorize?: false)
  end

  defp authorized_proposal!(suffix, context, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, :manual)
    request_kind = Keyword.get(opts, :request_kind, :effect)
    proposal_context = Map.put(context, :service, Keyword.get(opts, :service, "api"))

    {incident, signal_provider} =
      if trigger_kind == :signal do
        signal_case!(suffix, context, opts)
      else
        {Cases.open_case!(
           trigger_kind,
           "test",
           "operation-#{suffix}",
           "Operation #{suffix}",
           :warning,
           %{"desired_outcome" => "Target responds as expected"},
           context.target.id,
           :en,
           actor: context.operator
         ), nil}
      end

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
      if trigger_kind == :signal do
        assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
        %{value: Enum.find(Cases.list_turns!(actor: context.admin), &(&1.case_id == incident.id))}
      else
        Cases.start_turn!(
          incident.id,
          run.id,
          "operation-turn-#{suffix}",
          Keyword.get(opts, :turn_intent, %{"objective" => "Restore the service"}),
          %{"action" => "continue"},
          "Review Resolver limits",
          authorize?: false
        )
      end

    if trigger_kind == :signal and Keyword.get(opts, :recover_before_proposal, false) do
      recover_signal!(
        signal_provider,
        context,
        incident.initial_context["signal_event_key"],
        "recovered-before-#{suffix}"
      )
    end

    result =
      %{
        "outcome" => "decision",
        "intent" =>
          if(trigger_kind == :signal,
            do: signal_proposal_intent(evidence.id, proposal_context, request_kind),
            else: proposal_intent(evidence.id, proposal_context, request_kind)
          ),
        "resolver" => %{
          "provider_id" => context.resolver_provider.id,
          "provider_revision" => context.resolver_provider.revision,
          "assignment_id" => context.resolver_assignment.id,
          "assignment_revision" => context.resolver_assignment.revision
        },
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

    result =
      if trigger_kind == :signal do
        {:ok, revisions} = ConditionContext.current_condition_revisions(incident)
        result = Map.put(result, "condition_revisions", revisions)

        if request_kind == :effect do
          affected_event_key = Keyword.get(opts, :affected_event_key)

          affected_correlation_ids =
            Signals.list_signal_correlations!(actor: context.admin)
            |> Enum.filter(&(&1.event_key == affected_event_key))
            |> MapSet.new(& &1.id)

          conditions_by_id =
            Signals.list_conditions!(actor: context.admin) |> Map.new(&{&1.id, &1})

          claims =
            revisions
            |> Enum.filter(fn %{"id" => id} ->
              is_nil(affected_event_key) or
                MapSet.member?(
                  affected_correlation_ids,
                  Map.fetch!(conditions_by_id, id).signal_correlation_id
                )
            end)
            |> Enum.map(fn %{"id" => id, "revision" => revision} ->
              %{"condition_id" => id, "revision" => revision}
            end)

          put_in(result, ["intent", "affected_conditions"], claims)
        else
          result
        end
      else
        result
      end

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    authorized = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    if signal_provider,
      do: {incident, run, authorized, signal_provider},
      else: {incident, run, authorized}
  end

  defp signal_proposal_intent(evidence_id, context, kind \\ :effect)

  defp signal_proposal_intent(evidence_id, context, :effect) do
    proposal_intent(evidence_id, context)
    |> put_in(["tool", "operation"], "linux.service.restart")
    |> put_in(["verification_tool", "operation"], "linux.service.inspect")
    |> Map.put("operation", "linux.service.restart")
    |> Map.put("selectors", %{"unit" => "api.service"})
    |> Map.put("expected_result", %{"active_state" => "active"})
    |> put_in(["verification_intent", "selectors"], %{"unit" => "api.service"})
    |> put_in(["verification_intent", "expected_result"], %{"active_state" => "active"})
  end

  defp signal_proposal_intent(evidence_id, context, :observation) do
    proposal_intent(evidence_id, context, :observation)
    |> put_in(["tool", "operation"], "linux.service.inspect")
    |> Map.put("operation", "linux.service.inspect")
    |> Map.put("selectors", %{"unit" => "api.service"})
    |> Map.put("parameters", %{"unit" => "api.service"})
  end

  defp proposal_intent(evidence_id, context),
    do: proposal_intent(evidence_id, context, :effect)

  defp proposal_intent(evidence_id, context, :effect) do
    service = Map.get(context, :service, "api")

    tool = %{
      "request_kind" => "effect",
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
      "request_kind" => "effect",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => service},
      "parameters" => %{"service" => service},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => tool,
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => service},
        "parameters" => %{"service" => service},
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

  defp proposal_intent(evidence_id, context, :observation) do
    service = Map.get(context, :service, "api")

    tool = %{
      "request_kind" => "observation",
      "id" => "observation-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "observe.service",
      "operation" => "service.inspect"
    }

    %{
      "type" => "proposal",
      "request_kind" => "observation",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => service},
      "parameters" => %{"service" => service},
      "reason" => "Inspect the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{},
      "tool" => tool,
      "verification_intent" => %{},
      "verification_tool" => %{}
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

  defp separate_target!(context, suffix) do
    name = "operation-#{suffix}"
    target = Targets.create_target!(name, "host", "linux", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        context.provider.id,
        "method-#{suffix}",
        "linux",
        "ssh",
        "ssh://#{name}",
        context.provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: context.admin
      )

    %{context | target: target, method: method}
  end

  defp verified_result(facts) do
    %Target.Verification{
      status: :verified,
      observed_at: DateTime.utc_now(),
      facts: facts,
      evidence: [%{"check" => "fresh"}]
    }
  end

  defp signal_provider!(incident, context) do
    Providers.create_provider!(
      "signal-#{incident.id}",
      :signal,
      "fixture-signal",
      %{"source" => incident.source},
      %{"secret" => "signal-secret"},
      actor: context.admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))
  end

  defp signal_case!(suffix, context, opts) do
    provider = signal_provider!(%{id: suffix, source: "test"}, context)

    Targets.create_external_identity!(
      context.target.id,
      "test",
      "hostname",
      context.target.name,
      actor: context.admin
    )

    fire_signal!(
      provider,
      context,
      "operation-#{suffix}",
      "initial-#{suffix}",
      DateTime.add(DateTime.utc_now(), -10, :second)
    )

    if additional = Keyword.get(opts, :additional_event_key) do
      signal_event!(
        provider,
        context,
        additional,
        "additional-#{suffix}",
        :firing,
        DateTime.add(DateTime.utc_now(), -9, :second),
        %{
          "labels" => %{
            "service" => Keyword.get(opts, :additional_subject, "api.service"),
            "alertname" => "ServiceUnavailable"
          }
        }
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    {incident, provider}
  end

  defp fire_signal!(provider, context, event_key, receipt_id, now) do
    signal_event!(provider, context, event_key, receipt_id, :firing, now)
  end

  defp recover_signal!(provider, context, event_key, receipt_id, now \\ DateTime.utc_now()) do
    signal_event!(provider, context, event_key, receipt_id, :recovered, now)
  end

  defp signal_event!(provider, context, event_key, receipt_id, state, now, attributes \\ nil) do
    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: receipt_id, headers: %{}, received_at: now},
      %{
        authenticate: fn state, _envelope ->
          {:ok, %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: state.source}}
        end,
        normalize: fn _state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: receipt_id,
               event_key: event_key,
               state: state,
               occurred_at: now,
               target_ref: %{kind: :hostname, value: context.target.name},
               attributes:
                 attributes ||
                   %{
                     "labels" => %{
                       "service" => "api.service",
                       "alertname" => "ServiceUnavailable"
                     }
                   }
             }
           ]}
        end
      },
      authorize?: false
    )
  end

  defp recovery_check_jobs(case_id) do
    Opsonde.Repo.all(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(SignalRecoveryCheckWorker) and
            fragment("?->>'case_id'", job.args) == ^case_id
      )
    )
  end

  defp approve_recovery!(turn, context, delivery_opts \\ []) do
    assert :ok =
             Opsonde.Cases.Turn.RecoveryReviewDelivery.run(
               turn.id,
               delivery_opts ++
                 [
                   ai_invocation: %{
                     test_pid: self(),
                     respond: fn request ->
                       assert request.case_id == turn.case_id
                       assert request.conclusion.evidence_ids != []

                       if delivery_opts != [],
                         do: assert(request.retry_context["category"] == "invalid_output")

                       assessment =
                         if request.case_symptom do
                           %{
                             "symptom_id" => request.case_symptom.id,
                             "desired_outcome" => request.case_symptom.desired_outcome,
                             "evidence_ids" =>
                               request.conclusion.desired_outcome_claims
                               |> Enum.map(& &1["evidence_id"])
                               |> Enum.uniq(),
                             "status" => "supported",
                             "reason" => "The claimed facts satisfy the desired outcome"
                           }
                         end

                       {:ok,
                        %AI.ReviewDecision{
                          verdict: :approved,
                          reason:
                            "The cited observation directly checks the stated service state",
                          desired_outcome_assessment: assessment,
                          usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                        }}
                     end
                   }
                 ]
             )

    assert_receive {:review_recovery, %{model: "reviewer-model"}, _request}
    assert Cases.get_case!(turn.case_id, authorize?: false).status == :resolved

    event =
      Cases.case_event_by_idempotency!(
        turn.case_id,
        Opsonde.Cases.ResolutionRun.Budget.key("recovery-review:result", turn.id),
        authorize?: false
      )

    invocation =
      Cases.ai_invocation_by_idempotency!(event.data["invocation_key"], authorize?: false)

    assert invocation.turn_id == turn.id
    assert invocation.status == :completed
    assert invocation.provider_id == context.reviewer_provider.id
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

  defp operation_evidence_record(operation_id) do
    Opsonde.Repo.one!(
      from(evidence in Opsonde.Cases.Evidence,
        where: evidence.idempotency_key == ^"operation:outcome:#{operation_id}"
      )
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

  defp report_jobs(case_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^Oban.Worker.to_string(GenerationWorker) and
          fragment("?->>'case_id'", job.args) == ^case_id
    )
    |> Opsonde.Repo.all()
  end
end
