defmodule Opsonde.DecisionRouteWorkerTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.DecisionRouteWorker

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("route-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("route-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "route-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "route-target-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("route-effect-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "route-ssh",
        "linux",
        "ssh",
        "ssh://route-effect-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "persisted Target discovery is routed once across duplicate delivery", context do
    target =
      Targets.create_target!("route-linux", "host", "linux", %{}, nil, actor: context.admin)

    {incident, run} = open_case!("target-search", context.operator)

    turn =
      completed_turn!(incident, run, "target-search", %{
        "type" => "target_search",
        "query" => "route-linux",
        "reason" => "Find the registered affected host"
      })

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    assert [evidence] =
             Cases.list_evidence!(actor: context.admin)
             |> Enum.filter(&(&1.case_id == incident.id))

    assert evidence.kind == "target_candidates"
    assert Enum.any?(evidence.content["targets"], &(&1["id"] == target.id))

    assert Enum.count(Cases.list_turns!(actor: context.admin), &(&1.case_id == incident.id)) == 2
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  test "persisted Proposal reaches the authority pending state without an effect", context do
    {incident, run} = open_case!("proposal", context.operator)
    evidence = evidence!(incident, run, "proposal")

    turn =
      completed_turn!(incident, run, "proposal", proposal_intent(evidence.id, context), :proposal)

    assert :ok =
             DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    assert :ok =
             DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    routed = Cases.get_case!(incident.id, authorize?: false)

    [proposal] = Cases.list_proposals!(actor: context.admin)

    assert proposal.status == :recommended

    assert routed.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
           }

    assert routed.status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  test "malformed persisted decision becomes explicit attention without Target calls", context do
    {incident, run} = open_case!("malformed", context.operator)

    turn =
      completed_turn!(incident, run, "malformed", %{
        "type" => "unrecognized_intent",
        "request" => %{"operation" => "must-not-run"}
      })

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    attention = Cases.get_case!(incident.id, authorize?: false)
    assert attention.status == :needs_attention
    assert attention.stop_reason == "Resolver decision routing failed"

    assert attention.pending_intent == %{
             "action" => "review_resolver_route",
             "source_turn_id" => turn.id
           }

    paused = Cases.get_resolution_run!(run.id, authorize?: false)
    assert paused.status == :needs_attention
    assert paused.target_request_count == 0
    assert paused.effect_count == 0
    assert Cases.list_evidence!(actor: context.admin) == []
  end

  defp open_case!(source_ref, actor) do
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

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp completed_turn!(incident, run, suffix, intent, progress_kind \\ :hypothesis) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "decision-route-#{suffix}",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    Cases.complete_turn!(
      started.value.id,
      started.value.revision,
      %{
        "outcome" => "decision",
        "intent" => intent,
        "resolver" => resolver_identity(),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      progress_kind,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "route-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp proposal_intent(evidence_id, context) do
    target_id = context.target.id
    access_method_id = context.method.id
    provider_id = context.provider.id

    %{
      "type" => "proposal",
      "tool_id" => "effect-tool",
      "target_id" => target_id,
      "target_revision" => 1,
      "access_method_id" => access_method_id,
      "access_method_revision" => 1,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the failed service",
      "evidence_ids" => [evidence_id],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "id" => "effect-tool",
        "target_id" => target_id,
        "target_revision" => 1,
        "access_method_id" => access_method_id,
        "access_method_revision" => 1,
        "provider_id" => provider_id,
        "provider_revision" => 1,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
      "verification_intent" => %{
        "tool_id" => "observation-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "observation-tool",
        "target_id" => target_id,
        "target_revision" => 1,
        "access_method_id" => access_method_id,
        "access_method_revision" => 1,
        "provider_id" => provider_id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp resolver_identity do
    %{
      "provider_id" => Ash.UUID.generate(),
      "provider_revision" => 1,
      "assignment_id" => Ash.UUID.generate(),
      "assignment_revision" => 1
    }
  end
end
