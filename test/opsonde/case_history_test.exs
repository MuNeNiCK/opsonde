defmodule Opsonde.CaseHistoryTest do
  use Opsonde.DataCase, async: false

  import Ecto.Query

  alias Opsonde.{Accounts, Cases, Repo}
  alias Opsonde.Cases.ResolutionRun

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("history-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("history-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("history-viewer@example.com", @password, :viewer, actor: admin)

    configure_limits!(admin)
    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "Turn completion and Evidence survive reload and retries do not duplicate history",
       context do
    {incident, run} = open!("durable-history", context.operator)
    intent = %{"action" => "inspect", "target" => "linux-01"}

    started = start!(incident, run, "turn-1", intent)
    assert started.status == :charged
    assert started.value.ordinal == 1
    assert started.run.turn_count == 1

    retried = start!(incident, run, "turn-1", intent)
    assert retried.status == :duplicate
    assert retried.value.id == started.value.id

    assert {:error, _error} =
             start(incident, run, "turn-1", %{"action" => "change-the-request"})

    observed_at = DateTime.utc_now()

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-1",
        "command_output",
        "linux-01",
        "journalctl",
        %{"lines" => ["I/O error"]},
        observed_at,
        authorize?: false
      )

    retried_evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-1",
        "command_output",
        "linux-01",
        "journalctl",
        %{"lines" => ["I/O error"]},
        observed_at,
        authorize?: false
      )

    assert retried_evidence.id == evidence.id

    assert {:error, _error} =
             Cases.append_evidence(
               incident.id,
               run.id,
               started.value.id,
               "evidence-1",
               "command_output",
               "linux-01",
               "journalctl",
               %{"lines" => ["different"]},
               observed_at,
               authorize?: false
             )

    completed =
      complete!(started.value, %{"finding" => "storage path"}, :evidence)

    assert completed.status == :charged
    assert completed.value.status == :completed
    assert completed.value.result == %{"finding" => "storage path"}

    repeated =
      complete!(started.value, %{"finding" => "storage path"}, :evidence)

    assert repeated.status == :duplicate
    assert repeated.value.id == completed.value.id

    assert [turn] = Cases.list_turns!(actor: context.viewer)
    assert turn.status == :completed
    assert turn.result == %{"finding" => "storage path"}
    assert [reloaded_evidence] = Cases.list_evidence!(actor: context.viewer)
    assert reloaded_evidence.content == %{"lines" => ["I/O error"]}

    assert Enum.map(Cases.list_case_events!(actor: context.viewer), & &1.event_type) == [
             "case_opened",
             "turn_started",
             "evidence_added",
             "turn_completed"
           ]
  end

  test "concurrent distinct charges serialize and cannot exceed the configured limit", context do
    {incident, run} = open!("concurrent-budget", context.operator)

    results =
      1..3
      |> Enum.map(fn index ->
        Task.async(fn ->
          Cases.charge_resolution_run(
            incident.id,
            run.id,
            :target_request,
            1,
            "request-#{index}",
            %{"action" => "inspect", "request" => index},
            "Increase the Target request limit or inspect manually",
            authorize?: false
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _result}, &1))
    statuses = Enum.map(results, fn {:ok, result} -> result.status end)
    assert Enum.sort(statuses) == [:charged, :charged, :exhausted]

    reloaded_run = Cases.get_resolution_run!(run.id, actor: context.viewer)
    assert reloaded_run.target_request_count == 2
    assert reloaded_run.status == :needs_attention

    reloaded_case = Cases.get_case!(incident.id, actor: context.viewer)
    assert reloaded_case.status == :needs_attention
    refute reloaded_case.status == :resolved
  end

  test "each finite limit persists its exact handoff and never marks the Case resolved",
       context do
    scenarios = [
      {:turn,
       fn incident, run ->
         start!(incident, run, "turn-at-limit", %{"action" => "inspect"})
         start!(incident, run, "turn-over-limit", %{"action" => "inspect-next"})
       end},
      {:target_request,
       fn incident, run ->
         charge!(incident, run, :target_request, 2, "target-at-limit")
         charge!(incident, run, :target_request, 1, "target-over-limit")
       end},
      {:effect,
       fn incident, run ->
         charge!(incident, run, :effect, 1, "effect-over-limit")
       end},
      {:related_target,
       fn incident, run ->
         charge!(incident, run, :related_target, 1, "related-over-limit")
       end},
      {:ai_usage,
       fn incident, run ->
         charge!(incident, run, :ai_usage, 2, "ai-over-limit")
       end},
      {:no_progress,
       fn incident, run ->
         started = start!(incident, run, "no-progress-turn", %{"action" => "inspect"})
         completed = complete!(started.value, %{"finding" => "none"}, :none)
         assert completed.status in [:charged, :duplicate]

         charge_with_limit!(
           incident,
           run,
           :target_request,
           1,
           "after-no-progress",
           "no_progress"
         )
       end},
      {:elapsed,
       fn incident, run ->
         past = DateTime.add(DateTime.utc_now(), -1, :second)

         Repo.update_all(
           from(item in ResolutionRun, where: item.id == ^run.id),
           set: [deadline_at: past]
         )

         charge_with_limit!(incident, run, :target_request, 1, "after-deadline", "elapsed")
       end}
    ]

    for {expected_limit, operation} <- scenarios do
      {incident, run} = open!("limit-#{expected_limit}", context.operator)
      pending = %{"action" => "continue", "limit" => to_string(expected_limit)}
      result = operation.(incident, run)

      assert result.status == :exhausted, "#{expected_limit} did not exhaust"
      assert result.case.status == :needs_attention
      assert result.case.pending_intent == pending
      refute result.case.status == :resolved

      replayed = operation.(incident, run)
      assert replayed.status == :exhausted
      assert replayed.reason == result.reason

      events =
        Cases.list_case_events!(actor: context.viewer)
        |> Enum.filter(&(&1.case_id == incident.id))

      assert Enum.count(events, &(&1.event_type == "limit_exhausted")) == 1
      event = List.last(events)

      assert event.event_type == "limit_exhausted"
      assert event.data["limit"] == to_string(expected_limit)
      assert event.data["pending_intent"] == pending
      assert event.data["required_human_input"] == "Review the exhausted limit"
    end
  end

  test "history has no authorized public mutation path and cancellation stops new charges",
       context do
    {incident, run} = open!("append-only", context.operator)
    started = start!(incident, run, "append-only-turn", %{"action" => "inspect"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_turn_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: run.id,
                 ordinal: 2,
                 idempotency_key: "bypass",
                 status: :started,
                 intent: %{},
                 result: %{},
                 started_at: DateTime.utc_now()
               },
               actor: context.admin
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_evidence_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: run.id,
                 turn_id: started.value.id,
                 idempotency_key: "bypass",
                 kind: "bypass",
                 source: "test",
                 source_ref: "test",
                 content: %{},
                 observed_at: DateTime.utc_now()
               },
               actor: context.admin
             )

    cancelled =
      Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert cancelled.cancel_requested

    assert {:error, _error} =
             Cases.charge_resolution_run(
               incident.id,
               run.id,
               :target_request,
               1,
               "cancelled-request",
               %{"action" => "inspect"},
               "Review cancellation",
               authorize?: false
             )
  end

  defp start!(incident, run, key, intent) do
    start(incident, run, key, intent) |> then(fn {:ok, result} -> result end)
  end

  defp start(incident, run, key, intent) do
    limit = limit_name(key)

    Cases.start_turn(
      incident.id,
      run.id,
      key,
      intent,
      %{"action" => "continue", "limit" => limit},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp complete!(turn, result, progress_kind) do
    Cases.complete_turn!(
      turn.id,
      turn.revision,
      result,
      progress_kind,
      %{"action" => "continue", "limit" => "no_progress"},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp charge!(incident, run, kind, amount, key) do
    charge(incident, run, kind, amount, key)
    |> then(fn {:ok, result} -> result end)
  end

  defp charge_with_limit!(incident, run, kind, amount, key, limit) do
    Cases.charge_resolution_run!(
      incident.id,
      run.id,
      kind,
      amount,
      key,
      %{"action" => "continue", "limit" => limit},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp charge(incident, run, kind, amount, key) do
    Cases.charge_resolution_run(
      incident.id,
      run.id,
      kind,
      amount,
      key,
      %{"action" => "continue", "limit" => to_string(kind)},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp limit_name(key) do
    cond do
      String.starts_with?(key, "no-progress") -> "no_progress"
      true -> "turn"
    end
  end

  defp open!(source_ref, actor) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        :not_applicable,
        %{},
        nil,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp configure_limits!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      60,
      1,
      2,
      0,
      0,
      1,
      1,
      "configure history acceptance",
      actor: admin
    )
  end
end
