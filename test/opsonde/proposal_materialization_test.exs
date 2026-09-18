defmodule Opsonde.ProposalMaterializationTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("proposal-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("proposal-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "proposal-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "proposal-target-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("proposal-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "proposal-ssh",
        "linux",
        "ssh",
        "ssh://proposal-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "exact accepted Proposal materializes once without dispatch", context do
    {incident, run, evidence, turn, intent} = proposal_turn!("exact", context)

    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert {:ok, duplicate} = Cases.materialize_proposal(turn.id, authorize?: false)

    assert duplicate.id == proposal.id
    assert duplicate.reserved_operation_id == proposal.reserved_operation_id
    assert duplicate.proposal_digest == proposal.proposal_digest
    assert proposal.status == :proposed
    assert proposal.preflight_status == :cleared
    assert proposal.case_id == incident.id
    assert proposal.resolution_run_id == run.id
    assert proposal.source_turn_id == turn.id
    assert proposal.target_id == context.target.id
    assert proposal.target_revision == context.target.revision
    assert proposal.access_method_id == context.method.id
    assert proposal.access_method_revision == context.method.revision
    assert proposal.provider_id == context.provider.id
    assert proposal.provider_revision == context.provider.revision
    assert proposal.tool_id == intent["tool_id"]
    assert proposal.evidence_ids == [evidence.id]
    assert proposal.selectors == intent["selectors"]
    assert proposal.parameters == intent["parameters"]
    assert proposal.verification_intent == intent["verification_intent"]
    assert proposal.verification_tool == intent["verification_tool"]
    assert proposal.expires_at == run.deadline_at
    assert byte_size(proposal.proposal_digest) == 64
    assert proposal.preflight_context["provider_id"] == context.provider.id
    assert is_binary(proposal.preflight_context["clearance_digest"])
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "TargetPolicy denial is a durable blocked Proposal under the Case mode", context do
    Targets.create_target_policy!(
      context.target.id,
      "protect-api",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "API restart is forbidden",
      actor: context.admin
    )

    {incident, run, _evidence, turn, _intent} = proposal_turn!("denied", context)

    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert proposal.status == :blocked
    assert proposal.preflight_status == :blocked
    assert proposal.preflight_context["category"] == "denied"
    assert proposal.preflight_reason == "API restart is forbidden"
    assert {:ok, routed} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert routed.status == :blocked
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "foreign Evidence and revoked owner authority fail without a Proposal", context do
    {incident, run} = open_case!("foreign-source", context)
    {other_case, other_run} = open_case!("foreign-evidence", context)
    foreign = evidence!(other_case, other_run, "foreign")
    turn = completed_turn!(incident, run, "foreign", proposal_intent(foreign.id, context))

    assert {:error, _error} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []

    own = evidence!(incident, run, "revoked")
    revoked_turn = completed_turn!(incident, run, "revoked", proposal_intent(own.id, context))
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} = Cases.materialize_proposal(revoked_turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []
  end

  test "a changed Access Method records stale preflight and preserves the offered revisions",
       context do
    {_incident, run, _evidence, turn, _intent} = proposal_turn!("stale-method", context)

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: context.method.priority + 1},
      actor: context.admin
    )

    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert proposal.status == :blocked
    assert proposal.preflight_context["category"] == "stale_context"
    assert proposal.access_method_revision == context.method.revision
    assert proposal.provider_revision == context.provider.revision
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  test "an elapsed ResolutionRun cannot materialize a stale Proposal", context do
    {_incident, run, _evidence, turn, _intent} = proposal_turn!("expired", context)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Opsonde.Repo.update_all(
      from(item in Opsonde.Cases.ResolutionRun, where: item.id == ^run.id),
      set: [deadline_at: past]
    )

    assert {:error, _error} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  defp proposal_turn!(suffix, context) do
    {incident, run} = open_case!(suffix, context)
    evidence = evidence!(incident, run, suffix)
    intent = proposal_intent(evidence.id, context)
    turn = completed_turn!(incident, run, suffix, intent)
    {incident, run, evidence, turn, intent}
  end

  defp open_case!(suffix, context) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "proposal-#{suffix}",
        "Proposal #{suffix}",
        :warning,
        :not_applicable,
        %{},
        context.target.id,
        :en,
        actor: context.operator
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "proposal-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp completed_turn!(incident, run, suffix, intent) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "proposal-turn-#{suffix}",
        %{"objective" => "Restore the service"},
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
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp proposal_intent(evidence_id, context) do
    %{
      "type" => "proposal",
      "tool_id" => "effect-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "id" => "effect-tool",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
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

  defp resolver_identity do
    %{
      "provider_id" => Ash.UUID.generate(),
      "provider_revision" => 1,
      "assignment_id" => Ash.UUID.generate(),
      "assignment_revision" => 1
    }
  end
end
