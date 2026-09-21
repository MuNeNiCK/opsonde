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

    [record] = Cases.list_ai_invocations!(authorize?: false)
    assert record.status == :completed
    assert record.input_tokens == 7
    assert record.output_tokens == 5

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

  test "known timeout persists a handoff without usage charge", context do
    {incident, run, turn} = turn!("timeout", context.operator)

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:error, :timeout, "model deadline exceeded"} end
               }
             )

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_failed"
    assert completed.result["category"] == "timeout"

    attention = Cases.get_case!(incident.id, authorize?: false)
    assert attention.status == :needs_attention
    assert attention.pending_intent == %{"action" => "retry_resolver", "turn_id" => turn.id}
    assert attention.stop_reason =~ "timeout"

    paused = Cases.get_resolution_run!(run.id, authorize?: false)
    assert paused.status == :needs_attention
    assert paused.ai_usage_units == 0

    record =
      Cases.list_ai_invocations!(authorize?: false)
      |> Enum.find(&(&1.turn_id == turn.id))

    assert record.status == :failed
    assert record.category == "timeout"
  end

  test "invalid output starts one bounded successor Turn", context do
    {incident, run, turn} = turn!("malformed", context.operator)

    assert :ok = invalid_output(turn)
    assert_receive {:resolve, %{api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_failed"
    assert completed.result["category"] == "invalid_output"
    assert completed.progress_kind == :none

    running = Cases.get_resolution_run!(run.id, authorize?: false)
    assert running.status == :running
    assert running.turn_count == 2
    assert running.no_progress_turns == 1
    assert running.ai_usage_units == 0

    [successor] =
      Cases.list_turns!(authorize?: false)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.status == :started))

    assert successor.intent == %{
             "category" => "invalid_output",
             "objective" => "Continue resolution after an invalid Resolver response",
             "source" => "resolver_delivery_failure",
             "source_turn_id" => turn.id
           }

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running

    assert current.pending_intent == %{
             "action" => "resolve_turn",
             "turn_id" => successor.id,
             "source_turn_id" => turn.id
           }

    assert :ok = invalid_output(turn, fn -> flunk("completed Turn called AI again") end)
    refute_receive {:resolve, _, _}

    assert Enum.count(Cases.list_turns!(authorize?: false), &(&1.resolution_run_id == run.id)) ==
             2

    assert :ok = invalid_output(successor)
    assert_receive {:resolve, %{api_key: @api_key}, _request}

    exhausted = Cases.get_case!(incident.id, authorize?: false)
    assert exhausted.status == :needs_attention
    assert exhausted.stop_reason == "No-progress turn limit exhausted"

    exhausted_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert exhausted_run.status == :needs_attention
    assert exhausted_run.turn_count == 2
    assert exhausted_run.no_progress_turns == 2

    assert Enum.count(Cases.list_turns!(authorize?: false), &(&1.resolution_run_id == run.id)) ==
             2
  end

  test "an interrupted dispatch becomes visible without a second AI call", context do
    incident =
      Cases.open_case!(
        :signal,
        "alertmanager",
        "interrupted",
        "Service is unavailable",
        :critical,
        :firing,
        %{},
        nil,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    turn = start_turn!(incident, run, "interrupted")
    parent = self()

    task =
      Task.async(fn ->
        ResolverDelivery.run(turn.id,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :resolver_remote_started)
              receive do: (:never -> :unreachable)
            end
          }
        )
      end)

    assert_receive {:resolve, _, _request}
    assert_receive :resolver_remote_started

    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.record_case_source_recovery!(current.id, current.revision, authorize?: false)
    assert nil == Task.shutdown(task, :brutal_kill)

    [dispatching] = Cases.list_ai_invocations!(authorize?: false)
    assert dispatching.status == :dispatching
    assert dispatching.reserved_units == 10_000

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("interrupted dispatch called AI again") end
               }
             )

    refute_receive {:resolve, _, _}

    [unknown] = Cases.list_ai_invocations!(authorize?: false)
    assert unknown.id == dispatching.id
    assert unknown.status == :unknown
    assert unknown.category == "response_unknown"

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_unknown"
    assert completed.result["reserved_usage_units"] == 10_000

    paused = Cases.get_case!(incident.id, authorize?: false)
    assert paused.status == :needs_attention

    assert paused.pending_intent == %{
             "action" => "review_resolver_response",
             "turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 10_000

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("unknown dispatch called AI again") end
               }
             )

    events = Cases.list_case_events!(actor: context.admin)

    assert Enum.count(events, fn event ->
             event.data["request_key"] == "resolver-unknown:#{unknown.id}"
           end) == 1
  end

  test "a competing Turn completion still accounts for the later AI result", context do
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
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 20

    [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
    assert invocation.category == "superseded"
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

  test "source changes during AI resolution rerun the same Turn from fresh context", context do
    incident =
      Cases.open_case!(
        :signal,
        "alertmanager",
        "source-change",
        "Service is unavailable",
        :critical,
        :firing,
        %{},
        nil,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    verification =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "source-change-verification",
        "target_verification",
        "target_provider",
        "verification-1",
        %{
          "status" => "verified",
          "facts" => %{"state" => "healthy"},
          "expected" => %{"state" => "healthy"}
        },
        DateTime.utc_now(),
        authorize?: false
      )

    turn = start_turn!(incident, run, "source-change")

    stale = %AI.ResolverDecision{
      intent: %AI.Handoff{reason: "Old firing context", required_input: "Inspect the alert"},
      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
    }

    assert {:snooze, 1} =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :firing
                   current = Cases.get_case!(incident.id, authorize?: false)

                   Cases.record_case_source_recovery!(current.id, current.revision,
                     authorize?: false
                   )

                   {:ok, stale}
                 end
               }
             )

    assert_receive {:resolve, _, %{alert_state: :firing}}
    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12

    [discarded] = Cases.list_ai_invocations!(authorize?: false)
    assert discarded.status == :completed
    assert discarded.category == "context_changed"

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.event_type == "case_needs_attention")
           )

    recovery = %AI.ResolverDecision{
      intent: %AI.RecoveryConclusion{
        reason: "The source recovered and target verification is healthy",
        evidence_ids: [verification.id]
      },
      usage: %AI.Usage{input_tokens: 4, output_tokens: 3}
    }

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered
                   assert AI.recovery_ready?(request)
                   {:ok, recovery}
                 end
               }
             )

    assert_receive {:resolve, _, %{alert_state: :recovered}}
    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "decision"
    assert completed.result["intent"]["type"] == "recovery_conclusion"
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 19

    invocations = Cases.list_ai_invocations!(authorize?: false)
    assert Enum.count(invocations) == 2
    assert Enum.count(invocations, &(&1.category == "context_changed")) == 1
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
                   tool = Enum.find(request.proposal_tools, &(&1.request_kind == :observation))

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: tool.id,
                        target_id: tool.target_id,
                        target_revision: tool.target_revision,
                        access_method_id: tool.access_method_id,
                        access_method_revision: tool.access_method_revision,
                        request_kind: :observation,
                        capability: tool.capability,
                        operation: tool.operation,
                        selectors: %{"path" => "/var/log/messages"},
                        parameters: %{"path" => "/var/log/messages"},
                        reason: "Inspect the current error source",
                        evidence_ids: []
                      },
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 3}
                    }}
                 end
               }
             )

    observation_intent = Cases.get_turn!(observation_turn.id, authorize?: false).result["intent"]
    assert observation_intent["type"] == "proposal"
    assert observation_intent["request_kind"] == "observation"
    assert observation_intent["selectors"] == %{"path" => "/var/log/messages"}
    assert observation_intent["tool"]["target_id"] == target.id
    assert observation_intent["tool"]["target_revision"] == target.revision
    assert observation_intent["tool"]["access_method_id"] == method.id
    assert observation_intent["tool"]["access_method_revision"] == method.revision
    assert observation_intent["tool"]["provider_id"] == method.provider_id
    assert observation_intent["tool"]["provider_revision"] == method.provider_revision
    assert observation_intent["tool"]["request_kind"] == "observation"
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
        :en,
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
                   proposal_tool =
                     Enum.find(request.proposal_tools, &(&1.request_kind == :effect))

                   [observation_tool] = request.observation_tools

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: proposal_tool.id,
                        target_id: proposal_tool.target_id,
                        target_revision: proposal_tool.target_revision,
                        access_method_id: proposal_tool.access_method_id,
                        access_method_revision: proposal_tool.access_method_revision,
                        request_kind: :effect,
                        capability: proposal_tool.capability,
                        operation: proposal_tool.operation,
                        selectors: %{"service" => "api"},
                        parameters: %{
                          "service" => "api",
                          "enabled" => true,
                          "expected_enabled" => false,
                          "optional" => nil
                        },
                        reason: "Restart the unhealthy service",
                        evidence_ids: [evidence.id],
                        expected_result: %{"service" => "running"},
                        verification_intent: %AI.VerificationIntent{
                          tool_id: observation_tool.id,
                          selectors: %{"service" => "api"},
                          parameters: %{"service" => "api"},
                          expected_result: %{"service" => "running"}
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

    assert proposal_intent["parameters"] == %{
             "service" => "api",
             "enabled" => true,
             "expected_enabled" => false,
             "optional" => nil
           }

    assert proposal_intent["tool"]["provider_id"] == method.provider_id
    assert proposal_intent["tool"]["provider_revision"] == method.provider_revision
    assert proposal_intent["tool"]["request_kind"] == "effect"

    assert proposal_intent["verification_intent"]["selectors"] == %{
             "service" => "api"
           }

    assert proposal_intent["verification_tool"]["id"] =~ "observation:"
    assert proposal_intent["verification_tool"]["access_method_id"] == method.id
    assert proposal_intent["verification_tool"]["provider_id"] == method.provider_id
    assert proposal_intent["verification_tool"]["provider_revision"] == method.provider_revision
    assert proposal_intent["verification_tool"]["operation"] == "system.inspect"
  end

  test "accepted relationship snapshot reaches the durable related Target route", context do
    {linux, linux_method, capabilities} = target_context!(context.admin)

    vm =
      Targets.create_target!(
        "snapshot-vm",
        "virtual_machine",
        "vmware_vm",
        %{},
        nil,
        actor: context.admin
      )

    vm_method =
      Targets.create_access_method!(
        vm.id,
        linux_method.provider_id,
        "snapshot-vm-ssh",
        "vmware_vm",
        "ssh",
        "ssh://snapshot-vm",
        linux_method.provider_revision,
        10,
        ["observe.system"],
        actor: context.admin
      )

    relationship =
      Targets.create_relationship!(linux.id, vm.id, "runs_on", %{}, nil, actor: context.admin)

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "relationship-snapshot",
        "Investigate Linux I/O errors",
        :critical,
        :not_applicable,
        %{},
        linux.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "relationship-snapshot-evidence",
        "observation",
        "fixture",
        "io-errors",
        %{"target_id" => linux.id, "io_errors" => 12},
        DateTime.utc_now(),
        authorize?: false
      )

    turn = start_turn!(incident, run, "relationship-snapshot")

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation: target_invocation(capabilities),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [offered] = request.target_relations

                   assert offered.id == relationship.id
                   assert offered.revision == relationship.revision
                   assert offered.source_target.id == linux.id
                   assert offered.destination_target.id == vm.id

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetTraversal{
                        relationship_id: offered.id,
                        relationship_revision: offered.revision,
                        next_target_id: offered.destination_target.id,
                        next_target_revision: offered.destination_target.revision,
                        evidence_ids: [evidence.id],
                        reason: "The I/O evidence implicates the VM layer"
                      },
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 3}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    intent = completed.result["intent"]
    assert intent["type"] == "target_traversal"
    assert intent["relationship"]["id"] == relationship.id
    assert intent["relationship"]["revision"] == relationship.revision
    assert intent["relationship"]["source_target_revision"] == linux.revision
    assert intent["relationship"]["destination_target_revision"] == vm.revision

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == vm.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 1

    [event] =
      Cases.list_case_events!(actor: context.admin)
      |> Enum.filter(&(&1.event_type == "related_target_traversed"))

    assert event.data["relationship_id"] == relationship.id
    assert event.data["next_target_id"] == vm.id

    assert [available_method] =
             Targets.available_access_methods_for_target!(vm.id, authorize?: false)

    assert available_method.id == vm_method.id
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
        :en,
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
        :en,
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
          input_schema: %{"type" => "object"},
          output_schema: %{
            "type" => "object",
            "properties" => %{"status" => %{"type" => "string"}},
            "additionalProperties" => false
          },
          verification_schema: %{
            "type" => "object",
            "properties" => %{"service" => %{"type" => "string"}},
            "minProperties" => 1,
            "additionalProperties" => false
          }
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

  defp invalid_output(turn, callback \\ fn -> {:ok, %{}} end) do
    ResolverDelivery.run(turn.id,
      ai_invocation: %{
        test_pid: self(),
        respond: fn _request -> callback.() end
      }
    )
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
