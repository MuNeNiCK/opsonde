defmodule Opsonde.ResolverDeliveryTest do
  use Opsonde.DataCase, async: false

  import Ecto.Query

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.{Budget, DecisionRouteWorker, ResolverDelivery, ResolverWorker}
  alias Opsonde.Providers.{AI, Target}

  @password "correct horse battery staple"
  @api_key "resolver-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("delivery-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("delivery-operator@example.com", @password, :operator, actor: admin)

    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      600,
      4,
      5,
      2,
      3,
      10_000,
      2,
      "configure Resolver delivery",
      actor: admin
    )

    provider =
      Providers.create_provider!(
        "resolver-ai",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => @api_key},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    assignment =
      Providers.create_ai_usage_role_assignment!(provider.id, :resolver, 10, actor: admin)

    %{admin: admin, operator: operator, provider: provider, assignment: assignment}
  end

  test "result and AI usage commit once after a durable exact assignment", context do
    {incident, run, turn} = turn!("success", context.operator)

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSearch{
        query: "linux-01 disk errors",
        reason: "Find the registered Target referenced by the incident"
      },
      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
    }

    ai_invocation = %{
      test_pid: self(),
      respond: fn request ->
        key = Budget.key("turn:resolver_assignment", turn.id)

        assert {:ok, event} =
                 Cases.case_event_by_idempotency(incident.id, key, authorize?: false)

        assert event.data["provider_id"] == context.provider.id
        assert event.data["provider_revision"] == context.provider.revision
        assert event.data["assignment_id"] == context.assignment.id
        assert event.data["assignment_revision"] == context.assignment.revision
        assert request.provider_revision == context.provider.revision
        {:ok, decision}
      end
    }

    assert :ok = ResolverDelivery.run(turn.id, ai_invocation: ai_invocation)
    assert_receive {:resolve, %{model: "resolver-model", api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "decision"
    assert completed.result["intent"]["type"] == "target_search"
    assert completed.result["usage"] == %{"input_tokens" => 7, "output_tokens" => 5}
    assert [%Oban.Job{args: %{"turn_id" => turn_id}}] = route_jobs(turn.id)
    assert turn_id == turn.id

    charged = Cases.get_resolution_run!(run.id, authorize?: false)
    assert charged.ai_usage_units == 12

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("completed Turn called AI again") end
               }
             )

    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}

    events = Cases.list_case_events!(actor: context.admin)
    assert Enum.count(events, &(&1.event_type == "resolver_assigned")) == 1
    assert Enum.count(events, &(&1.event_type == "budget_charged")) == 1
    assert Enum.count(events, &(&1.event_type == "turn_completed")) == 1
  end

  test "known timeout and malformed output persist distinct handoffs without usage charge",
       context do
    for {suffix, response, expected_category} <- [
          {"timeout", {:error, :timeout, "model deadline exceeded"}, "timeout"},
          {"malformed", {:ok, %{}}, "invalid_output"}
        ] do
      {incident, run, turn} = turn!(suffix, context.operator)

      assert :ok =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request -> response end
                 }
               )

      assert_receive {:resolve, %{api_key: @api_key}, _request}

      completed = Cases.get_turn!(turn.id, authorize?: false)
      assert completed.status == :completed
      assert completed.result["outcome"] == "delivery_failed"
      assert completed.result["category"] == expected_category

      attention = Cases.get_case!(incident.id, authorize?: false)
      assert attention.status == :needs_attention
      assert attention.pending_intent == %{"action" => "retry_resolver", "turn_id" => turn.id}
      assert attention.stop_reason =~ expected_category

      paused = Cases.get_resolution_run!(run.id, authorize?: false)
      assert paused.status == :needs_attention
      assert paused.ai_usage_units == 0

      assert :ok =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request -> flunk("failed Turn called AI again") end
                 }
               )

      refute_receive {:resolve, _, _}
    end
  end

  test "a competing Turn completion rolls back the later AI usage charge", context do
    {_incident, run, turn} = turn!("competing-result", context.operator)

    ai_invocation = %{
      test_pid: self(),
      respond: fn _request ->
        Cases.complete_turn!(
          turn.id,
          turn.revision,
          %{"outcome" => "already_accepted"},
          :hypothesis,
          %{"action" => "route_resolver_decision", "turn_id" => turn.id},
          "Review the accepted result",
          authorize?: false
        )

        {:ok,
         %AI.ResolverDecision{
           intent: %AI.Handoff{reason: "Competing response", required_input: "Review"},
           usage: %AI.Usage{input_tokens: 10, output_tokens: 10}
         }}
      end
    }

    assert :ok = ResolverDelivery.run(turn.id, ai_invocation: ai_invocation)
    assert_receive {:resolve, _, _}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result == %{"outcome" => "already_accepted"}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    assert route_jobs(turn.id) == []
  end

  test "cancelled Case stops before AI dispatch", context do
    {incident, _run, turn} = turn!("cancelled", context.operator)
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert {:cancel, "Case resolution was cancelled"} =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("cancelled Case called AI") end
               }
             )

    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
    refute_receive {:resolve, _, _}
  end

  test "accepted observation and Proposal retain exact offered tool snapshots", context do
    {target, method, capabilities} = target_context!(context.admin)

    observation_turn = selected_turn!("observation-snapshot", context.operator, target)

    assert :ok =
             ResolverDelivery.run(observation_turn.id,
               target_invocation: target_invocation(capabilities),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [tool] = request.observation_tools

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.ObservationChoice{
                        tool_id: tool.id,
                        selectors: %{"path" => "/var/log/messages"},
                        parameters: %{"path" => "/var/log/messages"},
                        reason: "Inspect the current error source"
                      },
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 3}
                    }}
                 end
               }
             )

    observation_intent = Cases.get_turn!(observation_turn.id, authorize?: false).result["intent"]
    assert observation_intent["type"] == "observation_choice"
    assert observation_intent["selectors"] == %{"path" => "/var/log/messages"}
    assert observation_intent["tool"]["target_id"] == target.id
    assert observation_intent["tool"]["target_revision"] == target.revision
    assert observation_intent["tool"]["access_method_id"] == method.id
    assert observation_intent["tool"]["access_method_revision"] == method.revision
    assert observation_intent["tool"]["provider_id"] == method.provider_id
    assert observation_intent["tool"]["provider_revision"] == method.provider_revision
    assert observation_intent["tool"]["capability"] == "observe.system"
    assert observation_intent["tool"]["operation"] == "system.inspect"

    proposal_case =
      Cases.open_case!(
        :manual,
        "test",
        "proposal-snapshot",
        "Case proposal-snapshot",
        :warning,
        :not_applicable,
        %{},
        target.id,
        actor: context.operator
      )

    proposal_run = Cases.active_resolution_run!(proposal_case.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        proposal_case.id,
        proposal_run.id,
        nil,
        "proposal-snapshot-evidence",
        "observation",
        "fixture",
        "observation-1",
        %{"target_id" => target.id, "service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    proposal_turn = start_turn!(proposal_case, proposal_run, "proposal-snapshot")

    assert :ok =
             ResolverDelivery.run(proposal_turn.id,
               target_invocation: target_invocation(capabilities),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [observation_tool] = request.observation_tools
                   [proposal_tool] = request.proposal_tools

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: proposal_tool.id,
                        target_id: proposal_tool.target_id,
                        target_revision: proposal_tool.target_revision,
                        access_method_id: proposal_tool.access_method_id,
                        access_method_revision: proposal_tool.access_method_revision,
                        capability: proposal_tool.capability,
                        operation: proposal_tool.operation,
                        selectors: %{"service" => "api"},
                        parameters: %{"service" => "api"},
                        reason: "Restart the unhealthy service",
                        evidence_ids: [evidence.id],
                        expected_result: %{"service" => "running"},
                        verification_intent: %AI.VerificationIntent{
                          tool_id: observation_tool.id,
                          selectors: %{"path" => "/var/log/messages"},
                          parameters: %{"path" => "/var/log/messages"},
                          expected_result: %{"errors" => "absent"}
                        }
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 4}
                    }}
                 end
               }
             )

    proposal_intent = Cases.get_turn!(proposal_turn.id, authorize?: false).result["intent"]
    assert proposal_intent["type"] == "proposal"
    assert proposal_intent["selectors"] == %{"service" => "api"}
    assert proposal_intent["tool"]["provider_id"] == method.provider_id
    assert proposal_intent["tool"]["provider_revision"] == method.provider_revision

    assert proposal_intent["verification_intent"]["selectors"] == %{
             "path" => "/var/log/messages"
           }

    assert proposal_intent["verification_tool"]["id"] =~ "observation:"
    assert proposal_intent["verification_tool"]["access_method_id"] == method.id
    assert proposal_intent["verification_tool"]["provider_id"] == method.provider_id
    assert proposal_intent["verification_tool"]["provider_revision"] == method.provider_revision
    assert proposal_intent["verification_tool"]["operation"] == "system.inspect"
  end

  defp turn!(source_ref, actor) do
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

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "turn-#{source_ref}",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    {incident, run, started.value}
  end

  defp selected_turn!(source_ref, actor, target) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        :not_applicable,
        %{},
        target.id,
        actor: actor
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    start_turn!(incident, run, source_ref)
  end

  defp start_turn!(incident, run, key) do
    Cases.start_turn!(
      incident.id,
      run.id,
      "turn-#{key}",
      %{"objective" => "Resolve the incident"},
      %{"action" => "continue"},
      "Review Resolver limits",
      authorize?: false
    ).value
  end

  defp target_context!(admin) do
    provider =
      Providers.create_provider!(
        "snapshot-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "snapshot-target-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target =
      Targets.create_target!("snapshot-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "snapshot-ssh",
        "linux",
        "ssh",
        "ssh://snapshot",
        provider.revision,
        10,
        ["observe.system", "effect.service"],
        actor: admin
      )

    capabilities = %Target.Capabilities{
      observations: [
        %Target.Operation{
          capability: "observe.system",
          operation: "system.inspect",
          description: "Inspect system state",
          input_schema: %{"type" => "object"}
        }
      ],
      effects: [
        %Target.Operation{
          capability: "effect.service",
          operation: "service.restart",
          description: "Restart one service",
          input_schema: %{"type" => "object"}
        }
      ]
    }

    {target, method, capabilities}
  end

  defp target_invocation(capabilities) do
    %{
      test_pid: self(),
      respond: fn -> {:ok, capabilities} end,
      cancelled?: fn -> false end
    }
  end

  defp route_jobs(turn_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^Oban.Worker.to_string(DecisionRouteWorker) and
          fragment("?->>'turn_id'", job.args) == ^turn_id
    )
    |> Opsonde.Repo.all()
  end
end
