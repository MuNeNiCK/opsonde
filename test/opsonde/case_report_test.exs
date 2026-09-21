defmodule Opsonde.CaseReportTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Reports}
  alias Opsonde.Cases.{Case, Operation, VerificationAttempt}
  alias Opsonde.Reports.Report.Content
  alias Opsonde.Reports.GenerationWorker

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("report-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("report-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("report-viewer@example.com", @password, :viewer, actor: admin)
    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "a terminal Case revision becomes one immutable localized Report", context do
    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    incident = open!("ja-report", operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    now = DateTime.utc_now()

    first_turn =
      Cases.create_turn_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          ordinal: 1,
          idempotency_key: "report-turn-1",
          status: :completed,
          intent: %{"objective" => "障害を解決する"},
          result: %{
            "intent" => %{
              "type" => "proposal",
              "reason" => "サービス停止が主因の可能性があります"
            }
          },
          progress_kind: :proposal,
          started_at: now,
          completed_at: now
        },
        authorize?: false
      )

    Cases.create_turn_record!(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        ordinal: 2,
        idempotency_key: "report-turn-2",
        status: :completed,
        intent: %{"objective" => "残る不確実性を確認する"},
        result: %{
          "intent" => %{
            "type" => "handoff",
            "reason" => "複合要因のため物理状態を確認できません",
            "required_input" => "ディスクLEDを確認してください"
          }
        },
        progress_kind: :human_input,
        started_at: DateTime.add(now, 1, :second),
        completed_at: DateTime.add(now, 1, :second)
      },
      authorize?: false
    )

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        first_turn.id,
        "report-evidence",
        "observation",
        "linux-ssh",
        "host-1",
        %{"uncertainty" => "hardware path remains unknown"},
        now,
        authorize?: false
      )

    terminal =
      Cases.update_case_record!(
        incident,
        incident.revision,
        %{
          status: :needs_attention,
          stop_reason: "複合要因の調査には現地確認が必要です",
          required_human_input: "ディスクLEDを確認してください",
          pending_intent: %{"action" => "inspect_hardware"}
        },
        authorize?: false
      )

    Cases.pause_resolution_run!(run, run.revision, authorize?: false)

    report =
      Reports.generate_report!(terminal.id, terminal.revision, actor: context.operator)

    assert report.language == :ja
    assert report.outcome == :needs_attention
    assert report.revision == 1
    assert byte_size(report.content_digest) == 64
    assert report.content["labels"]["summary"] == "概要"
    assert report.content["outcome_label"] == "対応が必要"
    assert report.content["case"]["revision"] == terminal.revision
    assert report.content["raw_evidence"] |> hd() |> Map.fetch!("id") == evidence.id
    assert length(report.content["resolver_turns"]) == 2

    assert get_in(report.content, ["resolver_turns", Access.at(1), "decision", "reason"]) ==
             "複合要因のため物理状態を確認できません"

    assert report.content["unresolved"]["required_human_input"] ==
             "ディスクLEDを確認してください"

    serialized = Jason.encode!(report.content)
    refute serialized =~ "pending_intent"
    refute serialized =~ "idempotency_key"
    refute serialized =~ "resolver_identity"
    refute serialized =~ "session_id"

    retried = Reports.generate_report!(terminal.id, terminal.revision, actor: context.operator)
    assert retried.id == report.id
    assert retried.generated_at == report.generated_at
    assert retried.content_digest == report.content_digest
    assert retried.content == report.content

    reloaded = Reports.get_report!(report.id, actor: context.viewer)
    assert reloaded.content == report.content
    assert Reports.list_reports!(actor: context.viewer) |> Enum.map(& &1.id) == [report.id]

    assert {:error, %Ash.Error.Forbidden{}} =
             Reports.generate_report(terminal.id, terminal.revision, actor: context.viewer)
  end

  test "English labels are fixed at Case open and a running Case stays unchanged on failure",
       context do
    running = open!("running-report", context.operator)

    assert {:error, _error} =
             Reports.generate_report(running.id, running.revision, actor: context.operator)

    unchanged = Cases.get_case!(running.id, actor: context.viewer)
    assert unchanged.status == :running
    assert unchanged.revision == running.revision
    assert Reports.list_reports!(actor: context.viewer) == []

    resolved =
      Cases.update_case_record!(running, running.revision, %{status: :resolved},
        authorize?: false
      )

    assert {:error, _error} =
             Reports.generate_report(resolved.id, resolved.revision + 1, actor: context.operator)

    still_resolved = Cases.get_case!(resolved.id, actor: context.viewer)
    assert still_resolved.status == :resolved
    assert still_resolved.revision == resolved.revision

    report = Reports.generate_report!(resolved.id, resolved.revision, actor: context.operator)
    assert report.content["labels"]["summary"] == "Summary"
    assert report.content["outcome_label"] == "Resolved"
  end

  test "a final automatic Report failure is persisted without claiming completion", context do
    incident = open!("failed-report", context.operator)

    assert {:error, _error} =
             GenerationWorker.perform(%Oban.Job{
               args: %{"case_id" => incident.id, "case_revision" => incident.revision},
               attempt: 3,
               max_attempts: 3
             })

    assert Reports.list_reports!(actor: context.admin) == []

    assert [event] =
             Cases.list_case_events!(actor: context.admin)
             |> Enum.filter(
               &(&1.case_id == incident.id and &1.event_type == "report_generation_failed")
             )

    assert event.resolution_run_id == nil
  end

  test "projection preserves multiple operation outcomes and raw uncertainty", _context do
    incident = %Case{
      id: Ash.UUID.generate(),
      revision: 7,
      report_language: :ja,
      status: :needs_attention,
      pending_intent: %{}
    }

    records = %{
      runs: [],
      events: [],
      turns: [],
      evidence: [],
      proposals: [],
      reviews: [],
      approvals: [],
      operations: [
        %Operation{id: Ash.UUID.generate(), status: :applied, operation: "service.restart"},
        %Operation{
          id: Ash.UUID.generate(),
          status: :unknown,
          operation: "interface.reset",
          outcome_category: "connection_lost",
          result_details: %{"uncertainty" => "remote acceptance cannot be confirmed"}
        }
      ],
      verifications: [
        %VerificationAttempt{
          id: Ash.UUID.generate(),
          status: :unknown,
          operation: "interface.inspect",
          outcome_category: "timeout",
          facts: %{"state" => "unknown"}
        }
      ]
    }

    content = Content.build(incident, records)
    assert Enum.map(content["operations"], & &1["status"]) == ["applied", "unknown"]

    assert get_in(content, ["operations", Access.at(1), "result_details", "uncertainty"]) ==
             "remote acceptance cannot be confirmed"

    assert content["verifications"] |> hd() |> Map.fetch!("status") == "unknown"
  end

  defp open!(source_ref, actor) do
    Cases.open_case!(
      :manual,
      "test",
      source_ref,
      "Case #{source_ref}",
      :warning,
      :not_applicable,
      %{"source_ref" => source_ref},
      nil,
      :en,
      actor: actor
    )
  end
end
