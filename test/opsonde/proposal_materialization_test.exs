defmodule Opsonde.ProposalMaterializationTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Signals, Targets}
  alias Opsonde.Providers.Signal

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
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("proposal-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "proposal-ssh",
        "ssh",
        "ssh://proposal-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

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

  for {label, kind} <- [
        {"no", :none},
        {"stale", :stale},
        {"recovered", :recovered},
        {"fabricated", :fabricated}
      ] do
    test "a Signal effect with #{label} affected Condition cannot materialize", context do
      {incident, _prior_run, _resumed_run, current, _stale, turn} =
        resumed_signal_case!("invalid-affected-#{unquote(label)}", context)

      condition =
        incident.id
        |> Cases.active_conditions_for_case!(authorize?: false)
        |> Enum.map(&Signals.get_condition!(&1.condition_id, authorize?: false))
        |> Enum.find(&(&1.state == :firing))

      claims =
        case unquote(kind) do
          :none ->
            []

          :stale ->
            [%{"condition_id" => condition.id, "revision" => condition.revision + 1}]

          :recovered ->
            recovered =
              Signals.list_conditions!(actor: context.admin)
              |> Enum.find(&(&1.state == :recovered))

            [%{"condition_id" => recovered.id, "revision" => recovered.revision}]

          :fabricated ->
            [%{"condition_id" => Ash.UUID.generate(), "revision" => 1}]
        end

      completed = complete_turn!(turn, proposal_intent(current.id, context), claims: claims)
      assert {:error, _error} = Cases.materialize_proposal(completed.id, authorize?: false)
      assert Cases.list_proposals!(actor: context.admin) == []
    end
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
        %{"desired_outcome" => "Target responds as expected"},
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

  defp complete_turn!(turn, intent, opts \\ []) do
    incident = Cases.get_case!(turn.case_id, authorize?: false)

    result = %{
      "outcome" => "decision",
      "intent" => intent,
      "resolver" => resolver_identity(),
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    result =
      if incident.trigger_kind == :signal do
        {:ok, revisions} =
          Opsonde.Cases.Case.ConditionContext.current_condition_revisions(incident)

        {:ok, conditions} = Opsonde.Cases.Case.ConditionContext.current_conditions(incident)

        claims =
          Keyword.get_lazy(opts, :claims, fn ->
            conditions
            |> Enum.filter(&(&1.state == :firing))
            |> Enum.map(&%{"condition_id" => &1.id, "revision" => &1.revision})
          end)

        result
        |> Map.put("condition_revisions", revisions)
        |> put_in(["intent", "affected_conditions"], claims)
      else
        result
      end

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      result,
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp resumed_signal_case!(suffix, context) do
    enable_signal_automation!(context.admin)
    source = "proposal-monitor-#{suffix}"
    event_key = "proposal-signal-#{suffix}"

    provider =
      Providers.create_provider!(
        source,
        :signal,
        "fixture-signal",
        %{"source" => source},
        %{"secret" => "proposal-monitor-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Targets.create_external_identity!(
      context.target.id,
      source,
      "hostname",
      context.target.name,
      actor: context.admin
    )

    now = DateTime.utc_now()

    for {receipt_id, state, seconds_ago} <- [
          {"#{suffix}-initial", :firing, 120},
          {"#{suffix}-recovered", :recovered, 90},
          {"#{suffix}-refired", :firing, 60}
        ] do
      ingest_proposal_signal!(
        provider,
        context.target.name,
        event_key,
        receipt_id,
        state,
        DateTime.add(now, -seconds_ago, :second)
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    prior_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [current] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    stale =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.case_id == incident.id and &1.content["state"] == "recovered"))

    assert stale.kind == "signal_event"
    assert current.content["state"] == "firing"

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

  defp ingest_proposal_signal!(provider, target_name, event_key, receipt_id, state, occurred_at) do
    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: receipt_id, headers: %{}, received_at: occurred_at},
      %{
        authenticate: fn provider_state, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: provider_state.source}}
        end,
        normalize: fn _provider_state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: receipt_id,
               event_key: event_key,
               state: state,
               occurred_at: occurred_at,
               target_ref: %{kind: :hostname, value: target_name},
               attributes: %{
                 "labels" => %{
                   "alertname" => "ServiceUnavailable",
                   "service" => "api.service"
                 }
               }
             }
           ]}
        end
      },
      authorize?: false
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
      "affected_conditions" => [],
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
