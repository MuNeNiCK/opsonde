defmodule OpsondeWeb.API.V1.WorkflowControllerTest do
  use OpsondeWeb.ConnCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.ReviewDelivery
  alias Opsonde.Providers.AI

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

    incident = open_case!(context.operator_token, "lifecycle-1")
    assert incident["status"] == "running"
    assert incident["authority_mode"] == "ask"

    claimed =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => incident["revision"]}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 2, "current_owner_id" => owner_id}} =
             json_response(claimed, 200)

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

    cancelled =
      post_json(
        "/api/v1/cases/#{incident["id"]}/cancel",
        %{"case" => %{"expected_revision" => 3}},
        token!(context.next_operator.email)
      )

    assert %{"data" => %{"revision" => 4, "cancel_requested" => true}} =
             json_response(cancelled, 200)

    snapshot = get_json("/api/v1/cases/#{incident["id"]}", context.viewer_token)

    assert %{
             "data" => %{
               "case" => %{"id" => case_id, "revision" => 4},
               "resolution_runs" => [%{"generation" => 1}],
               "proposals" => [],
               "operations" => [],
               "verification_attempts" => []
             }
           } = json_response(snapshot, 200)

    assert case_id == incident["id"]
    refute snapshot.resp_body =~ "pending_intent"
    refute snapshot.resp_body =~ "idempotency_key"

    timeline = get_json("/api/v1/cases/#{incident["id"]}/timeline?limit=2", context.viewer_token)

    assert %{"data" => first_events, "page" => %{"next" => cursor}} =
             json_response(timeline, 200)

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

    snapshot = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)
    assert snapshot["case"]["status"] == "running"
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

    assert approved_revision > proposal.revision

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

    assert operation_id == operation.id
    assert Cases.get_operation!(operation.id, authorize?: false).revision == operation.revision

    assert :ok =
             Opsonde.Cases.OperationDelivery.run(operation.id,
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

  test "unexpected AI failures cannot reach the reconnect contract", context do
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

    assert %{
             "data" => [
               %{
                 "outcome" => "delivery_failed",
                 "verdict" => "needs_human",
                 "category" => "failed",
                 "reason" => "Reviewer delivery failed"
               }
             ]
           } = json_response(response, 200)

    refute response.resp_body =~ "internal-review-secret"
    refute response.resp_body =~ "RuntimeError"
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
      Providers.create_ai_usage_role_assignment!(resolver.id, :resolver, 10, actor: context.admin)

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
      Providers.create_ai_usage_role_assignment!(reviewer.id, :reviewer, 10, actor: context.admin)

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
        :not_applicable,
        %{},
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

  defp open_case!(token, source_ref) do
    post_json(
      "/api/v1/cases",
      %{
        "case" => %{
          "trigger_kind" => "manual",
          "source" => "api",
          "source_ref" => source_ref,
          "title" => "Investigate #{source_ref}",
          "severity" => "warning",
          "alert_state" => "not_applicable",
          "initial_context" => %{},
          "report_language" => "en"
        }
      },
      token
    )
    |> json_response(201)
    |> Map.fetch!("data")
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
  defp put_json(path, body, token), do: request(:put, path, body, token)

  defp request(method, path, body, token) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
