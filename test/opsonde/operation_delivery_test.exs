defmodule Opsonde.OperationDeliveryTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.{OperationDelivery, OperationWorker}
  alias Opsonde.Providers.Target

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("operation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operation-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "operation-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "operation-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("operation-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "operation-ssh",
        "linux",
        "ssh",
        "ssh://operation-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    resolver_provider =
      Providers.create_provider!(
        "operation-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    resolver_assignment =
      Providers.create_ai_usage_role_assignment!(resolver_provider.id, :resolver, 10,
        actor: admin
      )

    configure_mode!(admin, :full_access)

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment
    }
  end

  test "accepting an authorized Proposal is atomic and idempotent", context do
    {_incident, run, proposal} = authorized_proposal!("accept", context)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    duplicate = Cases.accept_operation!(proposal.id, authorize?: false)

    assert duplicate.id == operation.id
    assert operation.id == proposal.reserved_operation_id
    assert operation.status == :queued
    assert operation.proposal_revision == proposal.revision
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1
    assert operation_jobs(operation.id) == 1

    assert %{"operation_id" => operation.id} == operation_job(operation.id).args
    refute_receive {:effect, _, _}
  end

  test "revoked approval authority creates no Operation, job or budget charge", context do
    {_incident, run, proposal} = authorized_proposal!("revoked", context)
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}
  end

  test "a Target Policy added after approval prevents acceptance", context do
    {_incident, run, proposal} = authorized_proposal!("policy-before-accept", context)

    Targets.create_target_policy!(
      context.target.id,
      "deny-operation-acceptance",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "The API service must not be restarted",
      actor: context.admin
    )

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}
  end

  test "effect exhaustion persists attention without an Operation or job", context do
    configure_mode!(context.admin, :full_access, 0)
    {incident, run, proposal} = authorized_proposal!("exhausted", context)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert operation_jobs(proposal.reserved_operation_id) == 0

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "review_effect_limit"
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "each normalized Target outcome is sent and persisted once", context do
    for status <- [:applied, :failed, :partial, :unknown] do
      {incident, _run, proposal} = authorized_proposal!("outcome-#{status}", context)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      result = %Target.EffectResult{
        status: status,
        reference: "remote-#{status}",
        details: %{"status" => to_string(status)}
      }

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, result})
               )

      assert_receive {:effect, _state, request}
      assert request.operation_id == operation.id
      assert request.idempotency_key == operation.idempotency_key

      stored = Cases.get_operation!(operation.id, authorize?: false)
      assert stored.status == status
      assert stored.reference == "remote-#{status}"
      assert stored.result_details == %{"status" => to_string(status)}

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("terminal Operation was resent") end)
               )

      refute_receive {:effect, _, _}

      assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
               "verify_operation"

      assert operation_evidence(operation.id) == 1
    end
  end

  test "a lost adapter response becomes unknown and is never resent", context do
    {_incident, _run, proposal} = authorized_proposal!("lost-response", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> raise "remote response lost" end)
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("unknown Operation was resent") end)
             )

    refute_receive {:effect, _, _}
  end

  test "authorization changed after acceptance fails before Target dispatch", context do
    {_incident, _run, proposal} = authorized_proposal!("policy-before-dispatch", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Targets.create_target_policy!(
      context.target.id,
      "deny-operation-dispatch",
      [:effect],
      ["effect.service"],
      ["service.restart"],
      %{"service" => %{"eq" => "api"}},
      %{},
      "The API service must not be restarted",
      actor: context.admin
    )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("invalidated Operation was sent") end)
             )

    invalidated = Cases.get_operation!(operation.id, authorize?: false)
    assert invalidated.status == :failed
    assert invalidated.outcome_category == "authorization_invalidated"
    refute_receive {:effect, _, _}
  end

  test "restart after the dispatch marker converges to unknown without a send", context do
    {_incident, _run, proposal} = authorized_proposal!("restart", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
    assert claim.state == :claimed
    assert claim.operation.status == :dispatching

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("recovered dispatch was resent") end)
             )

    recovered = Cases.get_operation!(operation.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    refute_receive {:effect, _, _}
    assert operation_evidence(operation.id) == 1
  end

  test "cancellation before claim records no-send failure", context do
    {incident, _run, proposal} = authorized_proposal!("cancel", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("cancelled Operation was sent") end)
             )

    cancelled = Cases.get_operation!(operation.id, authorize?: false)
    assert cancelled.status == :failed
    assert cancelled.outcome_category == "cancelled_before_dispatch"
    refute_receive {:effect, _, _}
  end

  defp authorized_proposal!(suffix, context) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "operation-#{suffix}",
        "Operation #{suffix}",
        :warning,
        :not_applicable,
        %{},
        context.target.id,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "operation-evidence-#{suffix}",
        "observation",
        "fixture",
        "observation-#{suffix}",
        %{"service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "operation-turn-#{suffix}",
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
          "intent" => proposal_intent(evidence.id, context),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    authorized = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    {incident, run, authorized}
  end

  defp proposal_intent(evidence_id, context) do
    tool = %{
      "id" => "effect-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
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
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp configure_mode!(admin, mode, max_effects \\ nil) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      max_effects || current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "test #{mode} Operation delivery",
      actor: admin
    )
  end

  defp invocation(response) when is_function(response, 0),
    do: %{test_pid: self(), respond: response}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response end}

  defp operation_jobs(operation_id) do
    Opsonde.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      ),
      :count
    )
  end

  defp operation_job(operation_id) do
    Opsonde.Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      )
    )
  end

  defp operation_evidence(operation_id) do
    Opsonde.Repo.aggregate(
      from(evidence in Opsonde.Cases.Evidence,
        where: evidence.idempotency_key == ^"operation:outcome:#{operation_id}"
      ),
      :count
    )
  end
end
