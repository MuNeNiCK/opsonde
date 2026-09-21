defmodule Opsonde.CaseLifecycleTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Targets}

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("case-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("case-operator@example.com", @password, :operator, actor: admin)

    next_operator =
      Accounts.create_user!("case-next-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("case-viewer@example.com", @password, :viewer, actor: admin)

    %{admin: admin, operator: operator, next_operator: next_operator, viewer: viewer}
  end

  test "manual, Signal and Audit Cases copy one exact standing revision without requiring a Target",
       context do
    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: context.admin)

    setting =
      configure_authority!(context.admin, %{
        authority_mode: :auto,
        signal_automation_enabled: true,
        max_elapsed_seconds: 7_200,
        max_resolver_turns: 40,
        reason: "enable Case acceptance"
      })

    manual =
      open_case!(:manual, "web", "manual-1", :not_applicable, context.operator, target.id)

    signal = open_case!(:signal, "zabbix", "event-1", :firing, nil)
    audit = open_case!(:audit, "schedule", "audit-1", :not_applicable, context.operator)

    for incident <- [manual, signal, audit] do
      assert incident.authority_setting_id == setting.id
      assert incident.authority_setting_revision == 2
      assert incident.authority_mode == :auto
      assert incident.max_elapsed_seconds == 7_200
      assert incident.max_resolver_turns == 40

      run = Cases.active_resolution_run!(incident.id, authorize?: false)
      assert run.generation == 1
      assert run.authority_mode == :auto
      assert run.max_elapsed_seconds == 7_200
      assert run.status == :running
    end

    assert manual.initial_target_id == target.id
    assert is_nil(signal.initial_target_id)

    updated_setting =
      configure_authority!(context.admin, %{
        authority_mode: :full_access,
        signal_automation_enabled: true,
        max_elapsed_seconds: 10_800,
        max_resolver_turns: 50,
        reason: "future Cases only"
      })

    reloaded = Cases.get_case!(manual.id, actor: context.viewer)
    assert reloaded.authority_setting_revision == 2
    assert reloaded.authority_mode == :auto
    assert reloaded.max_elapsed_seconds == 7_200

    later = open_case!(:manual, "cli", "manual-2", :not_applicable, context.operator)
    assert later.authority_setting_id == updated_setting.id
    assert later.authority_setting_revision == 3
    assert later.authority_mode == :full_access
  end

  test "disabled Signal automation opens a durable attention state and duplicate delivery is one Case",
       context do
    attempts =
      for _attempt <- 1..2 do
        Task.async(fn ->
          Cases.open_case(
            :signal,
            "zabbix",
            "event-disabled",
            "Disk error",
            :critical,
            :firing,
            %{"host" => "linux-01"},
            nil,
            :en,
            authorize?: false
          )
        end)
      end
      |> Task.await_many()

    assert [{:ok, first}, {:ok, second}] = attempts
    assert first.id == second.id

    incident = Cases.get_case!(first.id, actor: context.viewer)
    assert incident.status == :needs_attention
    assert incident.stop_reason == "Signal automation is disabled"
    assert incident.pending_intent == %{"action" => "start_resolution"}
    assert incident.required_human_input == "Enable automation or claim the Case"
    assert is_nil(incident.initial_target_id)

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert run.status == :needs_attention
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
    assert length(Cases.list_resolution_runs!(actor: context.viewer)) == 1

    assert Enum.map(Cases.list_case_events!(actor: context.viewer), & &1.event_type) == [
             "case_opened"
           ]
  end

  test "Case opening and a concurrent standing-setting revision produce one complete snapshot",
       context do
    current = Cases.current_authority_setting!(actor: context.admin)

    configure = fn ->
      Cases.configure_authority_setting(
        current.setting_revision,
        :auto,
        true,
        current.max_elapsed_seconds + 60,
        current.max_resolver_turns + 1,
        current.max_target_requests,
        current.max_effects,
        current.max_related_targets,
        current.max_ai_usage_units,
        current.max_no_progress_turns,
        "concurrent setting revision",
        actor: context.admin
      )
    end

    open = fn ->
      Cases.open_case(
        :manual,
        "web",
        "concurrent-open",
        "Concurrent open",
        :warning,
        :not_applicable,
        %{},
        nil,
        :en,
        actor: context.operator
      )
    end

    assert [{:ok, _setting}, {:ok, incident}] =
             [Task.async(configure), Task.async(open)] |> Task.await_many()

    snapshot =
      Cases.list_authority_settings!(actor: context.viewer)
      |> Enum.find(&(&1.id == incident.authority_setting_id))

    assert incident.authority_setting_revision == snapshot.setting_revision
    assert incident.authority_mode == snapshot.authority_mode
    assert incident.max_elapsed_seconds == snapshot.max_elapsed_seconds
    assert incident.max_resolver_turns == snapshot.max_resolver_turns

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert run.authority_mode == incident.authority_mode
    assert run.max_elapsed_seconds == incident.max_elapsed_seconds
  end

  test "claim, handoff, cancellation and source recovery are revisioned and retryable", context do
    configure_authority!(context.admin, %{
      signal_automation_enabled: true,
      reason: "enable Signal handling"
    })

    incident = open_case!(:signal, "alertmanager", "alert-1", :firing, nil)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    claimed = Cases.claim_case!(incident.id, incident.revision, actor: context.operator)
    assert claimed.current_owner_id == context.operator.id
    assert claimed.revision == 2

    retried_claim = Cases.claim_case!(incident.id, incident.revision, actor: context.operator)
    assert retried_claim.id == claimed.id
    assert retried_claim.revision == claimed.revision

    handed_off =
      Cases.handoff_case!(claimed.id, claimed.revision, context.next_operator.id,
        actor: context.operator
      )

    assert handed_off.current_owner_id == context.next_operator.id
    assert handed_off.revision == 3

    assert {:error, _error} =
             Cases.handoff_case(
               handed_off.id,
               handed_off.revision,
               context.viewer.id,
               actor: context.operator
             )

    recovered =
      Cases.record_case_source_recovery!(handed_off.id, handed_off.revision,
        actor: context.next_operator
      )

    assert recovered.alert_state == :recovered
    assert %DateTime{} = recovered.source_recovered_at
    assert recovered.revision == 5
    assert recovered.pending_intent["action"] == "resolve_turn"
    assert recovered.pending_intent["source_state"] == "recovered"
    assert [_started] = Cases.started_turns_for_run!(run.id, authorize?: false)

    retried_recovery =
      Cases.record_case_source_recovery!(handed_off.id, handed_off.revision,
        actor: context.next_operator
      )

    assert retried_recovery.revision == recovered.revision

    cancelled =
      Cases.request_case_cancellation!(recovered.id, recovered.revision,
        actor: context.next_operator
      )

    assert cancelled.cancel_requested
    assert cancelled.status == :cancelled
    assert cancelled.stop_reason == "Resolution cancelled by an operator"
    assert cancelled.revision == 6

    cancelled_run = Cases.list_resolution_runs!(actor: context.viewer) |> hd()
    refute cancelled_run.active
    assert cancelled_run.status == :cancelled
    assert %DateTime{} = cancelled_run.ended_at

    retried_cancel =
      Cases.request_case_cancellation!(recovered.id, recovered.revision,
        actor: context.next_operator
      )

    assert retried_cancel.revision == cancelled.revision

    assert {:error, _error} =
             Cases.record_case_source_recovery(
               cancelled.id,
               cancelled.revision,
               actor: context.next_operator
             )

    assert Enum.map(Cases.list_case_events!(actor: context.viewer), & &1.event_type) == [
             "case_opened",
             "case_claimed",
             "case_handed_off",
             "source_recovered",
             "turn_started",
             "case_cancelled"
           ]
  end

  test "attention and concurrent resume preserve history and create one new generation",
       context do
    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    incident =
      open_case!(:manual, "cli", "manual-resume", :not_applicable, operator)

    assert incident.report_language == :ja
    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "limit:turns:1",
        "Resolver turn limit exhausted",
        %{"kind" => "observe", "target" => "linux-01"},
        "Extend limits or investigate manually",
        authorize?: false
      )

    assert attention.status == :needs_attention
    assert attention.stop_reason == "Resolver turn limit exhausted"
    assert attention.revision == 2

    paused_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert paused_run.id == first_run.id
    assert paused_run.status == :needs_attention
    assert paused_run.revision == 2

    resume = fn ->
      Cases.resume_case(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        :auto,
        paused_run.max_elapsed_seconds + 60,
        paused_run.max_resolver_turns + 1,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "extend one turn",
        actor: context.operator
      )
    end

    results = [Task.async(resume), Task.async(resume)] |> Task.await_many()
    assert [{:ok, resumed_a}, {:ok, resumed_b}] = results
    assert resumed_a.id == resumed_b.id
    assert resumed_a.generation == 2
    assert resumed_a.active
    assert resumed_a.authority_mode == :auto
    assert resumed_a.resumed_by_id == context.operator.id

    assert [resumed_turn] =
             Cases.list_turns!(actor: context.viewer)
             |> Enum.filter(&(&1.resolution_run_id == resumed_a.id))

    assert resumed_turn.status == :started
    assert resumed_turn.intent == %{"objective" => "Continue resolution after operator resume"}

    old_run = Cases.get_resolution_run!(first_run.id, actor: context.viewer)
    refute old_run.active
    assert old_run.status == :superseded

    reloaded = Cases.get_case!(incident.id, actor: context.viewer)
    assert reloaded.status == :running
    assert reloaded.revision == 3
    assert reloaded.authority_setting_revision == incident.authority_setting_revision
    assert reloaded.authority_mode == incident.authority_mode
    assert reloaded.report_language == :ja

    runs = Cases.list_resolution_runs!(actor: context.viewer) |> Enum.sort_by(& &1.generation)
    assert Enum.map(runs, & &1.generation) == [1, 2]
    assert Enum.count(runs, & &1.active) == 1

    resumed_event =
      Cases.list_case_events!(actor: context.viewer)
      |> Enum.find(&(&1.event_type == "case_resumed"))

    assert resumed_event.data["prior_generation"] == 1
    assert resumed_event.data["new_generation"] == 2
    assert resumed_event.data["reason"] == "extend one turn"
  end

  test "source recovery remains recordable while a limit has paused autonomous resolution",
       context do
    configure_authority!(context.admin, %{
      signal_automation_enabled: true,
      reason: "enable Signal recovery handling"
    })

    incident = open_case!(:signal, "alertmanager", "paused-recovery", :firing, nil)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    stopped =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        run.revision,
        "paused-recovery-limit",
        "AI usage limit exhausted",
        %{"action" => "review_ai_limit"},
        "Review the AI usage limit and resume the Case",
        authorize?: false
      )

    recovered =
      Cases.record_case_source_recovery!(stopped.id, stopped.revision, actor: context.operator)

    assert recovered.status == :needs_attention
    assert recovered.alert_state == :recovered
    assert recovered.pending_intent == stopped.pending_intent
    assert Cases.started_turns_for_run!(run.id, authorize?: false) == []
  end

  test "cancelling an attention Case retires its active run", context do
    incident = open_case!(:manual, "web", "cancel-attention", :not_applicable, context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        run.revision,
        "cancel-attention:pause",
        "Operator review is required",
        %{"action" => "provide_human_input"},
        "Review or cancel",
        authorize?: false
      )

    cancelled =
      Cases.request_case_cancellation!(attention.id, attention.revision, actor: context.operator)

    assert cancelled.status == :cancelled
    assert cancelled.cancel_requested
    assert cancelled.required_human_input == nil
    assert cancelled.pending_intent == %{}

    retired = Cases.get_resolution_run!(run.id, actor: context.viewer)
    refute retired.active
    assert retired.status == :cancelled
    assert %DateTime{} = retired.ended_at

    assert {:error, _error} = Cases.active_resolution_run(incident.id, authorize?: false)
  end

  test "viewer mutation and direct internal writes are forbidden", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.open_case(
               :manual,
               "web",
               "forbidden",
               "Forbidden",
               :warning,
               :not_applicable,
               %{},
               nil,
               :en,
               actor: context.viewer
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_case_event_record(
               %{
                 case_id: Ash.UUID.generate(),
                 event_type: "bypass",
                 idempotency_key: "bypass",
                 data: %{}
               },
               actor: context.admin
             )
  end

  test "resume cannot reduce a prior run limit", context do
    incident =
      open_case!(:manual, "cli", "manual-no-reduction", :not_applicable, context.operator)

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        run.revision,
        "limit:manual:no-reduction",
        "Manual handoff",
        %{"kind" => "observe"},
        "Review limits",
        authorize?: false
      )

    paused = Cases.active_resolution_run!(incident.id, authorize?: false)

    assert {:error, _error} =
             Cases.resume_case(
               attention.id,
               attention.revision,
               paused.id,
               paused.revision,
               paused.authority_mode,
               paused.max_elapsed_seconds,
               paused.max_resolver_turns - 1,
               paused.max_target_requests,
               paused.max_effects,
               paused.max_related_targets,
               paused.max_ai_usage_units,
               paused.max_no_progress_turns,
               "invalid reduction",
               actor: context.operator
             )

    assert Cases.active_resolution_run!(incident.id, authorize?: false).id == paused.id
    assert length(Cases.list_resolution_runs!(actor: context.viewer)) == 1
  end

  defp open_case!(
         kind,
         source,
         source_ref,
         alert_state,
         actor,
         target_id \\ nil
       ) do
    Cases.open_case!(
      kind,
      source,
      source_ref,
      "#{kind} Case #{source_ref}",
      :warning,
      alert_state,
      %{"source_ref" => source_ref},
      target_id,
      :en,
      actor: actor,
      authorize?: not is_nil(actor)
    )
  end

  defp configure_authority!(actor, overrides) do
    current = Cases.current_authority_setting!(actor: actor)

    values =
      %{
        authority_mode: current.authority_mode,
        signal_automation_enabled: current.signal_automation_enabled,
        max_elapsed_seconds: current.max_elapsed_seconds,
        max_resolver_turns: current.max_resolver_turns,
        max_target_requests: current.max_target_requests,
        max_effects: current.max_effects,
        max_related_targets: current.max_related_targets,
        max_ai_usage_units: current.max_ai_usage_units,
        max_no_progress_turns: current.max_no_progress_turns,
        reason: "configure Case tests"
      }
      |> Map.merge(overrides)

    Cases.configure_authority_setting!(
      current.setting_revision,
      values.authority_mode,
      values.signal_automation_enabled,
      values.max_elapsed_seconds,
      values.max_resolver_turns,
      values.max_target_requests,
      values.max_effects,
      values.max_related_targets,
      values.max_ai_usage_units,
      values.max_no_progress_turns,
      values.reason,
      actor: actor
    )
  end
end
