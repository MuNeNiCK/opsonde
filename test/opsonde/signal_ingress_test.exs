defmodule Opsonde.SignalIngressTest do
  use Opsonde.DataCase, async: false

  import Ecto.Query

  alias Opsonde.{Accounts, Cases, Providers, Signals, Targets}
  alias Opsonde.Providers.Signal
  alias Opsonde.Repo

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("signal-ingress-admin@example.com", @password, @password,
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "signal-ingress-provider",
        :signal,
        "fixture-signal",
        %{"source" => "test-monitor"},
        %{"secret" => "signal-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, provider: provider}
  end

  test "authenticated firing resolves only an exact registered identity and starts one Case",
       context do
    Accounts.change_preferred_language!(context.admin, :ja, actor: context.admin)
    enable_signal_automation!(context.admin)

    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "linux-01",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()

    invocation =
      invocation("receipt-1", [
        event("receipt-1", "disk-errors", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "linux-01"},
          attributes: %{"title" => "Disk errors", "severity" => "critical"}
        )
      ])

    first = ingest!(context.provider, envelope("first", occurred_at), invocation)
    replay = ingest!(context.provider, envelope("first", occurred_at), invocation)

    assert first.id == replay.id
    assert first.event_count == 1

    [signal_event] = Signals.list_signal_events!(actor: context.admin)
    incident = Cases.get_case!(signal_event.case_id, actor: context.admin)

    assert signal_event.target_id == target.id
    assert incident.selected_target_id == target.id
    assert incident.selected_target_revision == target.revision
    assert incident.current_owner_id == context.admin.id
    assert incident.title == "Disk errors"
    assert incident.severity == :critical
    assert incident.status == :running
    assert incident.report_language == :ja

    Accounts.change_preferred_language!(context.admin, :en, actor: context.admin)
    assert Cases.get_case!(incident.id, actor: context.admin).report_language == :ja

    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_turns!(actor: context.admin)) == 1
    assert length(Cases.list_evidence!(actor: context.admin)) == 1
  end

  test "one grouped receipt persists separate source events and opens only firing Cases",
       context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("group", occurred_at),
      invocation("group-receipt", [
        event("group-receipt", "alert-a", :firing, occurred_at),
        event("group-receipt", "alert-b", :recovered, occurred_at)
      ])
    )

    events = Signals.list_signal_events!(actor: context.admin)
    cases = Cases.list_cases!(actor: context.admin)

    assert Enum.map(events, &{&1.event_key, &1.state}) |> Enum.sort() == [
             {"alert-a", :firing},
             {"alert-b", :recovered}
           ]

    assert [%{source_ref: "alert-a"}] = cases
    assert Enum.find(events, &(&1.event_key == "alert-a")).case_id == hd(cases).id
    assert is_nil(Enum.find(events, &(&1.event_key == "alert-b")).case_id)
  end

  test "concurrent receipt replay converges and conflicting reuse is rejected", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    envelope = envelope("concurrent", occurred_at)

    invocation =
      invocation("concurrent-receipt", [
        event("concurrent-receipt", "same-alert", :firing, occurred_at)
      ])

    attempts =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          Signals.ingest_signal(
            context.provider.id,
            context.provider.revision,
            envelope,
            invocation
          )
        end)
      end)
      |> Task.await_many()

    assert [{:ok, first}, {:ok, second}] = attempts
    assert first.id == second.id
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_cases!(actor: context.admin)) == 1

    conflicting =
      invocation("concurrent-receipt", [
        event("concurrent-receipt", "different-alert", :firing, occurred_at)
      ])

    assert {:error, _error} =
             Signals.ingest_signal(
               context.provider.id,
               context.provider.revision,
               envelope,
               conflicting
             )

    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_cases!(actor: context.admin)) == 1
  end

  test "recovery and delayed delivery remain traceable without rewinding Case state", context do
    enable_signal_automation!(context.admin)
    base = DateTime.utc_now()

    ingest_one!(context.provider, "firing", :firing, DateTime.add(base, 10, :second))
    ingest_one!(context.provider, "recovery", :recovered, DateTime.add(base, 30, :second))
    ingest_one!(context.provider, "delayed", :firing, DateTime.add(base, 20, :second))

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    correlation = Signals.list_signal_correlations!(actor: context.admin) |> List.first()

    assert incident.alert_state == :recovered
    assert incident.status == :running
    assert correlation.current_state == :recovered
    assert correlation.current_occurred_at == DateTime.add(base, 30, :second)
    assert length(Signals.list_signal_events!(actor: context.admin)) == 3
    assert length(Cases.list_turns!(actor: context.admin)) == 1

    ingest_one!(context.provider, "refiring", :firing, DateTime.add(base, 40, :second))

    incident = Cases.get_case!(incident.id, actor: context.admin)
    assert incident.alert_state == :firing
    assert incident.status == :running
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "source recovery resumes an attention Case without operator input", context do
    enable_signal_automation!(context.admin)
    base = DateTime.utc_now()

    ingest_one!(context.provider, "attention-firing", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{"outcome" => "delivery_failed", "category" => "invalid_output"},
      :none,
      %{"action" => "retry_resolver", "turn_id" => turn.id},
      "Review the Resolver delivery failure",
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    Cases.require_case_attention!(
      current.id,
      current.revision,
      current_run.id,
      current_run.revision,
      "resolver-delivery-failed:test",
      "Resolver delivery failed",
      %{"action" => "retry_resolver", "turn_id" => turn.id},
      "Review the Resolver delivery failure",
      authorize?: false
    )

    ingest_one!(
      context.provider,
      "attention-recovered",
      :recovered,
      DateTime.add(base, 30, :second)
    )

    recovered = Cases.get_case!(incident.id, actor: context.admin)
    assert recovered.status == :running
    assert recovered.alert_state == :recovered
    assert recovered.required_human_input == nil
    assert recovered.stop_reason == nil

    resumed_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert resumed_run.generation == 2
    assert [_turn] = Cases.started_turns_for_run!(resumed_run.id, authorize?: false)
  end

  test "source sequence orders events that have the same source timestamp", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("same-time-recovery", occurred_at),
      invocation("same-time-recovery", [
        event("same-time-recovery", "same-time-alert", :recovered, occurred_at,
          source_sequence: 20
        )
      ])
    )

    ingest!(
      context.provider,
      envelope("same-time-delayed", occurred_at),
      invocation("same-time-delayed", [
        event("same-time-delayed", "same-time-alert", :firing, occurred_at, source_sequence: 10)
      ])
    )

    correlation = Signals.list_signal_correlations!(actor: context.admin) |> List.first()
    assert correlation.current_state == :recovered
    assert correlation.current_source_sequence == "20"
    assert Cases.list_cases!(actor: context.admin) == []
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
  end

  test "disabled automation stores the alert without starting autonomous resolution", context do
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "disabled", :firing, occurred_at)

    incident = Cases.list_cases!(actor: context.admin) |> List.first()

    assert incident.status == :needs_attention
    assert is_nil(incident.current_owner_id)
    assert Cases.list_turns!(actor: context.admin) == []
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_evidence!(actor: context.admin)) == 1
  end

  test "a later source event is retained after the Case is terminal", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "terminal-firing", :firing, occurred_at)

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    Cases.update_case_record!(
      incident,
      incident.revision,
      %{status: :cancelled},
      authorize?: false
    )

    Cases.retire_resolution_run!(
      run,
      run.revision,
      %{status: :cancelled, ended_at: DateTime.utc_now()},
      authorize?: false
    )

    ingest_one!(
      context.provider,
      "terminal-recovery",
      :recovered,
      DateTime.add(occurred_at, 10, :second)
    )

    assert Cases.get_case!(incident.id, actor: context.admin).status == :cancelled
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2

    assert (Signals.list_signal_correlations!(actor: context.admin) |> List.first()).current_state ==
             :recovered
  end

  test "a later Target catalog change re-evaluates a running unresolved Signal Case", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "unresolved", :firing, occurred_at)

    [first_turn] = Cases.list_turns!(actor: context.admin)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "target not found"},
      :none,
      %{"action" => "continue"},
      "Review unresolved Target",
      authorize?: false
    )

    target =
      Targets.create_target!("late-linux", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "late-linux",
      actor: context.admin
    )

    job =
      Repo.one!(
        from(job in Oban.Job,
          where: job.worker == "Opsonde.Signals.CaseReconciliationWorker",
          order_by: [asc: job.inserted_at],
          limit: 1
        )
      )

    assert :ok = Opsonde.Signals.CaseReconciliationWorker.perform(job)

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == 2
    assert Enum.count(turns, &(&1.status == :started)) == 1

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    assert incident.status == :running
    assert is_nil(incident.selected_target_id)
  end

  test "matching identity registration resumes the same waiting Signal Case exactly once",
       context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("waiting-target", occurred_at),
      invocation("waiting-target", [
        event("waiting-target", "waiting-target-alert", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "late-linux"}
        )
      ])
    )

    [first_turn] = Cases.list_turns!(actor: context.admin)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "decision", "intent" => %{"type" => "handoff"}},
      :human_input,
      %{"action" => "provide_human_input", "source_turn_id" => first_turn.id},
      "Register the Target identity",
      authorize?: false
    )

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    waiting =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "waiting-target:handoff",
        "The exact Target identity is unavailable",
        %{"action" => "provide_human_input", "source_turn_id" => first_turn.id},
        "Register the exact Target identity",
        authorize?: false
      )

    unrelated =
      Targets.create_target!("unrelated-linux", "host", "linux", %{}, nil, actor: context.admin)

    unrelated_identity =
      Targets.create_external_identity!(
        unrelated.id,
        "test-monitor",
        "hostname",
        "unrelated-linux",
        actor: context.admin
      )

    assert :ok =
             Opsonde.Signals.CaseReconciliationWorker.perform(
               reconciliation_job!(unrelated_identity.id)
             )

    unchanged = Cases.get_case!(waiting.id, actor: context.admin)
    assert unchanged.status == :needs_attention
    assert unchanged.revision == waiting.revision

    target =
      Targets.create_target!("late-linux", "host", "linux", %{}, nil, actor: context.admin)

    identity =
      Targets.create_external_identity!(
        target.id,
        "test-monitor",
        "hostname",
        "late-linux",
        actor: context.admin
      )

    job = reconciliation_job!(identity.id)
    assert :ok = Opsonde.Signals.CaseReconciliationWorker.perform(job)

    resumed = Cases.get_case!(waiting.id, actor: context.admin)
    assert resumed.status == :running
    assert resumed.selected_target_id == target.id
    assert resumed.selected_target_revision == target.revision
    assert resumed.current_owner_id == context.admin.id

    runs = Cases.list_resolution_runs!(actor: context.admin) |> Enum.sort_by(& &1.generation)

    assert Enum.map(runs, &{&1.generation, &1.status, &1.active}) == [
             {1, :superseded, false},
             {2, :running, true}
           ]

    resumed_run = List.last(runs)
    assert is_nil(resumed_run.resumed_by_id)

    assert [resumed_turn] =
             Cases.list_turns!(actor: context.admin)
             |> Enum.filter(&(&1.resolution_run_id == resumed_run.id))

    assert resumed_turn.status == :started

    assert resumed_turn.intent == %{
             "objective" => "Continue resolution after Target registration"
           }

    assert :ok = Opsonde.Signals.CaseReconciliationWorker.perform(job)
    assert length(Cases.list_resolution_runs!(actor: context.admin)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "Target reconciliation remains retryable while a Resolver Turn is active", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "busy-reconciliation", :firing, occurred_at)

    [first_turn] = Cases.list_turns!(actor: context.admin)
    job = %Oban.Job{args: %{"change_key" => "target:later"}}

    assert {:error, "Signal Case still has an active Resolver Turn"} =
             Opsonde.Signals.CaseReconciliationWorker.perform(job)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "target not found"},
      :none,
      %{"action" => "continue"},
      "Review unresolved Target",
      authorize?: false
    )

    assert :ok = Opsonde.Signals.CaseReconciliationWorker.perform(job)
    assert length(Cases.list_turns!(actor: context.admin)) == 2
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
      "enable Signal ingress",
      actor: admin
    )
  end

  defp reconciliation_job!(identity_id) do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == "Opsonde.Signals.CaseReconciliationWorker"
      )
    )
    |> Enum.find(fn job ->
      String.contains?(job.args["change_key"], identity_id)
    end)
  end

  defp ingest_one!(provider, receipt_id, state, occurred_at) do
    ingest!(
      provider,
      envelope(receipt_id, occurred_at),
      invocation(receipt_id, [event(receipt_id, "same-alert", state, occurred_at)])
    )
  end

  defp ingest!(provider, envelope, invocation) do
    Signals.ingest_signal!(provider.id, provider.revision, envelope, invocation)
  end

  defp invocation(receipt_id, events) do
    %{
      authenticate: fn adapter_state, _envelope ->
        {:ok,
         %Signal.AuthenticatedReceipt{
           receipt_id: receipt_id,
           source: adapter_state.source
         }}
      end,
      normalize: fn _adapter_state, _envelope, _receipt -> {:ok, events} end
    }
  end

  defp event(receipt_id, event_key, state, occurred_at, opts \\ []) do
    %Signal.Event{
      receipt_id: receipt_id,
      event_key: event_key,
      state: state,
      occurred_at: occurred_at,
      source_sequence: Keyword.get(opts, :source_sequence),
      target_ref: Keyword.get(opts, :target_ref),
      attributes: Keyword.get(opts, :attributes, %{})
    }
  end

  defp envelope(body, received_at) do
    %Signal.Envelope{body: body, headers: %{}, received_at: received_at}
  end
end
