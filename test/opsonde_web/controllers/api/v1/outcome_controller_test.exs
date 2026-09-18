defmodule OpsondeWeb.API.V1.OutcomeControllerTest do
  use OpsondeWeb.ConnCase, async: false

  alias Opsonde.{Accounts, Cases, Notifications, Providers, Targets}
  alias Opsonde.Notifications.DeliveryDispatch
  alias Opsonde.Providers.Notification

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
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
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

    receipt =
      Cases.create_signal_receipt_record!(
        %{
          provider_id: provider.id,
          provider_revision: provider.revision,
          receipt_id: "zabbix-event-9001",
          source: "zabbix",
          received_at: DateTime.utc_now(),
          metadata: %{"normalized" => true},
          normalized_digest: String.duplicate("a", 64),
          event_count: 1
        },
        authorize?: false
      )

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

    assert id == receipt.id
    refute list.resp_body =~ "metadata"
    refute list.resp_body =~ "normalized_digest"
    refute list.resp_body =~ "receipt-provider-secret"

    assert %{"data" => %{"id" => ^id}} =
             get_json("/api/v1/signal-receipts/#{id}", context.operator_token)
             |> json_response(200)
  end

  test "Audit schedule API exposes persisted queued, running and skipped outcomes", context do
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
            "objective" => "Inspect storage health",
            "timezone" => "Etc/UTC",
            "cron_expression" => "0 * * * *",
            "report_language" => "en",
            "target_ids" => [target.id]
          }
        },
        context.admin_token
      )

    persisted = Cases.get_audit_schedule!(schedule["id"], actor: context.admin)

    Cases.wake_audit_schedule!(
      persisted.id,
      persisted.revision,
      persisted.next_run_at,
      authorize?: false
    )

    [queued] =
      Cases.audit_runs_for_occurrence!(persisted.id, persisted.next_run_at, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "queued"

    Cases.claim_audit_run!(queued.id, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "running"

    empty_boundary =
      Targets.create_management_boundary!("outcome-empty-dc", "datacenter", %{},
        actor: context.admin
      )

    empty_schedule =
      Cases.schedule_audit!(
        "empty-scope-audit",
        "Inspect empty scope",
        "Etc/UTC",
        "0 * * * *",
        :ja,
        [],
        empty_boundary.id,
        actor: context.admin
      )

    Cases.wake_audit_schedule!(
      empty_schedule.id,
      empty_schedule.revision,
      empty_schedule.next_run_at,
      authorize?: false
    )

    runs = get_data!("/api/v1/audit-runs", context.viewer_token)
    assert Enum.any?(runs, &(&1["status"] == "running" and &1["id"] == queued.id))
    assert Enum.any?(runs, &(&1["status"] == "skipped"))

    current = Cases.get_audit_schedule!(persisted.id, actor: context.admin)

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

    invalid =
      post_json(
        "/api/v1/audit-schedules",
        %{
          "audit_schedule" => %{
            "name" => "invalid-audit",
            "objective" => "Invalid schedule",
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
        :not_applicable,
        %{"summary" => "service recovered"},
        nil,
        :en,
        actor: context.operator
      )

    terminal =
      Cases.update_case_record!(incident, incident.revision, %{status: :resolved},
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

    assert byte_size(digest) == 64
    assert case_revision == terminal.revision

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

    duplicate_delivery = post_json("/api/v1/deliveries", delivery_body, context.operator_token)
    assert json_response(duplicate_delivery, 202)["data"]["id"] == delivery_id

    assert {:ok, failed} =
             DeliveryDispatch.run(delivery_id, %{
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

    refute stored.resp_body =~ "delivery-provider-secret"
    refute stored.resp_body =~ "idempotency_key"

    retry_body = put_in(delivery_body, ["delivery", "idempotency_key"], "report-delivery-2")
    retry = post_json("/api/v1/deliveries", retry_body, context.operator_token)

    assert %{"data" => %{"id" => retry_id, "status" => "queued"}} =
             json_response(retry, 202)

    refute retry_id == delivery_id

    assert get_data!("/api/v1/reports/#{report_id}", context.viewer_token)["content_digest"] ==
             digest

    viewer_forbidden = post_json("/api/v1/deliveries", retry_body, context.viewer_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    assert length(Notifications.list_deliveries!(actor: context.admin)) == 2
  end

  defp post_data!(path, body, token) do
    post_json(path, body, token) |> json_response(201) |> Map.fetch!("data")
  end

  defp get_data!(path, token) do
    get_json(path, token) |> json_response(200) |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => email, "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token), do: request(:get, path, nil, token)
  defp post_json(path, body, token), do: request(:post, path, body, token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
