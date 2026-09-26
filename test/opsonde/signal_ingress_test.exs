defmodule Opsonde.SignalIngressTest do
  use Opsonde.DataCase, async: false

  import Ecto.Query

  alias Opsonde.{Accounts, Cases, Providers, Signals, Targets}
  alias Opsonde.Cases.{DecisionRouteWorker, ResolverDelivery}
  alias Opsonde.Providers.{AI, Signal}
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
    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :firing
    assert condition.target_id == target.id
    assert condition.occurrence == 1
    assert signal_event.condition_id == condition.id
    assert Cases.list_turns!(actor: context.admin) == []
    assert {:ok, %{state: :collecting}} = Cases.case_dispatch(incident.id, authorize?: false)
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

    assert [%{id: case_id}] = cases
    assert [membership] = Cases.active_conditions_for_case!(case_id, authorize?: false)
    assert membership.condition_id == Enum.find(events, &(&1.event_key == "alert-a")).condition_id
    assert Enum.find(events, &(&1.event_key == "alert-a")).case_id == hd(cases).id
    assert is_nil(Enum.find(events, &(&1.event_key == "alert-b")).case_id)
  end

  test "same Target alerts share a provisional Case while retaining separate Conditions",
       context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("same-target", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "same-target",
      actor: context.admin
    )

    second_provider = signal_provider!(context.admin, "separate-monitor")

    Targets.create_external_identity!(
      target.id,
      "separate-monitor",
      "hostname",
      "same-target",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()
    attributes = %{"title" => "Identical alert title"}

    ingest!(
      context.provider,
      envelope("separate-a", occurred_at),
      invocation("separate-a", [
        event("separate-a", "event-a", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "same-target"},
          attributes: attributes
        )
      ])
    )

    ingest!(
      second_provider,
      envelope("separate-b", occurred_at),
      invocation("separate-b", [
        event("separate-b", "event-b", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "same-target"},
          attributes: attributes
        )
      ])
    )

    assert [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "a due provisional Case starts one initial Resolver Turn for its Conditions", context do
    enable_signal_automation!(context.admin)
    received_at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("due-case", received_at),
      invocation("due-case", [event("due-case", "disk-errors", :firing, received_at)])
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert Cases.list_turns!(actor: context.admin) == []
    job = %Oban.Job{args: %{"case_id" => incident.id}}

    assert :ok = Opsonde.Cases.CaseDispatchWorker.perform(job)
    assert :ok = Opsonde.Cases.CaseDispatchWorker.perform(job)
    assert length(Cases.list_turns!(actor: context.admin)) == 1
    assert {:ok, %{state: :sent}} = Cases.case_dispatch(incident.id, authorize?: false)
  end

  test "PoE, twenty AP and coincident core alerts enter one provisional investigation",
       context do
    enable_signal_automation!(context.admin)

    names = ["poe-01" | Enum.map(1..20, &"ap-#{&1}")] ++ ["core-01"]

    targets =
      Enum.map(names, fn name ->
        target =
          Targets.create_target!(name, "network_device", "generic", %{}, nil,
            actor: context.admin
          )

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target.id}
      end)
      |> Map.new()

    for name <- tl(names) do
      Targets.create_relationship!(targets["poe-01"], targets[name], "connected_to", %{}, nil,
        actor: context.admin
      )
    end

    received_at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      Enum.map(names, fn name ->
        event("poe-star", name, :firing, received_at,
          target_ref: %{kind: :hostname, value: name},
          attributes: %{"title" => "#{name} unavailable"}
        )
      end)

    ingest!(context.provider, envelope("poe-star", received_at), invocation("poe-star", events))

    assert [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Signals.list_conditions!(actor: context.admin)) == 22
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 22
    assert Cases.list_turns!(actor: context.admin) == []

    assert :ok =
             Opsonde.Cases.CaseDispatchWorker.perform(%Oban.Job{
               args: %{"case_id" => incident.id}
             })

    [turn] = Cases.list_turns!(actor: context.admin)

    selection = %Opsonde.Providers.AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    assert {:ok, request} = Opsonde.Cases.ResolverProjection.build(turn.id, selection)
    assert length(request.conditions) == 22
    assert request.conditions |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 22
    assert Enum.count(request.evidence, &(&1.kind == "signal_event")) == 22
    assert Enum.all?(request.evidence, &is_binary(&1.content["condition_id"]))
  end

  test "an oversized Target graph preserves native alerts in separate Cases", context do
    enable_signal_automation!(context.admin)

    anchor =
      Targets.create_target!("dense-anchor", "network_device", "generic", %{}, nil,
        actor: context.admin
      )

    Targets.create_external_identity!(
      anchor.id,
      "test-monitor",
      "hostname",
      "dense-anchor",
      actor: context.admin
    )

    for index <- 1..128 do
      neighbour =
        Targets.create_target!("dense-neighbour-#{index}", "network_device", "generic", %{}, nil,
          actor: context.admin
        )

      Targets.create_relationship!(anchor.id, neighbour.id, "connected_to", %{}, nil,
        actor: context.admin
      )
    end

    occurred_at = DateTime.utc_now()

    for key <- ["dense-a", "dense-b"] do
      ingest!(
        context.provider,
        envelope(key, occurred_at),
        invocation(key, [
          event(key, key, :firing, occurred_at,
            target_ref: %{kind: :hostname, value: "dense-anchor"}
          )
        ])
      )
    end

    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "concurrent monitoring sources converge on one active incident", context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("concurrent-target", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "concurrent-target",
      actor: context.admin
    )

    second_provider = signal_provider!(context.admin, "concurrent-monitor")

    Targets.create_external_identity!(
      target.id,
      "concurrent-monitor",
      "hostname",
      "concurrent-target",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()

    requests = [
      {context.provider, "concurrent-a", "event-a", "test-monitor"},
      {second_provider, "concurrent-b", "event-b", "concurrent-monitor"}
    ]

    results =
      requests
      |> Enum.map(fn {provider, receipt_id, event_key, _source} ->
        Task.async(fn ->
          Signals.ingest_signal(
            provider.id,
            provider.revision,
            envelope(receipt_id, occurred_at),
            invocation(receipt_id, [
              event(receipt_id, event_key, :firing, occurred_at,
                target_ref: %{kind: :hostname, value: "concurrent-target"}
              )
            ])
          )
        end)
      end)
      |> Task.await_many()

    assert [{:ok, _first}, {:ok, _second}] = results
    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert Cases.list_turns!(actor: context.admin) == []
    [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
    assert length(Signals.list_signal_correlations!(actor: context.admin)) == 2
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

  test "late recurrence stays in its open investigation without rewinding earlier recovery",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -40, :second)

    ingest_one!(context.provider, "firing", :firing, DateTime.add(base, 10, :second))
    ingest_one!(context.provider, "recovery", :recovered, DateTime.add(base, 30, :second))
    ingest_one!(context.provider, "delayed", :firing, DateTime.add(base, 20, :second))

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    correlation = Signals.list_signal_correlations!(actor: context.admin) |> List.first()
    [first_condition] = Signals.list_conditions!(actor: context.admin)

    assert first_condition.state == :recovered
    assert incident.status == :running
    assert correlation.current_state == :recovered
    assert correlation.current_occurred_at == DateTime.add(base, 30, :second)
    assert length(Signals.list_signal_events!(actor: context.admin)) == 3
    assert :ok = dispatch_initial!(incident)
    assert length(Cases.list_turns!(actor: context.admin)) == 1

    ingest_one!(context.provider, "refiring", :firing, DateTime.add(base, 40, :second))

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    same_case = Cases.get_case!(incident.id, actor: context.admin)
    assert same_case.id == incident.id
    assert same_case.status == :running
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "a rotated native alert key for the same affected subject stays in the dispatched Case",
       context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("rotating-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "rotating-host",
      actor: context.admin
    )

    base = DateTime.add(DateTime.utc_now(), -30, :second)
    labels = %{"pod" => "pod-a", "namespace" => "default", "alertname" => "PodUnavailable"}

    for {receipt, key, state, offset} <- [
          {"original-firing", "fingerprint-a", :firing, 0},
          {"original-recovery", "fingerprint-a", :recovered, 10}
        ] do
      at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt, at),
        invocation(receipt, [
          event(receipt, key, state, at,
            target_ref: %{kind: :hostname, value: "rotating-host"},
            attributes: %{"labels" => labels}
          )
        ])
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    assert length(Cases.list_turns!(actor: context.admin)) == 1

    at = DateTime.add(base, 20, :second)

    ingest!(
      context.provider,
      envelope("rotated-firing", at),
      invocation("rotated-firing", [
        event("rotated-firing", "fingerprint-b", :firing, at,
          target_ref: %{kind: :hostname, value: "rotating-host"},
          attributes: %{"labels" => labels}
        )
      ])
    )

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "a reused native event key with a different affected subject opens another Case",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)

    for {receipt_id, state, offset, pod} <- [
          {"pod-a-firing", :firing, 0, "pod-a"},
          {"pod-a-recovered", :recovered, 10, "pod-a"},
          {"pod-b-firing", :firing, 20, "pod-b"}
        ] do
      occurred_at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt_id, occurred_at),
        invocation(receipt_id, [
          event(receipt_id, "shared-event-key", state, occurred_at,
            attributes: %{"labels" => %{"pod" => pod, "namespace" => "default"}}
          )
        ])
      )
    end

    assert length(Cases.list_cases!(actor: context.admin)) == 2
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
  end

  test "one native event key can carry two firing subjects without cross-recovery", context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)

    for {receipt, state, offset, pod} <- [
          {"pod-a-start", :firing, 0, "pod-a"},
          {"pod-b-start", :firing, 1, "pod-b"},
          {"pod-a-end", :recovered, 2, "pod-a"}
        ] do
      at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt, at),
        invocation(receipt, [
          event(receipt, "shared-native-key", state, at,
            attributes: %{
              "labels" => %{
                "pod" => pod,
                "namespace" => "default",
                "alertname" => "PodUnavailable"
              }
            }
          )
        ])
      )
    end

    conditions = Signals.list_conditions!(actor: context.admin)
    assert length(conditions) == 2
    assert Enum.find(conditions, &(&1.subject_ref["name"] == "pod-a")).state == :recovered
    assert Enum.find(conditions, &(&1.subject_ref["name"] == "pod-b")).state == :firing
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "a recurrence during Resolver delivery is charged and retried from current Conditions",
       context do
    enable_signal_automation!(context.admin)
    configure_resolver_ai!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "initial-ai-firing", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    [first_turn] = Cases.list_turns!(actor: context.admin)

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSearch{query: "current fault", reason: "Find affected target"},
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    assert :ok =
             ResolverDelivery.run(first_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert length(request.conditions) == 1

                   ingest_one!(
                     context.provider,
                     "ai-recovery",
                     :recovered,
                     DateTime.add(base, 10)
                   )

                   ingest_one!(context.provider, "ai-refiring", :firing, DateTime.add(base, 20))
                   {:ok, decision}
                 end
               }
             )

    assert Cases.get_turn!(first_turn.id, authorize?: false).result["outcome"] ==
             "context_changed"

    assert Cases.get_resolution_run!(first_turn.resolution_run_id, authorize?: false).ai_usage_units ==
             5

    [successor] =
      Cases.list_turns!(actor: context.admin)
      |> Enum.filter(&(&1.status == :started))

    assert :ok =
             ResolverDelivery.run(successor.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert length(request.conditions) == 2
                   assert Enum.map(request.conditions, & &1.state) == [:recovered, :firing]
                   {:ok, decision}
                 end
               }
             )

    assert Cases.get_turn!(successor.id, authorize?: false).result["outcome"] == "decision"
    assert length(Cases.list_cases!(actor: context.admin)) == 1
  end

  test "a recurrence after Resolver acceptance supersedes its unrouted decision", context do
    enable_signal_automation!(context.admin)
    configure_resolver_ai!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "route-initial", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    [first_turn] = Cases.list_turns!(actor: context.admin)

    assert :ok =
             ResolverDelivery.run(first_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{query: "old fault", reason: "Find target"},
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 1}
                    }}
                 end
               }
             )

    ingest_one!(context.provider, "route-recovery", :recovered, DateTime.add(base, 10))
    ingest_one!(context.provider, "route-refiring", :firing, DateTime.add(base, 20))

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => first_turn.id}})

    [successor] =
      Cases.list_turns!(actor: context.admin)
      |> Enum.filter(&(&1.status == :started))

    assert successor.id != first_turn.id

    assert Cases.get_case!(incident.id, actor: context.admin).pending_intent["turn_id"] ==
             successor.id

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => first_turn.id}})
    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "source recovery alone leaves an attention Case awaiting independent verification",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest_one!(context.provider, "attention-firing", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
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
      DateTime.add(base, 10, :second)
    )

    recovered = Cases.get_case!(incident.id, actor: context.admin)
    assert recovered.status == :needs_attention
    assert recovered.required_human_input == "Review the Resolver delivery failure"
    assert [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :recovered
    assert [active_run] = Cases.list_resolution_runs!(actor: context.admin)
    assert active_run.id == run.id
    assert active_run.status == :needs_attention
    assert length(Cases.list_turns!(actor: context.admin)) == 1
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

  test "a matching recurrence stays in the Case awaiting operator attention", context do
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "attention-first", :firing, base)
    ingest_one!(context.provider, "attention-recovered", :recovered, DateTime.add(base, 10))
    ingest_one!(context.provider, "attention-refiring", :firing, DateTime.add(base, 20))

    [incident] = Cases.list_cases!(actor: context.admin)
    assert incident.status == :needs_attention
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert Cases.list_turns!(actor: context.admin) == []
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

  test "a new firing of the same alert opens a fresh Case after prior resolution", context do
    enable_signal_automation!(context.admin)
    base = DateTime.utc_now()
    ingest_one!(context.provider, "first-firing", :firing, base)

    [first] = Cases.list_cases!(actor: context.admin)
    first_run = Cases.active_resolution_run!(first.id, authorize?: false)

    Cases.update_case_record!(first, first.revision, %{status: :resolved}, authorize?: false)

    Cases.retire_resolution_run!(
      first_run,
      first_run.revision,
      %{status: :completed, ended_at: DateTime.utc_now()},
      authorize?: false
    )

    ingest_one!(context.provider, "first-recovered", :recovered, DateTime.add(base, 10, :second))
    ingest_one!(context.provider, "second-firing", :firing, DateTime.add(base, 20, :second))

    [second, historical] =
      Cases.list_cases!(actor: context.admin)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    assert historical.id == first.id
    assert historical.status == :resolved
    assert second.id != first.id
    assert second.status == :running

    [second_membership] = Cases.active_conditions_for_case!(second.id, authorize?: false)

    assert Signals.get_condition!(second_membership.condition_id, authorize?: false).state ==
             :firing

    [correlation] = Signals.list_signal_correlations!(actor: context.admin)
    assert correlation.current_state == :firing

    assert correlation.latest_signal_event_id in Enum.map(
             Signals.list_signal_events!(actor: context.admin),
             & &1.id
           )

    ingest_one!(context.provider, "repeat-firing", :firing, DateTime.add(base, 21, :second))
    ingest_one!(context.provider, "stale-firing", :firing, DateTime.add(base, 19, :second))
    assert length(Cases.list_cases!(actor: context.admin)) == 2

    ingest_one!(context.provider, "second-recovered", :recovered, DateTime.add(base, 30, :second))
    ingest_one!(context.provider, "second-recovered", :recovered, DateTime.add(base, 30, :second))

    assert Cases.get_case!(first.id, actor: context.admin).status == :resolved
    events = Signals.list_signal_events!(actor: context.admin)

    [older, newer] =
      Signals.list_conditions!(actor: context.admin)
      |> Enum.sort_by(& &1.occurrence)

    assert older.state == :recovered
    assert newer.state == :recovered
    assert {older.occurrence, newer.occurrence} == {1, 2}
    assert Enum.any?(events, &(&1.condition_id == older.id))
    assert Enum.any?(events, &(&1.condition_id == newer.id))

    assert Enum.find(events, &(DateTime.compare(&1.occurred_at, DateTime.add(base, 19)) == :eq)).condition_id ==
             nil

    assert length(events) == 6
    assert Enum.count(events, &(&1.case_id == first.id)) == 2
    assert Enum.count(events, &(&1.case_id == second.id)) == 3
    assert Enum.count(events, &is_nil(&1.case_id)) == 1
  end

  test "a later Target catalog change re-evaluates a running unresolved Signal Case", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)
    ingest_one!(context.provider, "unresolved", :firing, occurred_at)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

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
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("waiting-target", occurred_at),
      invocation("waiting-target", [
        event("waiting-target", "waiting-target-alert", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "late-linux"}
        )
      ])
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

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
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)
    ingest_one!(context.provider, "busy-reconciliation", :firing, occurred_at)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

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

  defp dispatch_initial!(incident) do
    Opsonde.Cases.CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
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

  defp configure_resolver_ai!(admin) do
    provider =
      Providers.create_provider!(
        "signal-ingress-resolver-ai",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-test-key"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Opsonde.TestAIUsage.configure!(provider.id, :resolver, 10, admin)
  end

  defp signal_provider!(admin, source) do
    Providers.create_provider!(
      "signal-ingress-#{source}",
      :signal,
      "fixture-signal",
      %{"source" => source},
      %{"secret" => "signal-secret"},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
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
