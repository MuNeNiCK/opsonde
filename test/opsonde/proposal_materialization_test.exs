defmodule Opsonde.ProposalMaterializationTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Targets.BMC.OperationKey

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

  test "a BMC secret reference reaches Proposal without plaintext in the Case", context do
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :full_access,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "BMC secret Proposal test",
      actor: context.admin
    )

    endpoint = "https://bmc.example.test:8443"

    target =
      Targets.create_target!("proposal-physical", "physical_host", "bare_metal", %{}, nil,
        actor: context.admin
      )

    bmc_provider =
      Providers.create_provider!(
        "proposal-bmc-provider",
        :target,
        "bmc-redfish",
        %{"endpoint" => endpoint},
        %{"username" => "admin", "password" => "test-only-provider-password"},
        actor: context.admin
      )

    checked =
      Providers.record_provider_check!(bmc_provider, bmc_provider.revision, :passed, nil, nil,
        authorize?: false
      )

    bmc_provider =
      Providers.enable_provider!(checked, checked.revision, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        bmc_provider.id,
        "redfish",
        "bare_metal",
        "redfish",
        endpoint,
        bmc_provider.revision,
        10,
        ["observe.power", "effect.bmc_api"],
        actor: context.admin
      )

    value = "test-only-password-value"
    secret = Targets.create_bmc_secret!(method.id, "next-password", value, actor: context.admin)

    definition =
      Targets.create_bmc_operation!(
        method.id,
        "Rotate manager password",
        "Rotate manager password using configured secret",
        :effect,
        %{"method" => "PATCH", "uri" => "/redfish/v1/Managers/1/Accounts/1"},
        %{
          "type" => "object",
          "properties" => %{
            "selectors" => %{"type" => "object", "additionalProperties" => false},
            "parameters" => %{"type" => "object", "additionalProperties" => false}
          },
          "required" => ["selectors", "parameters"],
          "additionalProperties" => false
        },
        %{"type" => "object"},
        nil,
        %{
          secret_bindings: %{"/Password" => %{"id" => secret.id, "revision" => secret.revision}},
          parameter_classes: %{"/Password" => "secret"}
        },
        actor: context.admin
      )

    bmc_context = %{context | target: target, method: method, provider: bmc_provider}
    {incident, run} = open_case!("bmc-secret", bmc_context)
    evidence = evidence!(incident, run, "bmc-secret")
    intent = proposal_intent(evidence.id, bmc_context)
    operation = OperationKey.format(definition)

    intent =
      intent
      |> Map.merge(%{
        "capability" => "effect.bmc_api",
        "operation" => operation,
        "parameters" => %{},
        "selectors" => %{},
        "reason" => "Rotate the manager password with the registered secret"
      })
      |> put_in(["tool", "capability"], "effect.bmc_api")
      |> put_in(["tool", "operation"], operation)

    turn = completed_turn!(incident, run, "bmc-secret", intent)
    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert proposal.status == :proposed
    assert proposal.parameters == %{}
    refute inspect(proposal) =~ value
    refute inspect(Cases.get_turn!(turn.id, authorize?: false)) =~ value

    authorized = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    assert authorized.status == :authorized

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.parameters == %{}
    refute inspect(operation) =~ value
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

  test "the current Signal Evidence remains available after a Case resumes", context do
    {_incident, _prior_run, resumed_run, current, _stale, resumed_turn} =
      resumed_signal_case!("current-signal", context)

    completed =
      complete_turn!(resumed_turn, proposal_intent(current.id, context))

    assert {:ok, proposal} = Cases.materialize_proposal(completed.id, authorize?: false)
    assert proposal.resolution_run_id == resumed_run.id
    assert proposal.evidence_ids == [current.id]
  end

  test "a stale Signal Evidence cannot cross a resumed Case generation", context do
    {_incident, _prior_run, _resumed_run, _current, stale, resumed_turn} =
      resumed_signal_case!("stale-signal", context)

    completed =
      complete_turn!(resumed_turn, proposal_intent(stale.id, context))

    assert {:error, _error} = Cases.materialize_proposal(completed.id, authorize?: false)
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

    complete_turn!(started.value, intent)
  end

  defp complete_turn!(turn, intent) do
    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "intent" => intent,
        "resolver" => resolver_identity(),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp resumed_signal_case!(suffix, context) do
    enable_signal_automation!(context.admin)
    source_ref = "proposal-signal-#{suffix}"

    incident =
      Cases.open_case!(
        :signal,
        "alertmanager",
        source_ref,
        "Proposal #{suffix}",
        :warning,
        :firing,
        %{},
        context.target.id,
        :en,
        actor: context.operator
      )

    prior_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    stale =
      Cases.append_evidence!(
        incident.id,
        prior_run.id,
        nil,
        "proposal-signal-stale-#{suffix}",
        "signal_event",
        "alertmanager",
        source_ref,
        %{"current" => false, "state" => "recovered"},
        DateTime.add(DateTime.utc_now(), -60, :second),
        authorize?: false
      )

    current =
      Cases.append_evidence!(
        incident.id,
        prior_run.id,
        nil,
        "proposal-signal-current-#{suffix}",
        "signal_event",
        "alertmanager",
        source_ref,
        %{"current" => true, "state" => "firing"},
        DateTime.utc_now(),
        authorize?: false
      )

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        prior_run.id,
        prior_run.revision,
        "proposal-signal-attention-#{suffix}",
        "Resolver interrupted",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(prior_run.id, authorize?: false)

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
        "Continue after Resolver interruption",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    {incident, prior_run, resumed_run, current, stale, resumed_turn}
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
      "enable resumed Signal Proposal test",
      actor: admin
    )
  end

  defp proposal_intent(evidence_id, context) do
    %{
      "type" => "proposal",
      "request_kind" => "effect",
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
