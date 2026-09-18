defmodule Opsonde.ProposalAuthorityTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}

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

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
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
    assert Cases.get_resolution_run!(auto_run.id, authorize?: false).effect_count == 0
    refute_receive {:review, _, _}
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

  defp proposal!(suffix, context) do
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

    intent = proposal_intent(evidence.id, context)

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
          "intent" => intent,
          "resolver" => %{
            "provider_id" => Ash.UUID.generate(),
            "provider_revision" => 1,
            "assignment_id" => Ash.UUID.generate(),
            "assignment_revision" => 1
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
end
