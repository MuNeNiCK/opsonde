defmodule Opsonde.FileOperationTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Providers.AI
  alias Opsonde.Cases.Operation.Delivery
  alias Opsonde.Cases.Proposal.ReviewDelivery

  defmodule Peer do
    import Plug.Conn
    def init(agent), do: agent

    def call(conn, agent) do
      case {conn.method, conn.request_path} do
        {method, "/binary"} when method in ["PUT", "OPS!V2"] ->
          {:ok, bytes, conn} = read_body(conn)
          Agent.update(agent, &Map.put(&1, :writes, [bytes | &1.writes]))

          case Agent.get(agent, &Map.get(&1, :after_write)) do
            :drop -> Process.exit(self(), :kill)
            callback when is_function(callback, 0) -> callback.()
            nil -> :ok
          end

          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, bytes)

        _ ->
          send_resp(conn, 200, "ready")
      end
    end
  end

  setup do
    admin =
      Accounts.bootstrap!(
        "file-case-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!("file-case-operator@example.invalid", "test-only-password", :operator,
        actor: admin
      )

    agent = start_supervised!({Agent, fn -> %{writes: []} end})

    peer =
      start_supervised!(
        {Bandit,
         plug: {Peer, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(peer)

    provider =
      Providers.create_provider!(
        "Case file HTTP",
        :target,
        "http-api",
        %{"ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")},
        %{},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!("file-device", "network_device", "custom-network-device", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Case file HTTP",
        "http",
        "https://127.0.0.1:#{port}",
        provider.revision,
        100,
        ["request.http.observe", "request.http.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    ai =
      Providers.create_provider!(
        "Case file AI fixture",
        :ai,
        "fixture-ai",
        %{"model" => "file-review-fixture"},
        %{"api_key" => "test-only"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    assignments = Opsonde.TestAIUsage.configure!(ai.id, :all, 10, admin)
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Case file review test",
      actor: admin
    )

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      ai: ai,
      assignments: assignments,
      agent: agent
    }
  end

  test "Reviewer approval binds native HTTP verb and file identity through Case execution",
       context do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "payload.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "case-input",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    reference = Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)

    parameters = %{
      "method" => "OPS!V2",
      "path" => "/binary",
      "body_file" => "payload",
      "files" => %{"payload" => reference},
      "response_file" => %{"name" => "result.bin", "media_type" => "application/octet-stream"}
    }

    proposal = proposal!(context, parameters)
    assert proposal.parameters == parameters
    assert proposal.status == :reviewing
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Agent.get(context.agent, & &1.writes) == []

    invocation = %{
      test_pid: self(),
      respond: fn request ->
        assert request.proposal.parameters == parameters
        assert request.proposal.parameters["files"]["payload"] == reference
        assert request.session_id != request.resolver_session_id

        {:ok,
         %AI.ReviewDecision{
           verdict: :approved,
           reason: "Approve this exact immutable payload",
           usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
         }}
      end
    }

    assert :ok = ReviewDelivery.run(proposal.id, ai_invocation: invocation)
    assert_receive {:review, _state, _request}
    [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :reviewer
    assert approval.proposal_digest == proposal.proposal_digest
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.parameters == parameters
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :applied
    assert stored.parameters == parameters
    reply = stored.result_details["file"]
    assert reply["target_id"] == context.target.id
    assert reply["sha256"] == reference["sha256"]

    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"]["files"]["payload"] == reference
    assert evidence.content["details"]["file"] == reply
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "a revoked approved file is rejected before Case dispatch", context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    Targets.revoke_artifact!(reference["id"], actor: context.operator)
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :failed
    assert stored.outcome_category == "authorization_invalidated"
    assert stored.parameters["files"]["payload"] == reference
    incident = Cases.get_case!(proposal.case_id, authorize?: false)
    run = Cases.get_resolution_run!(proposal.resolution_run_id, authorize?: false)
    turns = Cases.list_turns!(actor: context.admin)
    assert :ok = Delivery.run(operation.id)

    assert Cases.get_case!(proposal.case_id, authorize?: false).pending_intent ==
             incident.pending_intent

    assert Cases.get_resolution_run!(proposal.resolution_run_id, authorize?: false).turn_count ==
             run.turn_count

    assert Cases.list_turns!(actor: context.admin) |> Enum.map(& &1.id) ==
             Enum.map(turns, & &1.id)

    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "an outcome save failure preserves the received file without repeating the effect",
       context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    # Fail only the outcome publication after the real HTTP peer has replied.
    Opsonde.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_file_operation_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'applied' THEN
        RAISE EXCEPTION 'test outcome publication unavailable';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Opsonde.Repo.query!("""
    CREATE TRIGGER reject_file_operation_outcome BEFORE UPDATE ON operations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_file_operation_outcome()
    """)

    assert {:error, _} = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
    assert Cases.get_operation!(operation.id, authorize?: false).status == :dispatching

    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    received = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert received.status == :ready
    assert Map.get(received, :request_id) == operation.id
    reply = Targets.artifact_reference!(received.id, context.target.id, actor: context.operator)

    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    Opsonde.Repo.query!("DROP TRIGGER reject_file_operation_outcome ON operations")
    assert :ok = Delivery.run(operation.id)
    recovered = Cases.get_operation!(operation.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    assert recovered.parameters["files"]["payload"] == reference
    assert Targets.get_artifact!(received.id, actor: context.operator).request_id == operation.id
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.filter(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert [%{content: %{"status" => "unknown"}}] = evidence

    assert Targets.artifact_reference!(received.id, context.target.id, actor: context.operator) ==
             reply
  end

  test "a lost file reply remains unknown with a visible receipt and no duplicate send",
       context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    Agent.update(context.agent, &Map.put(&1, :after_write, :drop))

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :unknown
    refute Map.has_key?(stored.result_details, "file")
    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert receipt.status == :receiving
    assert receipt.request_id == operation.id
    assert stored.result_details["reason"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "Case cancellation before dispatch does not send or open a response file", context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    incident = Cases.get_case!(proposal.case_id, actor: context.operator)
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :failed
    assert stored.outcome_category == "cancelled_before_dispatch"
    assert Agent.get(context.agent, & &1.writes) == []
    [input] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert input.id == reference["id"]
  end

  test "Case cancellation after the send leaves an unknown effect and unusable response file",
       context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Agent.update(context.agent, fn state ->
      Map.put(state, :after_write, fn ->
        incident = Cases.get_case!(proposal.case_id, actor: context.operator)
        Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)
      end)
    end)

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    refute Map.has_key?(stored.result_details, "file")
    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert receipt.status == :receiving
    assert receipt.request_id == operation.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "an approved input that expires before dispatch cannot be sent", context do
    previous = Application.get_env(:opsonde, :artifact_limits)
    Application.put_env(:opsonde, :artifact_limits, %{lifetime_seconds: 3})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:opsonde, :artifact_limits, previous),
        else: Application.delete_env(:opsonde, :artifact_limits)
    end)

    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    input = Targets.get_artifact!(reference["id"], actor: context.operator)
    Process.sleep(max(DateTime.diff(input.expires_at, DateTime.utc_now(), :millisecond), 0) + 20)

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :failed
    assert stored.outcome_category == "authorization_invalidated"
    assert Agent.get(context.agent, & &1.writes) == []

    assert {:error, _} =
             Targets.artifact_reference(input.id, context.target.id, actor: context.operator)

    assert [only] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert only.id == input.id
  end

  test "changed or cross-Target file references cannot produce a cleared Case proposal",
       context do
    reference = stage_file(context)

    foreign =
      Targets.create_target!(
        "other-file-device",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: context.admin
      )

    for invalid <- [
          Map.put(reference, "sha256", String.duplicate("0", 64)),
          Map.put(reference, "target_id", foreign.id)
        ] do
      proposal = proposal!(context, file_parameters(invalid), route?: false)
      assert proposal.status == :blocked
      assert proposal.preflight_status != :cleared
    end

    assert Cases.list_approvals!(actor: context.admin) == []
    assert Agent.get(context.agent, & &1.writes) == []
  end

  defp stage_file(context) do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "case-input.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        Ecto.UUID.generate(),
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  defp file_parameters(reference) do
    %{
      "method" => "PUT",
      "path" => "/binary",
      "body_file" => "payload",
      "files" => %{"payload" => reference},
      "response_file" => %{
        "name" => "case-result.bin",
        "media_type" => "application/octet-stream"
      }
    }
  end

  defp approve!(proposal) do
    :ok =
      ReviewDelivery.run(proposal.id,
        ai_invocation: %{
          test_pid: self(),
          respond: fn request ->
            assert request.proposal.parameters == proposal.parameters

            {:ok,
             %AI.ReviewDecision{
               verdict: :approved,
               reason: "Approve this exact immutable payload",
               usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
             }}
          end
        }
      )
  end

  defp proposal!(context, parameters, opts \\ []) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        Ecto.UUID.generate(),
        "Apply exact file payload",
        :warning,
        %{"desired_outcome" => "The device accepts the exact payload"},
        context.target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        Ecto.UUID.generate(),
        "observation",
        "wire-fixture",
        "device-status",
        %{"target_id" => context.target.id, "status" => "ready"},
        DateTime.utc_now(),
        authorize?: false
      )

    tool = %{
      "id" => "file-effect",
      "request_kind" => "effect",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "request.http.effect",
      "operation" => "request.execute"
    }

    intent = %{
      "type" => "proposal",
      "request_kind" => "effect",
      "tool_id" => tool["id"],
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "capability" => "request.http.effect",
      "operation" => "request.execute",
      "tool" => tool,
      "selectors" => %{},
      "parameters" => parameters,
      "reason" => "Send the exact reviewed file to the device",
      "evidence_ids" => [evidence.id],
      "affected_conditions" => [],
      "expected_result" => %{"status" => 200},
      "verification_intent" => %{
        "tool_id" => "file-verification",
        "selectors" => %{},
        "parameters" => %{"method" => "GET", "path" => "/"},
        "expected_result" => %{"status" => 200}
      },
      "verification_tool" => %{
        tool
        | "id" => "file-verification",
          "request_kind" => "observation",
          "capability" => "request.http.observe",
          "operation" => "request.observe"
      }
    }

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        Ecto.UUID.generate(),
        %{"objective" => "Apply reviewed payload"},
        %{"action" => "continue"},
        "Review limits",
        authorize?: false
      ).value

    resolver = context.assignments.resolver

    result = %{
      "outcome" => "decision",
      "intent" => intent,
      "resolver" => %{
        "provider_id" => context.ai.id,
        "provider_revision" => context.ai.revision,
        "assignment_id" => resolver.id,
        "assignment_revision" => resolver.revision
      },
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(completed.id, authorize?: false)

    if Keyword.get(opts, :route?, true),
      do: Cases.route_proposal_authority!(proposal.id, authorize?: false),
      else: proposal
  end
end
