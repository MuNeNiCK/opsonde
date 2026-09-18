defmodule OpsondeCLI.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Plug.Conn

  alias OpsondeCLI.{CLI, Config}

  setup do
    root = Path.join(System.tmp_dir!(), "opsonde-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")
    on_exit(fn -> File.rm_rf(root) end)
    %{config_path: config_path, stub: {__MODULE__, make_ref()}}
  end

  test "prints fixed-English help" do
    assert capture_io(fn -> assert CLI.run([]) == 0 end) =~ "Output is fixed-English JSON"
  end

  test "prints the product version" do
    assert capture_io(fn -> assert CLI.run(["--version"]) == 0 end) ==
             "opsonde 0.1.0\n"
  end

  test "rejects an unknown command" do
    assert capture_io(:stderr, fn -> assert CLI.run(["unknown"]) == 2 end) ==
             "Unknown or incomplete command. Run opsonde --help for usage.\n"
  end

  test "stores a login session with private permissions and never prints its token", context do
    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/sessions"
      {:ok, encoded, conn} = read_body(conn)

      assert Jason.decode!(encoded) == %{
               "session" => %{"email" => "admin@example.test", "password" => "secret-password"}
             }

      Req.Test.json(conn, %{
        data: %{token: "session-token", account: %{id: "account-1", role: "admin"}}
      })
    end)

    output =
      capture_io("secret-password\n", fn ->
        assert CLI.run(
                 [
                   "auth",
                   "login",
                   "--server",
                   "https://opsonde.example",
                   "--email",
                   "admin@example.test"
                 ],
                 runtime(context)
               ) == 0
      end)

    refute output =~ "session-token"
    assert output =~ "account-1"

    assert {:ok, %{"server" => "https://opsonde.example", "token" => "session-token"}} =
             Config.load(context.config_path)

    assert %{mode: 0o100600} = File.stat!(context.config_path)
    assert %{mode: 0o40700} = File.stat!(Path.dirname(context.config_path))

    shown = capture_io(fn -> assert CLI.run(["config", "show"], runtime(context)) == 0 end)
    assert shown =~ ~s("authenticated": true)
    refute shown =~ "session-token"
  end

  test "changing the server clears its session without changing an existing parent mode",
       context do
    parent = Path.dirname(context.config_path)
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)
    save_session(context)

    capture_io(fn ->
      assert CLI.run(
               ["config", "set-server", "https://replacement.example"],
               runtime(context)
             ) == 0
    end)

    assert {:ok, %{"server" => "https://replacement.example"}} =
             Config.load(context.config_path)

    assert %{mode: 0o40755} = File.stat!(parent)
  end

  test "wraps resource input and sends bearer authentication", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/targets"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      {:ok, encoded, conn} = read_body(conn)

      assert Jason.decode!(encoded) == %{
               "target" => %{"name" => "edge-1", "kind" => "network", "platform" => "ios_xe"}
             }

      conn
      |> put_status(201)
      |> Req.Test.json(%{data: %{id: "target-1", revision: 1}})
    end)

    input = ~s({"name":"edge-1","kind":"network","platform":"ios_xe"})

    output =
      capture_io(input, fn ->
        assert CLI.run(["target", "create", "--input", "-"], runtime(context)) == 0
      end)

    assert output =~ ~s("outcome": "succeeded")
    assert output =~ "target-1"
  end

  test "passes pagination without changing the shared API contract", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases"
      assert URI.decode_query(conn.query_string) == %{"after" => "cursor-value", "limit" => "7"}
      Req.Test.json(conn, %{data: [], page: %{next: nil}})
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["case", "list", "--limit", "7", "--after", "cursor-value"],
                 runtime(context)
               ) == 0
      end)

    assert output =~ ~s("outcome": "succeeded")
  end

  test "a new process resumes a case by id using read-only polling", context do
    save_session(context)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases/case-1"
      attempt = Agent.get_and_update(counter, fn value -> {value, value + 1} end)

      if attempt == 0 do
        Req.Test.json(conn, case_snapshot("running", [%{"status" => "running"}], []))
      else
        Req.Test.json(conn, case_snapshot("resolved", [%{"status" => "completed"}], []))
      end
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["case", "wait", "case-1", "--interval", "50", "--timeout", "2"],
                 runtime(context)
               ) == 0
      end)

    assert output =~ ~s("outcome": "resolved")
    assert Agent.get(counter, & &1) == 2
  end

  test "case polling distinguishes accepted, approval, attention and cancellation", context do
    save_session(context)

    scenarios = [
      {"accepted", case_snapshot("running", [], []), 10},
      {"approval_required",
       case_snapshot("running", [%{"status" => "running"}], [%{"status" => "awaiting_human"}]),
       11},
      {"needs_attention", case_snapshot("needs_attention", [], []), 12},
      {"cancel_requested", case_snapshot("running", [], [], true), 16}
    ]

    Enum.each(scenarios, fn {expected, response, exit_code} ->
      Req.Test.stub(context.stub, fn conn -> Req.Test.json(conn, response) end)

      output =
        capture_io(fn ->
          assert CLI.run(["case", "wait", "case-1", "--timeout", "0"], runtime(context)) ==
                   exit_code
        end)

      assert output =~ ~s("outcome": "#{expected}")
    end)
  end

  test "operation polling distinguishes active and terminal outcomes", context do
    save_session(context)

    for {status, expected, exit_code} <- [
          {"queued", "accepted", 10},
          {"dispatching", "resolving", 10},
          {"applied", "resolved", 0},
          {"failed", "failed", 13},
          {"partial", "partial", 14},
          {"unknown", "unknown", 15}
        ] do
      Req.Test.stub(context.stub, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{data: %{id: "operation-1", status: status}})
      end)

      output =
        capture_io(fn ->
          assert CLI.run(
                   ["operation", "wait", "operation-1", "--timeout", "0"],
                   runtime(context)
                 ) == exit_code
        end)

      assert output =~ ~s("outcome": "#{expected}")
    end
  end

  test "an accepted notification delivery is a completed typed result", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      Req.Test.json(conn, %{data: %{id: "delivery-1", status: "accepted"}})
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["delivery", "wait", "delivery-1", "--timeout", "2"],
                 runtime(context)
               ) == 10
      end)

    assert output =~ ~s("outcome": "accepted")
  end

  test "logout revokes the server session and removes only the local token", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "DELETE"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      send_resp(conn, 204, "")
    end)

    capture_io(fn -> assert CLI.run(["auth", "logout"], runtime(context)) == 0 end)
    assert {:ok, %{"server" => "https://opsonde.example"}} = Config.load(context.config_path)
  end

  test "returns typed authentication and transport failures", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      conn
      |> put_status(401)
      |> Req.Test.json(%{error: %{code: "invalid_session", message: "Session is invalid"}})
    end)

    authentication_error =
      capture_io(:stderr, fn ->
        assert CLI.run(["auth", "status"], runtime(context)) == 3
      end)

    assert authentication_error =~ "invalid_session"

    Req.Test.stub(context.stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    transport_error =
      capture_io(:stderr, fn ->
        assert CLI.run(["auth", "status"], runtime(context)) == 5
      end)

    assert transport_error =~ "transport_error"
    assert transport_error =~ ~s("outcome":"unknown")
  end

  defp runtime(context) do
    [config_path: context.config_path, request_options: [plug: {Req.Test, context.stub}]]
  end

  defp save_session(context) do
    :ok =
      Config.save(
        %{"server" => "https://opsonde.example", "token" => "saved-token"},
        context.config_path
      )
  end

  defp case_snapshot(status, runs, proposals, cancel_requested \\ false) do
    %{
      data: %{
        case: %{id: "case-1", status: status, cancel_requested: cancel_requested},
        resolution_runs: runs,
        proposals: proposals,
        operations: [],
        verification_attempts: []
      }
    }
  end
end
