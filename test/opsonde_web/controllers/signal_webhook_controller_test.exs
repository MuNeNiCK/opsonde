defmodule OpsondeWeb.SignalWebhookControllerTest do
  use OpsondeWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Opsonde.{Accounts, Providers, Signals}

  @password "correct horse battery staple"
  @secret "monitoring-webhook-secret"

  setup do
    admin =
      Accounts.bootstrap!("signal-webhook-admin@example.com", @password, @password,
        authorize?: true
      )

    alertmanager = provider!(admin, "alertmanager", "alertmanager-webhook")
    zabbix = provider!(admin, "zabbix", "zabbix-webhook", %{"timezone" => "Asia/Tokyo"})

    %{admin: admin, alertmanager: alertmanager, zabbix: zabbix}
  end

  test "Alertmanager authenticates and splits one group into source events", context do
    conn =
      context.conn
      |> authorized()
      |> post_json(
        "/api/v1/signals/alertmanager/#{context.alertmanager.id}",
        alertmanager_payload()
      )

    assert %{"receipt_id" => receipt_id} = json_response(conn, 202)
    assert is_binary(receipt_id)
    assert_operation_response(conn)

    receipts = Signals.list_signal_receipts!(actor: context.admin)
    events = Signals.list_signal_events!(actor: context.admin)

    assert length(receipts) == 1

    assert Enum.map(events, &{&1.event_key, &1.state}) |> Enum.sort() == [
             {"fingerprint-a", :firing},
             {"fingerprint-b", :recovered}
           ]

    firing = Enum.find(events, &(&1.event_key == "fingerprint-a"))
    assert firing.target_ref == %{"kind" => "instance", "value" => "server-a:9100"}

    assert firing.attributes["labels"] == %{
             "alertname" => "DiskErrors",
             "instance" => "server-a:9100",
             "opsonde_incident_key" => "storage-outage-42",
             "severity" => "critical"
           }

    assert firing.incident_key == "storage-outage-42"

    assert firing.attributes["annotations"] == %{"summary" => "Disk errors increased"}
    assert firing.metadata["alertmanager"]["truncated_alerts"] == 0
    assert firing.metadata["alertmanager"]["common_labels"] == %{"service" => "storage"}
    assert firing.metadata["alert"]["generator_url"] == "http://prometheus:9090/graph"
  end

  test "an exact Alertmanager retry returns accepted without duplicating persistence", context do
    path = "/api/v1/signals/alertmanager/#{context.alertmanager.id}"
    payload = alertmanager_payload()

    first = context.conn |> authorized() |> post_json(path, payload)
    second = build_conn() |> authorized() |> post_json(path, payload)

    assert json_response(first, 202)["receipt_id"] == json_response(second, 202)["receipt_id"]
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
  end

  test "authentication runs before Alertmanager body normalization", context do
    conn =
      context.conn
      |> put_req_header("authorization", "Bearer wrong-secret-value")
      |> post_json("/api/v1/signals/alertmanager/#{context.alertmanager.id}", %{"invalid" => true})

    assert json_response(conn, 401) == %{
             "errors" => %{"detail" => "Webhook authentication failed"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "authenticated malformed Alertmanager facts are rejected without persistence", context do
    payload = alertmanager_payload() |> put_in(["alerts", Access.at(0), "startsAt"], "invalid")

    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/alertmanager/#{context.alertmanager.id}", payload)

    assert json_response(conn, 422) == %{
             "errors" => %{"detail" => "Alertmanager timestamp is invalid"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "malformed JSON never reaches Signal persistence", context do
    assert_error_sent 400, fn ->
      context.conn
      |> authorized()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/signals/alertmanager/#{context.alertmanager.id}", "{invalid")
    end

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "Zabbix problem and recovery retain one source event identity and host reference",
       context do
    path = "/api/v1/signals/zabbix/#{context.zabbix.id}"

    firing =
      context.conn
      |> authorized()
      |> post_json(path, zabbix_payload("1", "1726650000"))

    recovery =
      build_conn()
      |> authorized()
      |> post_json(path, zabbix_payload("0", "1726650060"))

    assert response(firing, 202)
    assert response(recovery, 202)
    assert_operation_response(firing)
    assert_operation_response(recovery)

    events = Signals.list_signal_events!(actor: context.admin) |> Enum.sort_by(& &1.occurred_at)

    assert Enum.map(events, &{&1.event_key, &1.state, &1.source_sequence}) == [
             {"9001", :firing, "1726650000"},
             {"9001", :recovered, "1726650060"}
           ]

    assert Enum.all?(events, fn event ->
             event.target_ref == %{"kind" => "host_id", "value" => "10601"}
           end)

    assert Enum.all?(events, &(&1.incident_key == "storage-outage-42"))

    assert hd(events).attributes["zabbix"]["event_name"] == "Linux disk I/O errors"
  end

  test "Zabbix 7.0 date and time facts use the configured source timezone", context do
    payload =
      zabbix_payload("1", "")
      |> Map.put("event_timestamp", "{EVENT.TIMESTAMP}")
      |> Map.put("event_date", "2026.09.18")
      |> Map.put("event_time", "13:40:00")

    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/zabbix/#{context.zabbix.id}", payload)

    assert response(conn, 202)
    [event] = Signals.list_signal_events!(actor: context.admin)
    assert DateTime.compare(event.occurred_at, ~U[2026-09-18 04:40:00Z]) == :eq
    assert event.source_sequence == "1789706400"
  end

  test "source-specific endpoints reject a provider for the other adapter", context do
    conn =
      context.conn
      |> authorized()
      |> post_json(
        "/api/v1/signals/zabbix/#{context.alertmanager.id}",
        zabbix_payload("1", "1726650000")
      )

    assert json_response(conn, 404) == %{
             "errors" => %{"detail" => "Signal endpoint was not found"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "webhook contract rejects a malformed Provider identifier", context do
    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/zabbix/not-a-uuid", zabbix_payload("1", "1726650000"))

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["provider_id"]}
             }
           } = json_response(conn, 422)

    assert_operation_response(conn)
    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  defp provider!(admin, name, adapter_type, configuration \\ %{}) do
    Providers.create_provider!(
      name,
      :signal,
      adapter_type,
      Map.put(configuration, "source", name),
      %{"secret" => @secret},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))
  end

  defp authorized(conn) do
    put_req_header(conn, "authorization", "Bearer #{@secret}")
  end

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  defp alertmanager_payload do
    %{
      "version" => "4",
      "groupKey" => "{}:{alertname=\"DiskErrors\"}",
      "truncatedAlerts" => 0,
      "status" => "firing",
      "receiver" => "opsonde",
      "groupLabels" => %{"alertname" => "DiskErrors"},
      "commonLabels" => %{"service" => "storage"},
      "commonAnnotations" => %{},
      "externalURL" => "http://alertmanager:9093",
      "alerts" => [
        %{
          "status" => "firing",
          "labels" => %{
            "alertname" => "DiskErrors",
            "instance" => "server-a:9100",
            "opsonde_incident_key" => "storage-outage-42",
            "severity" => "critical"
          },
          "annotations" => %{"summary" => "Disk errors increased"},
          "startsAt" => "2026-09-18T01:00:00Z",
          "endsAt" => "0001-01-01T00:00:00Z",
          "generatorURL" => "http://prometheus:9090/graph",
          "fingerprint" => "fingerprint-a"
        },
        %{
          "status" => "resolved",
          "labels" => %{"alertname" => "LinkDown", "instance" => "switch-a"},
          "annotations" => %{"summary" => "Link recovered"},
          "startsAt" => "2026-09-18T00:50:00Z",
          "endsAt" => "2026-09-18T01:01:00Z",
          "generatorURL" => "http://prometheus:9090/graph",
          "fingerprint" => "fingerprint-b"
        }
      ]
    }
  end

  defp zabbix_payload(event_value, timestamp) do
    %{
      "event_id" => "9001",
      "event_value" => event_value,
      "event_timestamp" => "1726650000",
      "event_date" => "2024.09.18",
      "event_time" => "09:00:00",
      "recovery_timestamp" => if(event_value == "0", do: timestamp, else: ""),
      "recovery_date" => if(event_value == "0", do: "2024.09.18", else: ""),
      "recovery_time" => if(event_value == "0", do: "09:01:00", else: ""),
      "update_timestamp" => "",
      "host_id" => "10601",
      "host" => "linux-a",
      "host_name" => "Linux A",
      "trigger_id" => "21001",
      "event_name" => "Linux disk I/O errors",
      "severity" => "High",
      "severity_number" => "4",
      "tags" => [
        %{"tag" => "service", "value" => "storage"},
        %{"tag" => "opsonde_incident_key", "value" => "storage-outage-42"}
      ]
    }
  end
end
