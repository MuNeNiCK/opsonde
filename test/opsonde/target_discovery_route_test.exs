defmodule Opsonde.TargetDiscoveryRouteTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Targets}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("route-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("route-operator@example.com", @password, :operator, actor: admin)

    target =
      Targets.create_target!(
        "linux-route-01",
        "host",
        "linux",
        %{"site" => "tokyo"},
        nil,
        actor: admin
      )

    %{admin: admin, operator: operator, target: target}
  end

  test "persisted Target search routes once to candidate Evidence and the next Turn", context do
    {incident, run, source_turn} = completed_turn!("search", context.operator, search_intent())

    assert {:ok, routed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert routed.status == :charged
    assert routed.value.ordinal == 2
    assert routed.value.intent["source"] == "target_search"

    assert {:ok, replayed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id

    refreshed = Cases.get_resolution_run!(run.id, authorize?: false)
    assert refreshed.target_request_count == 1
    assert refreshed.turn_count == 2

    evidence = Cases.list_evidence!(actor: context.admin)
    assert [candidate] = Enum.filter(evidence, &(&1.kind == "target_candidates"))
    assert candidate.id == routed.value.intent["evidence_id"]

    assert [%{"id" => target_id, "revision" => target_revision}] =
             candidate.content["targets"]

    assert target_id == context.target.id
    assert target_revision == context.target.revision
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == nil
  end

  test "persisted Target selection can use only cited candidates and starts one next Turn",
       context do
    incident = open!("selection", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "selection-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    intent = %{
      "type" => "target_selection",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "evidence_ids" => [searched.value.id],
      "reason" => "The name and site match the incident"
    }

    source_turn = completed_turn!(incident, searched.run, "selection", intent)

    assert {:ok, routed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert routed.status == :charged
    assert routed.value.ordinal == 2
    assert routed.value.intent["selected_target_id"] == context.target.id

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == context.target.id
    assert selected.selected_target_revision == context.target.revision

    assert {:ok, replayed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id

    events = Cases.list_case_events!(actor: context.admin)
    assert Enum.count(events, &(&1.event_type == "case_target_selected")) == 1
    assert Targets.list_external_identities!(actor: context.admin) == []
  end

  test "stale selection and non-discovery results fail without a next Turn", context do
    incident = open!("rejected", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "rejected-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    intent = %{
      "type" => "target_selection",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "evidence_ids" => [searched.value.id],
      "reason" => "Use the stale candidate"
    }

    source_turn = completed_turn!(incident, searched.run, "rejected", intent)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{facts: %{"site" => "osaka"}},
      actor: context.admin
    )

    assert {:error, _error} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == nil
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == 1

    {_other_case, _other_run, other_turn} =
      completed_turn!("not-discovery", context.operator, %{
        "type" => "handoff",
        "reason" => "Need input",
        "required_input" => "Confirm ownership"
      })

    assert {:error, _error} = Cases.route_target_discovery(other_turn.id, authorize?: false)
  end

  defp completed_turn!(source_ref, actor, intent) do
    incident = open!(source_ref, actor)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    {incident, run, completed_turn!(incident, run, source_ref, intent)}
  end

  defp completed_turn!(incident, run, key, intent) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "source-#{key}",
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
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      :hypothesis,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp open!(source_ref, actor) do
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
  end

  defp search_intent do
    %{
      "type" => "target_search",
      "query" => "linux-route-01",
      "reason" => "Find the registered Target"
    }
  end
end
