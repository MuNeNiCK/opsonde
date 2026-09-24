defmodule Opsonde.ProposalAuthorityTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}

  alias Opsonde.Cases.{
    OperationAcceptanceWorker,
    OperationWorker,
    ReviewDelivery,
    ReviewProjection,
    ReviewWorker
  }

  alias Opsonde.Providers.AI
  alias Opsonde.Providers.Target, as: ProviderTarget

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("authority-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("authority-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "authority-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "authority-target-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("authority-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "authority-ssh",
        "linux",
        "ssh",
        "ssh://authority-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    resolver_provider = ai_provider!(admin, "authority-resolver", "resolver-model")

    resolver_assignment =
      Providers.create_ai_usage_role_assignment!(resolver_provider.id, :resolver, 10,
        actor: admin
      )

    reviewer_provider = ai_provider!(admin, "authority-reviewer", "reviewer-model")

    reviewer_assignment =
      Providers.create_ai_usage_role_assignment!(reviewer_provider.id, :reviewer, 10,
        actor: admin
      )

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment,
      reviewer_provider: reviewer_provider,
      reviewer_assignment: reviewer_assignment
    }
  end

  test "Readonly records a recommendation and pauses without Approval or effect", context do
    {incident, run, proposal} = proposal!("readonly", context)

    assert {:ok, recommended} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert {:ok, duplicate} = Cases.route_proposal_authority(proposal.id, authorize?: false)

    assert recommended.status == :recommended
    assert duplicate.id == recommended.id
    assert Cases.list_approvals!(actor: context.admin) == []

    paused_case = Cases.get_case!(incident.id, authorize?: false)
    assert paused_case.status == :needs_attention

    assert paused_case.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "Readonly observation uses the same approval and durable Operation path", context do
    {incident, run, proposal} = proposal!("readonly-observation", context, :observation)

    assert {:ok, authorized} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert authorized.status == :authorized

    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :readonly
    assert approval.decision == :approved

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.request_kind == :observation

    observed_at = DateTime.utc_now()

    assert :ok =
             Opsonde.Cases.OperationDelivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok,
                    %ProviderTarget.Observation{
                      facts: %{"status" => "degraded", "detail" => "disk latency"},
                      observed_at: observed_at
                    }}
                 end
               }
             )

    assert_receive {:observe, _state, %{operation: "service.inspect"}}
    refute_receive {:effect, _, _}
    assert Cases.verification_attempts_for_case!(incident.id, actor: context.admin) == []

    [evidence] =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.filter(&(&1.source_ref == operation.id))

    assert evidence.kind == "observation"

    assert evidence.content["facts"] == %{
             "status" => "degraded",
             "detail" => "disk latency"
           }

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.pending_intent["action"] == "resolve_turn"
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  test "Ask approval is exact, immutable, retryable and only exposes a dispatch reference",
       context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("ask-approve", context)

    assert {:ok, waiting} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert waiting.status == :awaiting_human
    assert Cases.list_approvals!(actor: context.admin) == []

    assert {:ok, authorized} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "The evidence supports this exact restart",
               actor: context.operator
             )

    assert {:ok, duplicate} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "The evidence supports this exact restart",
               actor: context.operator
             )

    assert duplicate.id == authorized.id
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.decision == :approved
    assert approval.source == :human
    assert approval.actor_id == context.operator.id
    assert approval.actor_role_version == context.operator.role_version
    assert approval.proposal_digest == waiting.proposal_digest
    assert byte_size(approval.clearance_digest) == 64

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "dispatch_operation",
             "approval_id" => approval.id,
             "operation_id" => proposal.reserved_operation_id,
             "proposal_id" => proposal.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert acceptance_jobs(proposal.id) == 1

    acceptance_job = %Oban.Job{args: %{"proposal_id" => proposal.id}}
    assert :ok = OperationAcceptanceWorker.perform(acceptance_job)
    assert :ok = OperationAcceptanceWorker.perform(acceptance_job)

    [operation] = Cases.list_operations!(actor: context.admin)
    assert operation.proposal_id == proposal.id
    assert operation.id == proposal.reserved_operation_id
    assert operation_jobs(operation.id) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               authorized.revision,
               waiting.proposal_digest,
               :rejected,
               "Opposite decision",
               actor: context.operator
             )

    refute_receive {:effect, _, _}
  end

  test "Ask rejection records one decision and starts one new Resolver Turn", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("ask-reject", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    initial_turn_count = length(Cases.list_turns!(actor: context.admin))

    rejected =
      Cases.decide_proposal!(
        waiting.id,
        waiting.revision,
        waiting.proposal_digest,
        :rejected,
        "Try a non-disruptive alternative",
        actor: context.operator
      )

    duplicate =
      Cases.decide_proposal!(
        waiting.id,
        waiting.revision,
        waiting.proposal_digest,
        :rejected,
        "Try a non-disruptive alternative",
        actor: context.operator
      )

    assert rejected.status == :rejected
    assert duplicate.id == rejected.id
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.decision == :rejected
    assert approval.source == :human
    assert is_nil(approval.clearance_digest)

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == initial_turn_count + 1
    reconsideration = Enum.max_by(turns, & &1.ordinal)
    assert reconsideration.intent["rejected_proposal_id"] == proposal.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "proposal_id" => proposal.id,
             "rejected_proposal_id" => proposal.id,
             "turn_id" => reconsideration.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "FullAccess leaves a mode Approval while Auto only waits for Reviewer", context do
    configure_mode!(:full_access, context.admin)
    {full_case, full_run, full_proposal} = proposal!("full", context)

    authorized = Cases.route_proposal_authority!(full_proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :full_access
    assert approval.actor_id == context.operator.id

    assert Cases.get_case!(full_case.id, authorize?: false).pending_intent["action"] ==
             "dispatch_operation"

    assert Cases.get_resolution_run!(full_run.id, authorize?: false).effect_count == 0
    assert acceptance_jobs(full_proposal.id) == 1
    refute_receive {:effect, _, _}

    configure_mode!(:auto, context.admin)
    {auto_case, auto_run, auto_proposal} = proposal!("auto", context)
    reviewing = Cases.route_proposal_authority!(auto_proposal.id, authorize?: false)

    assert reviewing.status == :reviewing

    assert Cases.get_case!(auto_case.id, authorize?: false).pending_intent == %{
             "action" => "review_proposal",
             "proposal_digest" => auto_proposal.proposal_digest,
             "proposal_id" => auto_proposal.id
           }

    assert length(Cases.list_approvals!(actor: context.admin)) == 1
    assert review_jobs(auto_proposal.id) == 1
    assert acceptance_jobs(auto_proposal.id) == 0
    assert Cases.get_resolution_run!(auto_run.id, authorize?: false).effect_count == 0
    refute_receive {:review, _, _}
  end

  test "Auto accepts one isolated assigned Reviewer decision and usage", context do
    configure_mode!(:auto, context.admin)

    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    {incident, run, proposal} = proposal!("review-approved", %{context | operator: operator})

    source_evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-source-#{proposal.id}",
        "signal_event",
        "alertmanager",
        incident.source_ref,
        %{
          "state" => "firing",
          "attributes" => %{
            "annotations" => %{
              "description" =>
                "Restore the exact value opsonde-dedicated-validation even when explanatory text is truncated"
            }
          }
        },
        DateTime.utc_now(),
        authorize?: false
      )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    response = %AI.ReviewDecision{
      verdict: :approved,
      reason: "The exact effect follows the cited evidence",
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    invocation = %{
      test_pid: self(),
      respond: fn request ->
        key = Opsonde.Cases.Budget.key("proposal:reviewer_assignment", proposal.id)
        event = Cases.case_event_by_idempotency!(incident.id, key, authorize?: false)
        assert event.data["provider_id"] == context.reviewer_provider.id
        assert event.data["assignment_id"] == context.reviewer_assignment.id
        assert request.session_id == "reviewer:#{proposal.id}"
        assert request.resolver_session_id == "resolver:#{run.id}"
        assert request.report_language == :ja
        refute request.session_id == request.resolver_session_id
        assert request.proposal.tool_id == proposal.tool_id
        assert Enum.map(request.source_evidence, & &1.id) == [source_evidence.id]

        assert get_in(hd(request.source_evidence).content, [
                 "attributes",
                 "annotations",
                 "description"
               ]) =~
                 "opsonde-dedicated-validation"

        refute request.objective =~ proposal.reason
        assert Enum.map(request.cited_evidence, & &1.id) == proposal.evidence_ids
        {:ok, response}
      end
    }

    assert :ok = ReviewDelivery.run(reviewing.id, ai_invocation: invocation)
    assert_receive {:review, %{model: "reviewer-model"}, _request}

    [decision] = Cases.list_review_decisions!(actor: context.admin)
    assert decision.outcome == :decision
    assert decision.verdict == :approved
    assert decision.selection_source == :assignment
    assert decision.provider_id == context.reviewer_provider.id
    assert decision.proposal_digest == proposal.proposal_digest
    assert decision.session_id != decision.resolver_session_id

    authorized = Cases.get_proposal!(proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :reviewer
    assert approval.proposal_digest == proposal.proposal_digest
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5

    [record] = Cases.list_ai_invocations!(authorize?: false)
    assert record.status == :completed
    assert record.input_tokens == 3
    assert record.output_tokens == 2

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "dispatch_operation"

    assert acceptance_jobs(proposal.id) == 1

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{respond: fn _ -> flunk("accepted review called AI twice") end}
             )

    refute_receive {:review, _, _}
    assert acceptance_jobs(proposal.id) == 1
    refute_receive {:effect, _, _}
  end

  test "Auto Reviewer accepts cited Case evidence preserved from a prior generation", context do
    configure_mode!(:auto, context.admin)

    setting = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      setting.setting_revision,
      setting.authority_mode,
      true,
      setting.max_elapsed_seconds,
      setting.max_resolver_turns,
      setting.max_target_requests,
      setting.max_effects,
      setting.max_related_targets,
      setting.max_ai_usage_units,
      setting.max_no_progress_turns,
      "enable resumed Signal review",
      actor: context.admin
    )

    incident =
      Cases.open_case!(
        :signal,
        "test-monitor",
        "review-resumed-evidence",
        "Review resumed evidence",
        :warning,
        :firing,
        %{},
        context.target.id,
        :en,
        actor: context.operator
      )

    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    prior_evidence =
      Cases.append_evidence!(
        incident.id,
        first_run.id,
        nil,
        "review-prior-generation-evidence",
        "signal_event",
        incident.source,
        incident.source_ref,
        %{"current" => true, "state" => "recovered", "service" => "healthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    waiting =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "review-prior-generation-wait",
        "Resolver delivery failed",
        %{"action" => "retry_resolver"},
        "Retry Resolver delivery",
        authorize?: false
      )

    resumed =
      Cases.record_case_source_recovery!(waiting.id, waiting.revision, actor: context.operator)

    second_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert second_run.generation == 2
    [started] = Cases.started_turns_for_run!(second_run.id, authorize?: false)

    turn =
      Cases.complete_turn!(
        started.id,
        started.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(prior_evidence.id, context, :observation),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(turn.id, authorize?: false)

    reviewing =
      Cases.list_proposals!(authorize?: false)
      |> Enum.find(&(&1.source_turn_id == turn.id))

    assert reviewing.status == :reviewing

    selection = %AI.Selection{
      role: :reviewer,
      provider_id: context.reviewer_provider.id,
      provider_revision: context.reviewer_provider.revision,
      assignment_id: context.reviewer_assignment.id,
      assignment_revision: context.reviewer_assignment.revision,
      source: :assignment
    }

    assert {:ok, request} = ReviewProjection.build(reviewing.id, selection)
    assert resumed.status == :running
    assert Enum.map(request.cited_evidence, & &1.id) == [prior_evidence.id]
  end

  test "Auto uses isolated Resolver fallback and reconsiders a rejected proposal once", context do
    configure_mode!(:auto, context.admin)

    Providers.update_ai_usage_role_assignment!(
      context.reviewer_assignment,
      context.reviewer_assignment.revision,
      %{enabled: false},
      actor: context.admin
    )

    {incident, run, proposal} = proposal!("review-fallback", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    initial_turn_count = length(Cases.list_turns!(actor: context.admin))

    response = %AI.ReviewDecision{
      verdict: :rejected,
      reason: "Try a non-disruptive alternative",
      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
    }

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   refute request.session_id == request.resolver_session_id
                   {:ok, response}
                 end
               }
             )

    assert_receive {:review, %{model: "resolver-model"}, _request}
    [decision] = Cases.list_review_decisions!(actor: context.admin)
    assert decision.selection_source == :resolver_fallback
    assert decision.provider_id == context.resolver_provider.id

    rejected = Cases.get_proposal!(proposal.id, authorize?: false)
    assert rejected.status == :rejected
    assert Cases.list_approvals!(actor: context.admin) == []

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == initial_turn_count + 1
    reconsideration = Enum.max_by(turns, & &1.ordinal)
    assert reconsideration.intent["rejected_proposal_id"] == proposal.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "proposal_id" => proposal.id,
             "rejected_proposal_id" => proposal.id,
             "turn_id" => reconsideration.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 4

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{respond: fn _ -> flunk("rejected review called AI twice") end}
             )

    assert length(Cases.list_turns!(actor: context.admin)) == initial_turn_count + 1
    refute_receive {:effect, _, _}
  end

  test "Auto waits for an explicit needs_human verdict until source state changes", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-needs-human", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :needs_human,
                      reason: "The available evidence cannot establish the blast radius",
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, _request}

    waiting = Cases.get_proposal!(proposal.id, authorize?: false)
    assert waiting.status == :awaiting_human

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "decide_proposal"

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 4
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}

    current = Cases.get_case!(incident.id, authorize?: false)

    firing =
      Cases.update_case_record!(
        current,
        current.revision,
        %{alert_state: :firing, source_recovered_at: nil},
        authorize?: false
      )

    recovered =
      Cases.record_case_source_recovery!(firing.id, firing.revision, actor: context.operator)

    assert recovered.alert_state == :recovered
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert recovered.pending_intent["action"] == "resolve_turn"
    assert recovered.pending_intent["turn_id"] == turn.id
    assert recovered.pending_intent["superseded_proposal_id"] == proposal.id
  end

  test "source recovery supersedes an in-flight review and starts one fresh Resolver turn",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-source-recovery", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    parent = self()

    task =
      Task.async(fn ->
        ReviewDelivery.run(reviewing.id,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :reviewer_remote_started)

              receive do
                :release_reviewer ->
                  {:ok,
                   %AI.ReviewDecision{
                     verdict: :approved,
                     reason: "The old source state supported this Proposal",
                     usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                   }}
              end
            end
          }
        )
      end)

    assert_receive :reviewer_remote_started

    current = Cases.get_case!(incident.id, authorize?: false)

    firing =
      Cases.update_case_record!(
        current,
        current.revision,
        %{alert_state: :firing, source_recovered_at: nil},
        authorize?: false
      )

    recovered =
      Cases.record_case_source_recovery!(firing.id, firing.revision, actor: context.operator)

    send(task.pid, :release_reviewer)
    assert :ok = Task.await(task)

    assert recovered.alert_state == :recovered
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.list_approvals!(actor: context.admin) == []

    [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :failed
    assert invocation.category == "context_changed"

    started = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert length(started) == 1
    [turn] = started

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    assert pending["action"] == "resolve_turn"
    assert pending["turn_id"] == turn.id
    assert pending["source_state"] == "recovered"
    assert pending["superseded_proposal_id"] == proposal.id

    replayed =
      Cases.record_case_source_recovery!(firing.id, firing.revision, actor: context.operator)

    assert replayed.revision == recovered.revision
    assert length(Cases.started_turns_for_run!(run.id, authorize?: false)) == 1
    refute_receive {:effect, _, _}
  end

  test "Reviewer delivery retries remain autonomous and terminal failure stops the Case",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-timeout", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    for attempt <- 1..2 do
      assert {:error, message} =
               ReviewDelivery.run(reviewing.id,
                 delivery_attempt: attempt,
                 max_delivery_attempts: 3,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request -> {:error, :timeout, "review deadline exceeded"} end
                 }
               )

      assert message =~ "attempt #{attempt} of 3"
      assert_receive {:review, _, _}
      assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing
      assert Cases.get_case!(incident.id, authorize?: false).status == :running
      assert Cases.list_review_decisions!(actor: context.admin) == []
    end

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 3,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:error, :timeout, "review deadline exceeded"} end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "restore_reviewer_delivery"
    assert stopped.pending_intent["proposal_id"] == proposal.id
    assert stopped.stop_reason == "Reviewer delivery failed: Reviewer AI timed out"

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 196_608

    records = Cases.list_ai_invocations!(authorize?: false)
    assert length(records) == 3
    assert Enum.all?(records, &(&1.status == :failed and &1.category == "timeout"))
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  test "Reviewer schema rejection charges usage and never approves or disables the Provider",
       context do
    configure_mode!(:auto, context.admin)
    {_incident, run, proposal} = proposal!("review-schema-failover", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error, :invalid_output,
                    "AI provider JSON does not match the requested schema",
                    %AI.Usage{input_tokens: 7, output_tokens: 5}}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    refute_receive {:review, _, _}

    failed_provider = Providers.get_provider!(context.reviewer_provider.id, authorize?: false)
    assert failed_provider.enabled
    assert failed_provider.check_status == :passed

    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12

    assert [%{input_tokens: 7, output_tokens: 5, category: "invalid_output"}] =
             Cases.list_ai_invocations!(authorize?: false)
  end

  test "Reviewer schema contract failure stops after one call without an alternate AI", context do
    configure_mode!(:auto, context.admin)
    {_incident, run, proposal} = proposal!("review-schema-no-fallback", context)

    Providers.disable_provider!(
      context.resolver_provider,
      context.resolver_provider.revision,
      actor: context.admin
    )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error, :invalid_output,
                    "AI provider JSON does not match the requested schema"}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    refute_receive {:review, _, _}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
  end

  test "an interrupted Reviewer dispatch retries without a human approval request",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-interrupted", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    parent = self()

    task =
      Task.async(fn ->
        ReviewDelivery.run(reviewing.id,
          delivery_attempt: 1,
          max_delivery_attempts: 3,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :reviewer_remote_started)
              receive do: (:never -> :unreachable)
            end
          }
        )
      end)

    assert_receive {:review, _, _request}
    assert_receive :reviewer_remote_started
    assert nil == Task.shutdown(task, :brutal_kill)

    [dispatching] = Cases.list_ai_invocations!(authorize?: false)
    assert dispatching.role == :reviewer
    assert dispatching.status == :dispatching

    assert {:error, retry_reason} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("interrupted Reviewer called AI again") end
               }
             )

    assert retry_reason == "Reviewer response was lost on attempt 2 of 3"

    refute_receive {:review, _, _}

    [unknown] = Cases.list_ai_invocations!(authorize?: false)
    assert unknown.id == dispatching.id
    assert unknown.status == :unknown
    assert unknown.category == "response_unknown"
    assert unknown.reserved_units == 65_536

    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             unknown.reserved_units

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}

    response = %AI.ReviewDecision{
      verdict: :approved,
      reason: "The bounded retry recovered the independent review",
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 3,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:ok, response} end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
    assert [%{verdict: :approved}] = Cases.list_review_decisions!(actor: context.admin)
    assert [%{source: :reviewer}] = Cases.list_approvals!(actor: context.admin)

    records = Cases.list_ai_invocations!(authorize?: false)
    assert Enum.count(records, &(&1.status == :unknown)) == 1
    assert Enum.count(records, &(&1.status == :completed)) == 1

    events = Cases.list_case_events!(actor: context.admin)

    assert Enum.count(events, fn event ->
             event.data["request_key"] == "review-unknown:#{unknown.id}"
           end) == 1
  end

  test "Reviewer budget exhaustion stops the Case instead of requesting approval", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-budget", context)
    run = Cases.get_resolution_run!(run.id, authorize?: false)

    run =
      Cases.update_resolution_run_counters!(
        run,
        run.revision,
        %{ai_usage_units: run.max_ai_usage_units - 1},
        authorize?: false
      )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      reason: "The exact observation is safe",
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "review_ai_usage"

    assert stopped.required_human_input ==
             "Increase the AI usage limit or decide the Proposal manually"

    paused = Cases.get_resolution_run!(run.id, authorize?: false)
    assert paused.status == :needs_attention
    assert paused.ai_usage_units == run.max_ai_usage_units - 1

    [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :failed
    assert invocation.category == "budget_exhausted"
    assert {invocation.input_tokens, invocation.output_tokens} == {2, 2}
    assert Cases.list_approvals!(actor: context.admin) == []
  end

  test "stale Target context invalidates Ask approval and cannot be overridden", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("stale", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: context.method.priority + 1},
      actor: context.admin
    )

    assert {:ok, invalidated} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Approve only if the route is unchanged",
               actor: context.operator
             )

    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "FullAccess cannot override a Target Policy added after Proposal creation", context do
    configure_mode!(:full_access, context.admin)
    {incident, run, proposal} = proposal!("policy-change", context)

    Targets.create_target_policy!(
      context.target.id,
      "deny-api-restart",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "API restart is now forbidden",
      actor: context.admin
    )

    invalidated = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "expired input and revoked human authority fail without a decision", context do
    configure_mode!(:ask, context.admin)
    {_incident, _run, proposal} = proposal!("expired", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    Opsonde.Repo.update_all(
      from(item in Opsonde.Cases.Proposal, where: item.id == ^waiting.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Expired input must fail",
               actor: context.operator
             )

    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Revoked authority must fail",
               actor: context.operator
             )

    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  defp proposal!(suffix, context, request_kind \\ :effect) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "authority-#{suffix}",
        "Authority #{suffix}",
        :warning,
        :not_applicable,
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
        "authority-evidence-#{suffix}",
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
        "authority-turn-#{suffix}",
        %{"objective" => "Restore the service"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    intent = proposal_intent(evidence.id, context, request_kind)

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
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
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    {incident, run, proposal}
  end

  defp proposal_intent(evidence_id, context, :effect) do
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

  defp proposal_intent(evidence_id, context, :observation) do
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
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Inspect the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{},
      "tool" => tool,
      "verification_intent" => %{},
      "verification_tool" => %{}
    }
  end

  defp configure_mode!(mode, admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "test #{mode} Proposal routing",
      actor: admin
    )
  end

  defp ai_provider!(admin, name, model) do
    Providers.create_provider!(
      name,
      :ai,
      "fixture-ai",
      %{"model" => model},
      %{"api_key" => "#{name}-secret"},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp review_jobs(proposal_id) do
    Opsonde.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(ReviewWorker) and
            fragment("?->>'proposal_id'", job.args) == ^proposal_id
      ),
      :count
    )
  end

  defp acceptance_jobs(proposal_id) do
    Opsonde.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationAcceptanceWorker) and
            fragment("?->>'proposal_id'", job.args) == ^proposal_id
      ),
      :count
    )
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
end
