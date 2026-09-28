defmodule OpsondeWeb.API.V1.WorkflowControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Opsonde.{Accounts, Cases, Providers, Reports, Signals, Targets}
  alias Opsonde.Cases.Case
  alias Opsonde.Cases.Case.Realtime
  alias Opsonde.Cases.Proposal.ReviewDelivery
  alias Opsonde.Cases.CaseDispatch.Worker, as: CaseDispatchWorker
  alias Opsonde.Providers.{AI, Signal}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("workflow-api-admin@example.com", @password, @password,
        authorize?: true
      )

    operator =
      Accounts.create_user!("workflow-api-operator@example.com", @password, :operator,
        actor: admin
      )

    next_operator =
      Accounts.create_user!("workflow-api-next@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("workflow-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin: admin,
      operator: operator,
      next_operator: next_operator,
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  test "public manual Case creation durably dispatches one investigation", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "manual-entry-once",
        "title" => "Investigate guest availability",
        "severity" => "warning",
        "initial_context" => %{
          "observed_problem" => "Guest unavailable",
          "desired_outcome" => "Guest responds to the health check"
        }
      }
    }

    first = post_json("/api/v1/cases", body, context.operator_token) |> json_response(201)
    second = post_json("/api/v1/cases", body, context.operator_token) |> json_response(201)
    incident_id = first["data"]["id"]
    assert second["data"]["id"] == incident_id

    assert first["data"]["case_symptom"]["desired_outcome"] ==
             "Guest responds to the health check"

    changed =
      put_in(body, ["case", "initial_context", "desired_outcome"], "Guest remains unavailable")
      |> then(&post_json("/api/v1/cases", &1, context.operator_token))

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(changed, 422)

    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :collecting

    assert [_job] =
             Opsonde.Repo.all(Oban.Job)
             |> Enum.filter(
               &(&1.worker == "Opsonde.Cases.CaseDispatch.Worker" and
                   &1.args["case_id"] == incident_id)
             )

    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident_id}})
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident_id}})

    run = Cases.active_resolution_run!(incident_id, authorize?: false)
    assert run.turn_count == 1
    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :sent

    assert [%{"status" => "started", "ordinal" => 1}] =
             get_data!("/api/v1/cases/#{incident_id}/turns", context.viewer_token)
             |> Enum.map(&Map.take(&1, ["status", "ordinal"]))
  end

  test "public Case creation publishes its changes only after commit", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "notification-on-commit",
        "title" => "Check notification timing",
        "severity" => "warning",
        "initial_context" => %{"desired_outcome" => "Target responds as expected"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, case_id} =
                 Ash.transact(Case, fn ->
                   response = post_json("/api/v1/cases", body, context.operator_token)
                   %{"data" => %{"id" => case_id}} = json_response(response, 201)
                   :ok = Realtime.subscribe(case_id)
                   refute_receive {:case_changed, ^case_id}, 20
                   case_id
                 end)

        for _ <- 1..3, do: assert_receive({:case_changed, ^case_id})
        refute_receive {:case_changed, ^case_id}, 100
      end)

    refute log =~ "Missed"
  end

  test "public manual Case creation requires an explicit desired outcome", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "missing-desired-outcome",
        "title" => "Check service",
        "severity" => "warning",
        "initial_context" => %{"observed_problem" => "Service stopped"}
      }
    }

    response = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(response, 400)
    assert Cases.list_cases!(actor: context.admin) == []
  end

  test "direct audit Case creation is rejected before an idle Case is stored", context do
    body = %{
      "case" => %{
        "trigger_kind" => "audit",
        "source" => "api",
        "source_ref" => "unsupported-direct-audit",
        "title" => "Inspect storage health",
        "severity" => "info",
        "initial_context" => %{"desired_outcome" => "Storage health is normal"}
      }
    }

    response = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    assert Cases.list_cases!(actor: context.admin) == []
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "manual Case and its dispatch job roll back together before a safe retry", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "rolled-back-manual-entry",
        "title" => "Investigate a rolled back request",
        "severity" => "warning",
        "initial_context" => %{"desired_outcome" => "Target responds as expected"}
      }
    }

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 Ash.transact(Case, fn ->
                   response = post_json("/api/v1/cases", body, context.operator_token)
                   assert %{"data" => %{"id" => case_id}} = json_response(response, 201)
                   :ok = Realtime.subscribe(case_id)
                   send(self(), {:rolled_back_case, case_id})
                   {:error, :simulated_persistence_failure}
                 end)

        assert_receive {:rolled_back_case, rolled_back_id}
        refute_receive {:case_changed, ^rolled_back_id}, 100
      end)

    refute log =~ "Missed"

    assert Cases.list_cases!(actor: context.admin) == []
    assert Opsonde.Repo.all(Oban.Job) == []

    accepted = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"data" => %{"id" => incident_id}} = json_response(accepted, 201)
    assert [_dispatch] = Cases.list_cases!(actor: context.admin)
    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :collecting
  end

  test "Case queue search, filters, and sorting are applied before pagination", context do
    older = open_case!(context.operator_token, "queue-older", "warning")
    newer = open_case!(context.operator_token, "queue-newer", "critical")

    searched = get_json("/api/v1/cases?query=QUEUE-OLDER", context.viewer_token)

    assert %{"data" => [%{"id" => searched_id}], "page" => %{"next" => nil}} =
             json_response(searched, 200)

    assert searched_id == older["id"]
    assert_operation_response(searched)

    sorted = get_json("/api/v1/cases?sort=severity_desc", context.viewer_token)

    assert [%{"id" => first_id}, %{"id" => second_id}] = json_response(sorted, 200)["data"]
    assert [first_id, second_id] == [newer["id"], older["id"]]
    assert_operation_response(sorted)

    filtered = get_json("/api/v1/cases?status=resolved", context.viewer_token)
    assert %{"data" => [], "page" => %{"next" => nil}} = json_response(filtered, 200)
    assert_operation_response(filtered)

    invalid = get_json("/api/v1/cases?status=unknown", context.viewer_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)
  end

  test "authenticated Case snapshot and split expose native Condition ownership", context do
    current = Cases.current_authority_setting!(actor: context.admin)

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
      "Enable Signal intake for Case API",
      actor: context.admin
    )

    provider =
      Providers.create_provider!(
        "case-api-signal",
        :signal,
        "fixture-signal",
        %{"source" => "case-api-monitor"},
        %{"secret" => "case-api-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target =
      Targets.create_target!("case-api-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "case-api-monitor",
      "hostname",
      "case-api-host",
      actor: context.admin
    )

    now = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for name <- ["api.service", "db.service"] do
        %Signal.Event{
          receipt_id: "case-api-receipt",
          event_key: name,
          state: :firing,
          occurred_at: now,
          target_ref: %{kind: :hostname, value: "case-api-host"},
          attributes: %{"labels" => %{"service" => name, "alertname" => "ServiceUnavailable"}}
        }
      end

    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: "case-api-receipt", headers: %{}, received_at: now},
      %{
        authenticate: fn adapter, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: "case-api-receipt", source: adapter.source}}
        end,
        normalize: fn _adapter, _envelope, _receipt -> {:ok, events} end
      }
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    listed = get_data!("/api/v1/cases", context.viewer_token)
    assert [%{"id" => listed_id, "condition_count" => 2, "firing_condition_count" => 2}] = listed
    assert listed_id == incident.id
    assert %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert length(snapshot["conditions"]) == 2
    assert length(snapshot["condition_history"]) == 2

    refs = Enum.map(snapshot["conditions"], & &1["subject_ref"])
    assert Enum.all?(refs, &(&1["kind"] == "native_labels" and is_binary(&1["digest"])))
    assert length(Enum.uniq(refs)) == 2

    revisions =
      snapshot["conditions"]
      |> Enum.map(&Map.take(&1, ["id", "revision"]))
      |> Enum.sort_by(& &1["id"])

    db_condition_id =
      Signals.list_signal_events!(actor: context.admin)
      |> Enum.find(&(&1.event_key == "db.service"))
      |> Map.fetch!(:condition_id)

    [moved] = Enum.filter(snapshot["conditions"], &(&1["id"] == db_condition_id))

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => revisions,
        "condition_groups" => [
          %{
            "condition_ids" => Enum.map(revisions, & &1["id"]),
            "assessment" => "unknown",
            "reason" => "No common cause observation yet",
            "evidence_ids" => []
          }
        ],
        "intent" => %{"type" => "handoff", "reason" => "Investigate separately"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review Resolver decision",
      authorize?: false
    )

    turns = get_data!("/api/v1/cases/#{incident.id}/turns", context.viewer_token)

    assert [
             %{
               "condition_revisions" => ^revisions,
               "condition_groups" => [%{"assessment" => "unknown"}]
             }
           ] = turns

    parent = Cases.get_case!(incident.id, authorize?: false)

    body = %{
      "case" => %{
        "expected_revision" => parent.revision,
        "condition_ids" => [moved["id"]],
        "expected_conditions" => revisions,
        "reason" => "Independent database failure"
      }
    }

    denied = post_json("/api/v1/cases/#{parent.id}/split", body, context.viewer_token)
    assert json_response(denied, 403)["error"]["code"] == "forbidden"

    stale_membership =
      body
      |> put_in(
        ["case", "expected_conditions"],
        List.update_at(
          revisions,
          0,
          &Map.update!(&1, "revision", fn revision -> revision + 1 end)
        )
      )
      |> then(&post_json("/api/v1/cases/#{parent.id}/split", &1, context.operator_token))

    assert json_response(stale_membership, 409)["error"]["code"] == "conflict"

    response = post_json("/api/v1/cases/#{parent.id}/split", body, context.operator_token)

    assert %{"data" => %{"id" => child_id, "split_parent_id" => parent_id}} =
             json_response(response, 200)

    assert_operation_response(response)
    assert parent_id == parent.id

    stale_revision =
      body
      |> put_in(["case", "reason"], "Stale Case revision")
      |> then(&post_json("/api/v1/cases/#{parent.id}/split", &1, context.operator_token))

    assert json_response(stale_revision, 409)["error"]["code"] == "conflict"

    parent_snapshot = get_data!("/api/v1/cases/#{parent.id}", context.viewer_token)
    child_snapshot = get_data!("/api/v1/cases/#{child_id}", context.viewer_token)
    assert length(parent_snapshot["conditions"]) == 1
    assert Enum.map(child_snapshot["conditions"], & &1["id"]) == [moved["id"]]
    assert hd(parent_snapshot["conditions"])["id"] != moved["id"]

    assert Enum.sort(
             Enum.map(get_data!("/api/v1/cases", context.viewer_token), & &1["condition_count"])
           ) == [1, 1]

    assert length(parent_snapshot["condition_history"]) == 2
    assert length(child_snapshot["condition_history"]) == 1
    assert Enum.any?(parent_snapshot["condition_history"], &(&1["detached_at"] != nil))

    timeline = get_data!("/api/v1/cases/#{parent.id}/timeline", context.viewer_token)
    assert Enum.any?(timeline, &(&1["related_case_id"] == child_id))
  end

  test "authority and Case lifecycle remain revisioned and reconnectable", context do
    current = get_data!("/api/v1/authority-setting", context.viewer_token)
    assert current["authority_mode"] == "readonly"
    assert current["setting_revision"] == 1

    configured =
      put_json(
        "/api/v1/authority-setting",
        %{
          "authority_setting" =>
            current
            |> Map.take([
              "authority_mode",
              "signal_automation_enabled",
              "max_elapsed_seconds",
              "max_resolver_turns",
              "max_target_requests",
              "max_effects",
              "max_related_targets",
              "max_ai_usage_units",
              "max_no_progress_turns"
            ])
            |> Map.merge(%{
              "expected_setting_revision" => current["setting_revision"],
              "authority_mode" => "ask",
              "reason" => "require operator approval"
            })
        },
        context.admin_token
      )

    assert %{"data" => %{"authority_mode" => "ask", "setting_revision" => 2}} =
             json_response(configured, 200)

    assert_operation_response(configured)

    authority_history = get_json("/api/v1/authority-settings", context.viewer_token)
    assert %{"data" => [_, _], "page" => %{"next" => nil}} = json_response(authority_history, 200)
    assert_operation_response(authority_history)

    stale_setting =
      put_json(
        "/api/v1/authority-setting",
        %{
          "authority_setting" => %{
            "expected_setting_revision" => 1,
            "authority_mode" => "readonly",
            "signal_automation_enabled" => false,
            "max_elapsed_seconds" => 3600,
            "max_resolver_turns" => 20,
            "max_target_requests" => 100,
            "max_effects" => 10,
            "max_related_targets" => 20,
            "max_ai_usage_units" => 1_000_000,
            "max_no_progress_turns" => 3,
            "reason" => "stale authority update"
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale_setting, 409)

    language =
      patch_json(
        "/api/v1/account/language",
        %{"account" => %{"preferred_language" => "ja"}},
        context.operator_token
      )

    assert %{"data" => %{"preferred_language" => "ja"}} = json_response(language, 200)

    incident = open_case!(context.operator_token, "lifecycle-1")
    assert incident["status"] == "running"
    assert incident["operator_action"] == "none"
    assert incident["authority_mode"] == "ask"
    assert incident["report_language"] == "ja"

    cases = get_json("/api/v1/cases", context.viewer_token)
    assert %{"data" => [%{"id" => case_id}]} = json_response(cases, 200)
    assert case_id == incident["id"]
    assert_operation_response(cases)

    claimed =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => incident["revision"]}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 2, "current_owner_id" => owner_id}} =
             json_response(claimed, 200)

    assert_operation_response(claimed)

    assert owner_id == context.operator.id

    retried_claim =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => incident["revision"]}},
        context.operator_token
      )

    assert json_response(retried_claim, 200)["data"] == json_response(claimed, 200)["data"]

    handed_off =
      post_json(
        "/api/v1/cases/#{incident["id"]}/handoff",
        %{"case" => %{"expected_revision" => 2, "owner_id" => context.next_operator.id}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 3, "current_owner_id" => next_owner}} =
             json_response(handed_off, 200)

    assert next_owner == context.next_operator.id
    assert_operation_response(handed_off)

    cancelled =
      post_json(
        "/api/v1/cases/#{incident["id"]}/cancel",
        %{"case" => %{"expected_revision" => 3}},
        token!(context.next_operator.email)
      )

    assert %{
             "data" => %{
               "revision" => 4,
               "cancel_requested" => true,
               "status" => "cancelled"
             }
           } =
             json_response(cancelled, 200)

    assert_operation_response(cancelled)

    report = Reports.generate_report!(incident["id"], 4, actor: context.operator)

    snapshot = get_json("/api/v1/cases/#{incident["id"]}", context.viewer_token)

    assert %{
             "data" => %{
               "case" => %{"id" => case_id, "revision" => 4},
               "resolution_runs" => [
                 %{"generation" => 1, "status" => "cancelled", "active" => false}
               ],
               "proposals" => [],
               "operations" => [],
               "verification_attempts" => [],
               "reports" => [%{"id" => report_id, "case_revision" => 4}]
             }
           } = json_response(snapshot, 200)

    assert_operation_response(snapshot)

    assert case_id == incident["id"]
    assert report_id == report.id
    refute snapshot.resp_body =~ "pending_intent"
    refute snapshot.resp_body =~ "idempotency_key"

    timeline = get_json("/api/v1/cases/#{incident["id"]}/timeline?limit=2", context.viewer_token)

    assert %{"data" => first_events, "page" => %{"next" => cursor}} =
             json_response(timeline, 200)

    assert_operation_response(timeline)

    assert Enum.map(first_events, & &1["type"]) == ["case_opened", "case_claimed"]
    assert is_binary(cursor)
    refute timeline.resp_body =~ "idempotency_key"
    refute Enum.any?(first_events, &Map.has_key?(&1, "data"))

    viewer_mutation =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => 4}},
        context.viewer_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_mutation, 403)
  end

  test "a needs-attention Case resumes once with extended limits", context do
    incident = open_case!(context.operator_token, "resume-1")
    run = Cases.active_resolution_run!(incident["id"], authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident["id"],
        incident["revision"],
        run.id,
        run.revision,
        "workflow-api-attention",
        "Resolver turn limit exhausted",
        %{"kind" => "observe"},
        "Extend limits or investigate manually",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    lower_limits =
      resume_input(attention, paused_run, paused_run.revision)
      |> Map.put("max_resolver_turns", paused_run.max_resolver_turns - 1)

    rejected =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{"case" => lower_limits},
        context.operator_token
      )

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => fields}}} =
             json_response(rejected, 422)

    assert "max_resolver_turns" in fields
    assert Cases.active_resolution_run!(incident["id"], authorize?: false).id == paused_run.id

    stale =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{
          "case" => resume_input(attention, paused_run, paused_run.revision + 1)
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    resumed =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{"case" => resume_input(attention, paused_run, paused_run.revision)},
        context.operator_token
      )

    assert %{"data" => %{"generation" => 2, "status" => "running", "active" => true}} =
             json_response(resumed, 200)

    assert_operation_response(resumed)

    snapshot = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)
    assert snapshot["case"]["status"] == "running", inspect(snapshot["case"])
    assert Enum.map(snapshot["resolution_runs"], & &1["generation"]) == [2, 1]
    assert Enum.map(snapshot["resolution_runs"], & &1["status"]) == ["running", "superseded"]

    assert %{"data" => [%{"status" => "started", "ordinal" => 1}]} =
             "/api/v1/cases/#{incident["id"]}/turns"
             |> get_json(context.viewer_token)
             |> json_response(200)
  end

  test "Proposal decision and status polling never dispatch an effect from HTTP", context do
    configure_mode!(:ask, context.admin)
    setup = proposal_setup!(context)
    {incident, proposal} = awaiting_proposal!(setup, context.operator)

    wrong_digest =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        %{
          "proposal" => %{
            "expected_revision" => proposal.revision,
            "proposal_digest" => String.duplicate("0", 64),
            "decision" => "approved",
            "reason" => "stale proposal input"
          }
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(wrong_digest, 409)

    decision_body = %{
      "proposal" => %{
        "expected_revision" => proposal.revision,
        "proposal_digest" => proposal.proposal_digest,
        "decision" => "approved",
        "reason" => "the evidence supports this exact restart"
      }
    }

    approved =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        decision_body,
        context.operator_token
      )

    assert %{"data" => %{"status" => "authorized", "revision" => approved_revision}} =
             json_response(approved, 200)

    assert_operation_response(approved)

    assert approved_revision > proposal.revision

    proposal_response = get_json("/api/v1/proposals/#{proposal.id}", context.viewer_token)
    assert %{"data" => %{"id" => proposal_id}} = json_response(proposal_response, 200)
    assert proposal_id == proposal.id
    assert_operation_response(proposal_response)

    duplicate =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        decision_body,
        context.operator_token
      )

    assert json_response(duplicate, 200)["data"] == json_response(approved, 200)["data"]
    assert length(Cases.list_approvals!(actor: context.admin)) == 1
    assert Cases.list_operations!(actor: context.admin) == []

    turns = get_json("/api/v1/cases/#{incident.id}/turns", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "ordinal" => 1,
                 "status" => "completed",
                 "outcome" => "decision",
                 "decision" => %{"type" => "proposal"},
                 "progress_kind" => "proposal"
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(turns, 200)

    assert_operation_response(turns)

    evidence = get_json("/api/v1/cases/#{incident.id}/evidence", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "kind" => "observation",
                 "source" => "fixture",
                 "source_ref" => "observation-1",
                 "content" => %{"service" => "unhealthy"}
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(evidence, 200)

    assert_operation_response(evidence)

    approvals = get_json("/api/v1/cases/#{incident.id}/approvals", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "proposal_id" => proposal_id,
                 "decision" => "approved",
                 "source" => "human",
                 "reason" => "the evidence supports this exact restart"
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(approvals, 200)

    assert_operation_response(approvals)

    assert proposal_id == proposal.id

    assert %{"data" => [], "page" => %{"next" => nil}} =
             get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)
             |> json_response(200)

    for response <- [turns, evidence, approvals] do
      refute response.resp_body =~ "idempotency_key"
      refute response.resp_body =~ "resolver-secret"
      refute response.resp_body =~ "provider-secret"
      refute response.resp_body =~ "clearance_digest"
      refute response.resp_body =~ "session_id"
    end

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    operation_response = get_json("/api/v1/operations/#{operation.id}", context.viewer_token)

    assert %{"data" => %{"id" => operation_id, "status" => "queued"}} =
             json_response(operation_response, 200)

    assert_operation_response(operation_response)

    assert operation_id == operation.id
    assert Cases.get_operation!(operation.id, authorize?: false).revision == operation.revision

    assert :ok =
             Opsonde.Cases.Operation.Delivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok,
                    %Opsonde.Providers.Target.EffectResult{
                      status: :applied,
                      reference: "remote-operation-1",
                      details: %{"changed" => true}
                    }}
                 end
               }
             )

    assert_receive {:effect, _state, _request}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    verification_response =
      get_json("/api/v1/verification-attempts/#{attempt.id}", context.viewer_token)

    assert %{"data" => %{"id" => attempt_id, "status" => "queued"}} =
             json_response(verification_response, 200)

    assert_operation_response(verification_response)

    assert attempt_id == attempt.id

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert Enum.map(snapshot["proposals"], & &1["status"]) == ["authorized"]
    assert Enum.map(snapshot["operations"], & &1["status"]) == ["applied"]
    assert Enum.map(snapshot["verification_attempts"], & &1["status"]) == ["queued"]

    for response <- [operation_response, verification_response] do
      refute response.resp_body =~ "authorization_digest"
      refute response.resp_body =~ "policy_context"
      refute response.resp_body =~ "idempotency_key"
      refute response.resp_body =~ "provider-secret"
    end
  end

  test "expired Proposal decision returns conflict and stops the Case", context do
    configure_mode!(:ask, context.admin)
    setup = proposal_setup!(context)
    {incident, proposal} = awaiting_proposal!(setup, context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    Opsonde.Repo.update_all(
      from(item in Opsonde.Cases.Proposal, where: item.id == ^proposal.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    expired =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        %{
          "proposal" => %{
            "expected_revision" => proposal.revision,
            "proposal_digest" => proposal.proposal_digest,
            "decision" => "approved",
            "reason" => "Approval arrived after expiry"
          }
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "proposal_expired"}} = json_response(expired, 409)
    assert_operation_response(expired)
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
  end

  test "auto Reviewer decisions and their exact approval are reconnectable without AI sessions",
       context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert reviewing.status == :reviewing

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      reason: "The cited evidence supports this exact change",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, %{api_key: "reviewer-secret"}, _request}

    response =
      get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "proposal_id" => proposal_id,
                 "outcome" => "decision",
                 "verdict" => "approved",
                 "selection_source" => "assignment",
                 "provider_id" => reviewer_id,
                 "input_tokens" => 3,
                 "output_tokens" => 2
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(response, 200)

    assert_operation_response(response)

    assert proposal_id == reviewing.id
    assert reviewer_id == setup.reviewer.id

    assert %{"data" => [%{"proposal_id" => ^proposal_id, "source" => "reviewer"}]} =
             get_json("/api/v1/cases/#{incident.id}/approvals", context.viewer_token)
             |> json_response(200)

    refute response.resp_body =~ "session_id"
    refute response.resp_body =~ "resolver_session_id"
    refute response.resp_body =~ "assignment_id"
    refute response.resp_body =~ "proposal_digest"
    refute response.resp_body =~ "reviewer-secret"
  end

  test "unexpected Reviewer failures stop for provider repair without creating an approval",
       context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> raise "credential internal-review-secret" end
               }
             )

    response =
      get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)

    assert %{"data" => [], "page" => %{"next" => nil}} = json_response(response, 200)

    assert_operation_response(response)

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention

    assert stopped.pending_intent == %{
             "action" => "restore_reviewer_delivery",
             "proposal_id" => reviewing.id
           }

    assert stopped.required_human_input == "Restore Reviewer AI availability and resume the Case"
    assert Cases.get_proposal!(reviewing.id, authorize?: false).status == :invalidated

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["case"]["operator_action"] == "intervention_required"

    refute response.resp_body =~ "internal-review-secret"
    refute response.resp_body =~ "RuntimeError"
  end

  test "an explicit Reviewer handoff is exposed as an operator decision", context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :needs_human,
                      reason: "The evidence requires an operator decision",
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                    }}
                 end
               }
             )

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["case"]["status"] == "running"
    assert snapshot["case"]["operator_action"] == "decision_required"
    assert [%{"status" => "awaiting_human"}] = snapshot["proposals"]
  end

  test "contract rejects malformed Case identifiers and action bodies", context do
    invalid_id = get_json("/api/v1/cases/not-a-uuid", context.viewer_token)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => ["id"]}}} =
             json_response(invalid_id, 422)

    assert_operation_response(invalid_id)

    incident = open_case!(context.operator_token, "invalid-action-contract")

    invalid_revision =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => 0}},
        context.operator_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["expected_revision"]}
             }
           } = json_response(invalid_revision, 422)

    assert_operation_response(invalid_revision)
  end

  defp resume_input(incident, run, expected_run_revision) do
    %{
      "expected_case_revision" => incident.revision,
      "resolution_run_id" => run.id,
      "expected_run_revision" => expected_run_revision,
      "authority_mode" => Atom.to_string(run.authority_mode),
      "max_elapsed_seconds" => run.max_elapsed_seconds + 60,
      "max_resolver_turns" => run.max_resolver_turns + 1,
      "max_target_requests" => run.max_target_requests,
      "max_effects" => run.max_effects,
      "max_related_targets" => run.max_related_targets,
      "max_ai_usage_units" => run.max_ai_usage_units,
      "max_no_progress_turns" => run.max_no_progress_turns,
      "reason" => "extend the bounded investigation"
    }
  end

  defp proposal_setup!(context) do
    provider =
      Providers.create_provider!(
        "workflow-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "provider-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target =
      Targets.create_target!("workflow-linux", "host", "linux", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "workflow-ssh",
        "linux",
        "ssh",
        "ssh://workflow-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: context.admin
      )

    resolver =
      Providers.create_provider!(
        "workflow-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    assignment =
      Opsonde.TestAIUsage.configure!(resolver.id, :resolver, 10, context.admin)
      |> Map.fetch!(:resolver)

    reviewer =
      Providers.create_provider!(
        "workflow-reviewer",
        :ai,
        "fixture-ai",
        %{"model" => "reviewer-model"},
        %{"api_key" => "reviewer-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    reviewer_assignment =
      Opsonde.TestAIUsage.configure!(reviewer.id, :reviewer, 10, context.admin)
      |> Map.fetch!(:reviewer)

    %{
      provider: provider,
      target: target,
      method: method,
      resolver: resolver,
      assignment: assignment,
      reviewer: reviewer,
      reviewer_assignment: reviewer_assignment
    }
  end

  defp awaiting_proposal!(setup, operator) do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "proposal-1",
        "Restart unhealthy service",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        setup.target.id,
        :en,
        actor: operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "workflow-evidence",
        "observation",
        "fixture",
        "observation-1",
        %{"service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "workflow-turn",
        %{"objective" => "Restore the service"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(evidence.id, setup),
          "resolver" => %{
            "provider_id" => setup.resolver.id,
            "provider_revision" => setup.resolver.revision,
            "assignment_id" => setup.assignment.id,
            "assignment_revision" => setup.assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    {incident, Cases.route_proposal_authority!(proposal.id, authorize?: false)}
  end

  defp proposal_intent(evidence_id, setup) do
    tool = %{
      "request_kind" => "effect",
      "id" => "effect-tool",
      "target_id" => setup.target.id,
      "target_revision" => setup.target.revision,
      "access_method_id" => setup.method.id,
      "access_method_revision" => setup.method.revision,
      "provider_id" => setup.provider.id,
      "provider_revision" => setup.provider.revision,
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
      "affected_conditions" => [],
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
        "target_id" => setup.target.id,
        "target_revision" => setup.target.revision,
        "access_method_id" => setup.method.id,
        "access_method_revision" => setup.method.revision,
        "provider_id" => setup.provider.id,
        "provider_revision" => setup.provider.revision,
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
      "workflow API mode",
      actor: admin
    )
  end

  defp open_case!(token, source_ref, severity \\ "warning") do
    response =
      post_json(
        "/api/v1/cases",
        %{
          "case" => %{
            "trigger_kind" => "manual",
            "source" => "api",
            "source_ref" => source_ref,
            "title" => "Investigate #{source_ref}",
            "severity" => severity,
            "initial_context" => %{"desired_outcome" => "Target responds as expected"}
          }
        },
        token
      )

    assert_operation_response(response)

    response
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp get_data!(path, token) do
    response = get_json(path, token)
    assert_operation_response(response)
    response |> json_response(200) |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => to_string(email), "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token), do: request(:get, path, nil, token)
  defp post_json(path, body, token), do: request(:post, path, body, token)
  defp put_json(path, body, token), do: request(:put, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
