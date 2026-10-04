defmodule OpsondeWeb.API.V1.OutcomeControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Opsonde.{Accounts, Audits, Cases, Notifications, Providers, Reports, Signals, Targets}
  alias Opsonde.Notifications.Delivery.Dispatch
  alias Opsonde.Providers.Notification
  alias Opsonde.Providers.Signal

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("outcome-api-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("outcome-api-operator@example.com", @password, :operator,
        actor: admin
      )

    viewer =
      Accounts.create_user!("outcome-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  @tag delivery_summary: true
  test "Report delivery badges and history remain complete when one Report has more than a page of deliveries",
       context do
    [older_report, busy_report, missing_report] =
      for name <- ~w(older busy missing) do
        incident =
          post_data!(
            "/api/v1/cases",
            %{
              "case" => %{
                "trigger_kind" => "manual",
                "source" => "api",
                "source_ref" => "delivery-summary-#{name}",
                "title" => "Delivery summary #{name}",
                "severity" => "warning",
                "initial_context" => %{"desired_outcome" => "Host responds"}
              }
            },
            context.operator_token
          )

        cancelled =
          post_json(
            "/api/v1/cases/#{incident["id"]}/cancel",
            %{"case" => %{"expected_revision" => 1}},
            context.operator_token
          )
          |> json_response(200)

        post_data!(
          "/api/v1/cases/#{incident["id"]}/reports",
          %{"report" => %{"expected_case_revision" => cancelled["data"]["revision"]}},
          context.operator_token
        )
      end

    provider =
      Providers.create_provider!(
        "delivery-summary-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "summary-webhook"},
        %{"token" => "summary-fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    deliveries =
      for {report, index} <- [{older_report, 0} | for(index <- 1..51, do: {busy_report, index})] do
        post_json(
          "/api/v1/deliveries",
          %{
            "delivery" => %{
              "report_id" => report["id"],
              "report_revision" => report["revision"],
              "provider_id" => provider.id,
              "provider_revision" => provider.revision,
              "idempotency_key" => "delivery-summary-#{index}"
            }
          },
          context.operator_token
        )
        |> json_response(202)
        |> Map.fetch!("data")
      end

    oldest = hd(deliveries)
    latest = List.last(deliveries)
    report_ids = Enum.map_join([older_report, busy_report, missing_report], ",", & &1["id"])
    path = "/api/v1/deliveries/latest?report_ids=" <> report_ids
    response = get_json(path, context.viewer_token)
    records = json_response(response, 200)["data"]
    assert_operation_response(response)
    assert length(records) == 2
    assert Enum.sort(Enum.map(records, & &1["id"])) == Enum.sort([oldest["id"], latest["id"]])

    assert Enum.all?(
             records,
             &(Enum.sort(Map.keys(&1)) ==
                 Enum.sort(
                   ~w(id report_id report_revision provider_id provider_revision destination_id destination_revision status reference enqueued_at dispatch_started_at completed_at revision)
                 ))
           )

    assert {:ok, dispatched} =
             Dispatch.run(latest["id"], %{
               test_pid: self(),
               respond: fn ->
                 {:ok,
                  %Notification.Result{
                    status: :delivered,
                    reference: "summary-receipt",
                    details: %{"message" => String.duplicate("x", 30_000)}
                  }}
               end
             })

    assert dispatched.status == :delivered
    changed = get_data!(path, context.operator_token)

    assert %{"status" => "delivered", "revision" => 3, "reference" => "summary-receipt"} =
             Enum.find(changed, &(&1["id"] == latest["id"]))

    full = get_data!("/api/v1/deliveries/#{latest["id"]}", context.viewer_token)
    assert byte_size(full["details"]["message"]) == 30_000

    history_path = "/api/v1/deliveries/summaries?report_ids=#{busy_report["id"]}"
    history = get_json(history_path, context.viewer_token)
    first_page = json_response(history, 200)
    assert_operation_response(history)
    assert length(first_page["data"]) == 50
    assert hd(first_page["data"])["id"] == latest["id"]
    assert byte_size(history.resp_body) < 30_000

    assert Enum.all?(
             first_page["data"],
             &(&1["report_id"] == busy_report["id"] and not Map.has_key?(&1, "details"))
           )

    next =
      get_json(
        history_path <> "&after=" <> URI.encode_www_form(first_page["page"]["next"]),
        context.viewer_token
      )

    assert %{"data" => [%{"id" => tail_id}], "page" => %{"next" => nil}} =
             json_response(next, 200)

    assert tail_id == Enum.at(deliveries, 1)["id"]
    assert_operation_response(next)

    assert get_data!(
             "/api/v1/deliveries/latest?report_ids=#{missing_report["id"]}",
             context.admin_token
           ) == []

    root =
      Path.join(System.tmp_dir!(), "delivery-summary-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      OpsondeCLI.Config.save(
        %{"server" => "https://opsonde.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &OpsondeWeb.Endpoint.call(&1, OpsondeWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    cli_latest =
      capture_io(fn ->
        assert OpsondeCLI.CLI.run(["delivery", "latest", "--report-ids", report_ids], runtime) ==
                 0
      end)
      |> Jason.decode!()

    assert cli_latest["data"] == changed

    cli_history =
      capture_io(fn ->
        assert OpsondeCLI.CLI.run(
                 [
                   "delivery",
                   "summaries",
                   "--report-ids",
                   busy_report["id"],
                   "--after",
                   first_page["page"]["next"]
                 ],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert cli_history["outcome"] == "succeeded"
    assert Map.take(cli_history, ["data", "page"]) == json_response(next, 200)

    first_busy = Enum.at(deliveries, 1)

    Opsonde.Repo.query!(
      "UPDATE deliveries SET enqueued_at = (SELECT enqueued_at FROM deliveries WHERE id = $1) WHERE id = $2",
      [Ecto.UUID.dump!(latest["id"]), Ecto.UUID.dump!(first_busy["id"])]
    )

    expected_tie_id = Enum.max([first_busy["id"], latest["id"]])

    assert [%{"id" => ^expected_tie_id}] =
             get_data!(
               "/api/v1/deliveries/latest?report_ids=#{busy_report["id"]}",
               context.viewer_token
             )
  end

  @tag delivery_summary: true
  test "Delivery summaries reject unbounded reference reads and expose storage faults", context do
    ids = for(_ <- 1..100, do: Ecto.UUID.generate()) |> Enum.join(",")
    latest = "/api/v1/deliveries/latest"
    summaries = "/api/v1/deliveries/summaries"
    assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
    assert get_data!(summaries <> "?report_ids=" <> ids, context.operator_token) == []
    assert get_data!(summaries, context.admin_token) == []
    missing = get_json(latest, context.admin_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(missing, 400)
    assert_operation_response(missing)

    for path <- [latest, summaries] do
      assert get_json(path, nil).status == 401

      for invalid <- ["", "not-a-uuid", Ecto.UUID.generate() <> "," <> ids] do
        failed = get_json(path <> "?report_ids=" <> invalid, context.viewer_token)
        assert %{"error" => %{"code" => "validation_failed"}} = json_response(failed, 422)
        assert_operation_response(failed)
      end
    end

    Opsonde.Repo.query!("ALTER TABLE deliveries RENAME COLUMN details TO unavailable_details")

    try do
      assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
      assert get_data!(summaries, context.viewer_token) == []
    after
      Opsonde.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_details TO details")
    end

    Opsonde.Repo.query!("ALTER TABLE deliveries RENAME COLUMN status TO unavailable_status")

    try do
      capture_log(fn ->
        for path <- [latest <> "?report_ids=" <> ids, summaries] do
          failed = get_json(path, context.viewer_token)
          assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
          refute Map.has_key?(json_response(failed, 500), "data")
        end
      end)
    after
      Opsonde.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_status TO status")
    end

    assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
    assert get_data!(summaries, context.viewer_token) == []
  end

  @tag report_page_capacity: true
  test "maximum immutable Report bodies remain exact while the public index contains only metadata",
       context do
    incident =
      Cases.open_case!(
        :manual,
        "fixture",
        "report-capacity",
        "Report capacity",
        :warning,
        %{"desired_outcome" => "Inspect retained results"},
        nil,
        :en,
        actor: context.operator
      )

    content = %{
      "outcome_label" => "Resolved",
      "case" => %{
        "id" => incident.id,
        "title" => incident.title,
        "severity" => "warning",
        "source" => "fixture",
        "source_ref" => "report-capacity",
        "inserted_at" => DateTime.to_iso8601(incident.inserted_at),
        "updated_at" => DateTime.to_iso8601(incident.updated_at)
      },
      "padding" => "",
      "operations" =>
        for(_ <- 1..3, do: %{"id" => Ecto.UUID.generate(), "purpose" => "investigation"}),
      "verifications" =>
        for(_ <- 1..2, do: %{"id" => Ecto.UUID.generate(), "status" => "verified"})
    }

    padding = String.duplicate("x", 10_485_760 - byte_size(Jason.encode!(content)))
    content = Map.put(content, "padding", padding)
    assert byte_size(Jason.encode!(content)) == 10_485_760
    digest = :crypto.hash(:sha256, Jason.encode!(content)) |> Base.encode16(case: :lower)

    report_ids =
      for revision <- 1..51 do
        Reports.create_report_record!(
          %{
            case_id: incident.id,
            case_revision: revision,
            language: :en,
            outcome: :resolved,
            content: content,
            content_digest: digest,
            generated_at: DateTime.add(incident.inserted_at, revision)
          },
          authorize?: false
        ).id
      end

    page = Reports.page_reports!(actor: context.viewer)
    assert length(page.results) == 50

    assert Enum.all?(
             page.results,
             &match?(%Ash.NotLoaded{type: :attribute, field: :content}, &1.content)
           )

    response = get_json("/api/v1/reports", context.viewer_token)
    assert_operation_response(response)
    assert byte_size(response.resp_body) < 32_000
    first_page = json_response(response, 200)
    assert length(first_page["data"]) == 50

    for summary <- first_page["data"] do
      refute Map.has_key?(summary, "content")
      refute Map.has_key?(summary, "document")
      assert summary["operation_count"] == 3
      assert summary["verification_count"] == 2
    end

    cursor = first_page["page"]["next"]
    tail = get_json("/api/v1/reports?after=" <> URI.encode_www_form(cursor), context.viewer_token)
    assert_operation_response(tail)
    tail_page = json_response(tail, 200)
    assert tail_page["page"]["next"] == nil

    assert Enum.sort(Enum.map(first_page["data"] ++ tail_page["data"], & &1["id"])) ==
             Enum.sort(report_ids)

    full = get_json("/api/v1/reports/#{hd(report_ids)}", context.viewer_token)
    assert_operation_response(full)
    assert json_response(full, 200)["data"]["content"]["padding"] == padding

    root = Path.join(System.tmp_dir!(), "report-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      OpsondeCLI.Config.save(
        %{"server" => "https://opsonde.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &OpsondeWeb.Endpoint.call(&1, OpsondeWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    listed =
      capture_io(fn ->
        assert OpsondeCLI.CLI.run(["report", "list"], runtime) == 0
      end)

    assert byte_size(listed) < 32_000
    assert Jason.decode!(listed)["data"] == first_page["data"]

    listed_tail =
      capture_io(fn ->
        assert OpsondeCLI.CLI.run(["report", "list", "--after", cursor], runtime) == 0
      end)

    assert Jason.decode!(listed_tail)["data"] == tail_page["data"]

    shown =
      capture_io(fn ->
        assert OpsondeCLI.CLI.run(["report", "show", hd(report_ids)], runtime) == 0
      end)

    assert Jason.decode!(shown)["data"]["content"]["padding"] == padding

    Opsonde.Repo.query!("ALTER TABLE reports RENAME COLUMN content TO unavailable_content")

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} = Reports.page_reports(actor: context.viewer)
      assert Exception.message(cause) =~ "does not exist"

      for path <- ["/api/v1/reports", "/api/v1/reports/#{hd(report_ids)}"] do
        failed = get_json(path, context.viewer_token)
        assert json_response(failed, 500)["error"]["code"] == "internal_error"
        assert_operation_response(failed)
      end

      for command <- [["report", "list"], ["report", "show", hd(report_ids)]] do
        failed =
          capture_io(:stderr, fn ->
            assert OpsondeCLI.CLI.run(command, runtime) == 4
          end)

        assert %{"http_status" => 500, "error" => %{"code" => "internal_error"}} =
                 Jason.decode!(failed)
      end
    after
      Opsonde.Repo.query!("ALTER TABLE reports RENAME COLUMN unavailable_content TO content")
    end

    assert length(Reports.page_reports!(actor: context.viewer).results) == 50
  end

  test "Report setting is readable but only an Admin can change it", context do
    path = "/api/v1/report-setting"
    shown = get_json(path, context.viewer_token)

    assert %{"data" => %{"automatic_case_reports_enabled" => true, "revision" => revision}} =
             json_response(shown, 200)

    assert_operation_response(shown)

    body = %{
      "report_setting" => %{
        "expected_revision" => revision,
        "automatic_case_reports_enabled" => false
      }
    }

    forbidden = request(:put, path, body, context.operator_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

    viewer_forbidden = request(:put, path, body, context.viewer_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    updated = request(:put, path, body, context.admin_token)

    assert %{
             "data" => %{
               "automatic_case_reports_enabled" => false,
               "revision" => next_revision,
               "changed_by_id" => changed_by_id
             }
           } = json_response(updated, 200)

    assert next_revision == revision + 1
    assert changed_by_id == context.admin.id
    assert_operation_response(updated)
    assert get_data!(path, context.viewer_token)["automatic_case_reports_enabled"] == false

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "manual-report-with-automatic-off",
        "Manual report while automatic generation is off",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    manual =
      post_json(
        "/api/v1/cases/#{resolved.id}/reports",
        %{"report" => %{"expected_case_revision" => resolved.revision}},
        context.operator_token
      )

    assert %{"data" => %{"case_id" => case_id}} = json_response(manual, 201)
    assert case_id == resolved.id

    stale = request(:put, path, body, context.admin_token)
    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)
  end

  test "Signal receipt status is cursor-readable without Provider credentials", context do
    provider =
      Providers.create_provider!(
        "receipt-signal-provider",
        :signal,
        "fixture-signal",
        %{"source" => "zabbix"},
        %{"secret" => "receipt-provider-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target = Targets.create_target!("10601", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(target.id, "zabbix", "hostname", "10601",
      actor: context.admin
    )

    now = DateTime.utc_now()
    receipt_id = "zabbix-event-9001"

    receipt =
      Signals.ingest_signal!(
        provider.id,
        provider.revision,
        %Signal.Envelope{body: receipt_id, headers: %{}, received_at: now},
        %{
          authenticate: fn adapter, _envelope ->
            {:ok, %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: adapter.source}}
          end,
          normalize: fn _adapter, _envelope, _receipt ->
            {:ok,
             [
               %Signal.Event{
                 receipt_id: receipt_id,
                 event_key: receipt_id,
                 state: :firing,
                 source_sequence: "9001",
                 occurred_at: now,
                 target_ref: %{kind: :hostname, value: "10601"},
                 attributes: %{"private" => "raw-event-detail"},
                 metadata: %{"private" => "raw-event-metadata"}
               }
             ]}
          end
        }
      )

    [signal_event] = Signals.list_signal_events!(actor: context.admin)
    incident = Cases.get_case!(signal_event.case_id, actor: context.admin)

    list = get_json("/api/v1/signal-receipts?limit=1", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "id" => id,
                 "receipt_id" => "zabbix-event-9001",
                 "event_count" => 1
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(list, 200)

    assert_operation_response(list)

    assert id == receipt.id
    refute list.resp_body =~ "metadata"
    refute list.resp_body =~ "normalized_digest"
    refute list.resp_body =~ "receipt-provider-secret"

    shown = get_json("/api/v1/signal-receipts/#{id}", context.operator_token)
    assert %{"data" => %{"id" => ^id}} = json_response(shown, 200)
    assert_operation_response(shown)

    event_response =
      get_json("/api/v1/signal-receipts/#{id}/events", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "id" => event_id,
                 "signal_receipt_id" => ^id,
                 "event_key" => "zabbix-event-9001",
                 "state" => "firing",
                 "case_id" => case_id,
                 "target_ref" => %{"kind" => "hostname", "value" => "10601"}
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(event_response, 200)

    assert_operation_response(event_response)

    assert event_id == signal_event.id
    assert case_id == incident.id
    refute event_response.resp_body =~ "raw-event-detail"
    refute event_response.resp_body =~ "raw-event-metadata"
  end

  test "Audit schedule API exposes queued, running, opened and skipped outcomes", context do
    boundary =
      Targets.create_management_boundary!("outcome-audit-dc", "datacenter", %{},
        actor: context.admin
      )

    target =
      Targets.create_target!("outcome-audit-linux", "host", "linux", %{}, boundary.id,
        actor: context.admin
      )

    schedule =
      post_data!(
        "/api/v1/audit-schedules",
        %{
          "audit_schedule" => %{
            "name" => "hourly-storage-audit",
            "desired_outcome" => "Storage health is normal",
            "timezone" => "Etc/UTC",
            "cron_expression" => "0 * * * *",
            "report_language" => "en",
            "target_ids" => [target.id]
          }
        },
        context.admin_token
      )

    assert schedule["desired_outcome"] == "Storage health is normal"

    schedules = get_json("/api/v1/audit-schedules", context.viewer_token)
    assert %{"data" => [%{"id" => schedule_id}]} = json_response(schedules, 200)
    assert schedule_id == schedule["id"]
    assert_operation_response(schedules)

    shown_schedule = get_json("/api/v1/audit-schedules/#{schedule["id"]}", context.viewer_token)

    assert %{"data" => %{"id" => ^schedule_id, "desired_outcome" => "Storage health is normal"}} =
             json_response(shown_schedule, 200)

    assert_operation_response(shown_schedule)

    persisted = Audits.get_audit_schedule!(schedule["id"], actor: context.admin)

    Audits.wake_audit_schedule!(
      persisted.id,
      persisted.revision,
      persisted.next_run_at,
      authorize?: false
    )

    [queued] =
      Audits.audit_runs_for_occurrence!(persisted.id, persisted.next_run_at, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "queued"

    Audits.claim_audit_run!(queued.id, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "running"

    assert :ok =
             Opsonde.Audits.AuditRun.Worker.perform(%Oban.Job{
               args: %{"audit_run_id" => queued.id}
             })

    opened = get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)
    assert opened["status"] == "case_opened"

    assert get_data!("/api/v1/cases/#{opened["case_id"]}", context.viewer_token)["case"]["id"] ==
             opened["case_id"]

    empty_boundary =
      Targets.create_management_boundary!("outcome-empty-dc", "datacenter", %{},
        actor: context.admin
      )

    empty_schedule =
      Audits.schedule_audit!(
        "empty-scope-audit",
        "Inspect empty scope",
        "Etc/UTC",
        "0 * * * *",
        :ja,
        [],
        empty_boundary.id,
        actor: context.admin
      )

    Audits.wake_audit_schedule!(
      empty_schedule.id,
      empty_schedule.revision,
      empty_schedule.next_run_at,
      authorize?: false
    )

    runs = get_data!("/api/v1/audit-runs", context.viewer_token)
    assert Enum.any?(runs, &(&1["status"] == "case_opened" and &1["id"] == queued.id))
    assert Enum.any?(runs, &(&1["status"] == "skipped"))

    current = Audits.get_audit_schedule!(persisted.id, actor: context.admin)

    stale =
      post_json(
        "/api/v1/audit-schedules/#{current.id}/deactivate",
        %{"audit_schedule" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    deactivated =
      post_json(
        "/api/v1/audit-schedules/#{current.id}/deactivate",
        %{"audit_schedule" => %{"expected_revision" => current.revision}},
        context.admin_token
      )

    assert %{"data" => %{"active" => false}} = json_response(deactivated, 200)
    assert_operation_response(deactivated)

    invalid =
      post_json(
        "/api/v1/audit-schedules",
        %{
          "audit_schedule" => %{
            "name" => "invalid-audit",
            "desired_outcome" => "Storage health is normal",
            "timezone" => "invalid/timezone",
            "cron_expression" => "not cron",
            "report_language" => "en",
            "target_ids" => [target.id]
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)
  end

  test "immutable Report delivery is idempotent and explicit retry keeps the Report", context do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "outcome-report",
        "Resolved service incident",
        :warning,
        %{"summary" => "service recovered", "desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    terminal =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    report_response =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision}},
        context.operator_token
      )

    assert %{
             "data" => %{
               "id" => report_id,
               "case_revision" => case_revision,
               "outcome" => "resolved",
               "revision" => report_revision,
               "content_digest" => digest
             }
           } = json_response(report_response, 201)

    assert_operation_response(report_response)

    assert byte_size(digest) == 64
    assert case_revision == terminal.revision

    reports = get_json("/api/v1/reports", context.viewer_token)
    assert %{"data" => [%{"id" => listed_report_id}]} = json_response(reports, 200)
    assert listed_report_id == report_id
    assert_operation_response(reports)

    shown_report = get_json("/api/v1/reports/#{report_id}", context.viewer_token)
    assert_operation_response(shown_report)

    assert %{
             "data" => %{
               "document" => %{
                 "title" => "Resolved service incident",
                 "conditions" => [],
                 "cited_evidence" => [],
                 "text" => text
               }
             }
           } = json_response(shown_report, 200)

    assert text =~ "Resolved service incident"
    assert text =~ "Not established"

    duplicate_report =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision}},
        context.operator_token
      )

    assert json_response(duplicate_report, 201)["data"]["id"] == report_id

    stale_report =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision + 1}},
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale_report, 409)

    provider =
      Providers.create_provider!(
        "outcome-notification-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "test-webhook"},
        %{"token" => "delivery-provider-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    delivery_body = %{
      "delivery" => %{
        "report_id" => report_id,
        "report_revision" => report_revision,
        "provider_id" => provider.id,
        "provider_revision" => provider.revision,
        "idempotency_key" => "report-delivery-1"
      }
    }

    delivery_response = post_json("/api/v1/deliveries", delivery_body, context.operator_token)

    assert %{"data" => %{"id" => delivery_id, "status" => "queued"}} =
             json_response(delivery_response, 202)

    assert_operation_response(delivery_response)

    duplicate_delivery = post_json("/api/v1/deliveries", delivery_body, context.operator_token)
    assert json_response(duplicate_delivery, 202)["data"]["id"] == delivery_id

    assert {:ok, failed} =
             Dispatch.run(delivery_id, %{
               test_pid: self(),
               respond: fn ->
                 {:ok,
                  %Notification.Result{
                    status: :failed,
                    reference: "remote-failure",
                    details: %{"message" => "destination unavailable"}
                  }}
               end
             })

    assert failed.status == :failed
    assert_receive {:delivery, %{token: "delivery-provider-secret"}, _request}

    stored = get_json("/api/v1/deliveries/#{delivery_id}", context.viewer_token)

    assert %{"data" => %{"status" => "failed", "reference" => "remote-failure"}} =
             json_response(stored, 200)

    assert_operation_response(stored)

    refute stored.resp_body =~ "delivery-provider-secret"
    refute stored.resp_body =~ "idempotency_key"

    retry_body = put_in(delivery_body, ["delivery", "idempotency_key"], "report-delivery-2")
    retry = post_json("/api/v1/deliveries", retry_body, context.operator_token)

    assert %{"data" => %{"id" => retry_id, "status" => "queued"}} =
             json_response(retry, 202)

    assert_operation_response(retry)

    refute retry_id == delivery_id

    deliveries = get_json("/api/v1/deliveries", context.viewer_token)
    assert %{"data" => delivery_records} = json_response(deliveries, 200)
    assert Enum.sort(Enum.map(delivery_records, & &1["id"])) == Enum.sort([delivery_id, retry_id])
    assert_operation_response(deliveries)

    assert get_data!("/api/v1/reports/#{report_id}", context.viewer_token)["content_digest"] ==
             digest

    viewer_forbidden = post_json("/api/v1/deliveries", retry_body, context.viewer_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    assert length(Notifications.list_deliveries!(actor: context.admin)) == 2
  end

  test "period Report API uses the same scoped Ash summary for viewers", context do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "period-api",
        "Period API Case",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    from = incident.inserted_at |> DateTime.add(-60) |> DateTime.to_iso8601()
    to = incident.inserted_at |> DateTime.add(60) |> DateTime.to_iso8601()
    path = "/api/v1/reports/operations-summary?" <> URI.encode_query(%{from: from, to: to})
    response = get_json(path, context.viewer_token)

    assert_operation_response(response)

    assert %{"data" => %{"case_count" => 1, "audit_count" => 0, "cases" => [source]}} =
             json_response(response, 200)

    assert source["id"] == incident.id

    invalid = get_json("/api/v1/reports/operations-summary?from=bad&to=bad", context.viewer_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)

    too_long =
      get_json(
        "/api/v1/reports/operations-summary?from=2025-01-01T00%3A00%3A00Z&to=2026-09-01T00%3A00%3A00Z",
        context.viewer_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(too_long, 422)
  end

  defp post_data!(path, body, token) do
    response = post_json(path, body, token)
    assert_operation_response(response)
    response |> json_response(201) |> Map.fetch!("data")
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

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
