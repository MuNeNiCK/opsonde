defmodule Opsonde.ObservationRouteTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Providers.Target

  @password "correct horse battery staple"
  @token "observation-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("observation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("observation-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "observation-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @token},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("observe-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "observe-ssh",
        "linux",
        "ssh",
        "ssh://observe-linux",
        provider.revision,
        10,
        ["observe.system"],
        actor: admin
      )

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "exact cleared observation becomes Evidence before one next Turn", context do
    {incident, run, turn} = observation_turn!("success", context)

    observation = %Target.Observation{
      facts: %{"errors" => 7},
      evidence: [%{"line" => "I/O error"}],
      observed_at: DateTime.utc_now()
    }

    assert {:ok, routed} =
             Cases.route_observation(turn.id, invocation(observation), authorize?: false)

    assert routed.status == :charged
    assert routed.value.ordinal == 2

    assert_receive {:observe, %{token: @token}, request}
    assert request.target_id == context.target.id
    assert request.target_revision == context.target.revision
    assert request.access_method_id == context.method.id
    assert request.access_method_revision == context.method.revision
    assert request.capability == "observe.system"
    assert request.operation == "system.inspect"
    assert request.selectors == %{"path" => "/var/log/messages"}
    assert request.parameters == %{"lines" => 100}
    assert request.max_attempts == 1

    [evidence] =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.filter(&(&1.turn_id == turn.id))

    assert evidence.kind == "observation"
    assert evidence.source == "target_provider"
    assert evidence.content["target_id"] == context.target.id
    assert evidence.content["tool_id"] == "observation-tool"
    assert evidence.content["facts"] == %{"errors" => 7}

    refreshed = Cases.get_resolution_run!(run.id, authorize?: false)
    assert refreshed.target_request_count == 1
    assert refreshed.turn_count == 2

    assert {:ok, replayed} =
             Cases.route_observation(
               turn.id,
               %{test_pid: self(), respond: fn -> flunk("duplicate route called adapter") end},
               authorize?: false
             )

    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id
    refute_receive {:observe, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "TargetPolicy denial and stale context become Evidence without adapter calls", context do
    Targets.create_target_policy!(
      context.target.id,
      "protect-credentials",
      [:observation],
      ["observe.system"],
      ["system.inspect"],
      %{"path" => %{"prefix" => "/usr/credential"}},
      %{},
      "credential path is forbidden",
      actor: context.admin
    )

    {_denied_case, denied_run, denied_turn} =
      observation_turn!("denied", context, selectors: %{"path" => "/usr/credential/service"})

    assert {:ok, denied} =
             Cases.route_observation(denied_turn.id, unreachable_invocation(), authorize?: false)

    assert denied.value.ordinal == 2
    assert Cases.get_resolution_run!(denied_run.id, authorize?: false).target_request_count == 0

    denied_evidence = evidence_for_turn!(denied_turn.id, context.admin)
    assert denied_evidence.kind == "observation_error"
    assert denied_evidence.source == "target_policy"
    assert denied_evidence.content["category"] == "denied"

    {_stale_case, stale_run, stale_turn} = observation_turn!("stale", context)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{facts: %{"site" => "osaka"}},
      actor: context.admin
    )

    assert {:ok, stale} =
             Cases.route_observation(stale_turn.id, unreachable_invocation(), authorize?: false)

    assert stale.value.ordinal == 2
    assert Cases.get_resolution_run!(stale_run.id, authorize?: false).target_request_count == 0

    stale_evidence = evidence_for_turn!(stale_turn.id, context.admin)
    assert stale_evidence.source == "target_policy"
    assert stale_evidence.content["category"] == "stale_context"
    refute_receive {:observe, _, _}
  end

  test "typed Provider failure is charged once and feeds the next Resolver", context do
    {_incident, run, turn} = observation_turn!("timeout", context)

    assert {:ok, routed} =
             Cases.route_observation(
               turn.id,
               %{
                 test_pid: self(),
                 respond: fn -> {:error, :timeout, "read deadline exceeded"} end
               },
               authorize?: false
             )

    assert routed.value.ordinal == 2
    assert_receive {:observe, %{token: @token}, _request}

    evidence = evidence_for_turn!(turn.id, context.admin)
    assert evidence.kind == "observation_error"
    assert evidence.source == "target_provider"
    assert evidence.content["category"] == "timeout"
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  test "persisted Provider identity mismatch fails before charge or adapter dispatch", context do
    {_incident, run, turn} =
      observation_turn!("provider-mismatch", context,
        provider_id: Ash.UUID.generate(),
        provider_revision: context.provider.revision
      )

    assert {:ok, routed} =
             Cases.route_observation(turn.id, unreachable_invocation(), authorize?: false)

    assert routed.value.ordinal == 2
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 0

    evidence = evidence_for_turn!(turn.id, context.admin)
    assert evidence.source == "target_policy"
    assert evidence.content["category"] == "stale_context"
    refute_receive {:observe, _, _}
  end

  defp observation_turn!(source_ref, context, opts \\ []) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        :not_applicable,
        %{},
        context.target.id,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "source-#{source_ref}",
        %{"objective" => "Inspect the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    selectors = Keyword.get(opts, :selectors, %{"path" => "/var/log/messages"})
    provider_id = Keyword.get(opts, :provider_id, context.provider.id)
    provider_revision = Keyword.get(opts, :provider_revision, context.provider.revision)

    completed =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
          "intent" => %{
            "type" => "observation_choice",
            "tool_id" => "observation-tool",
            "tool" => %{
              "id" => "observation-tool",
              "target_id" => context.target.id,
              "target_revision" => context.target.revision,
              "access_method_id" => context.method.id,
              "access_method_revision" => context.method.revision,
              "provider_id" => provider_id,
              "provider_revision" => provider_revision,
              "capability" => "observe.system",
              "operation" => "system.inspect"
            },
            "selectors" => selectors,
            "parameters" => %{"lines" => 100},
            "reason" => "Inspect current system errors"
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      )

    {incident, completed.run, completed.value}
  end

  defp evidence_for_turn!(turn_id, actor) do
    Cases.list_evidence!(actor: actor)
    |> Enum.find(&(&1.turn_id == turn_id))
  end

  defp invocation(%Target.Observation{} = observation),
    do: %{test_pid: self(), respond: fn -> {:ok, observation} end}

  defp unreachable_invocation,
    do: %{test_pid: self(), respond: fn -> flunk("denied request reached adapter") end}
end
