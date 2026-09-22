defmodule Opsonde.RelatedTargetRouteTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.ResolverProjection
  alias Opsonde.Providers.{AI, Target}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("relation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("relation-operator@example.com", @password, :operator, actor: admin)

    configure_limits!(admin, 8)

    provider =
      Providers.create_provider!(
        "relationship-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "relationship-provider-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    linux = target!(admin, provider, "linux-01", "host", "linux", "linux-ssh")
    vm = target!(admin, provider, "vm-01", "virtual_machine", "vmware_vm", "vm-ssh")
    bmc = target!(admin, provider, "bmc-01", "bmc", "redfish", "bmc-redfish")
    kubernetes = target!(admin, provider, "cluster-01", "cluster", "kubernetes", "k8s-api")
    switch = target!(admin, provider, "switch-01", "network", "ios-xe", "switch-netconf")

    runs_on = relationship!(admin, linux, vm, "runs_on")
    managed_by = relationship!(admin, vm, bmc, "managed_by")
    hosted_by = relationship!(admin, kubernetes, linux, "hosted_by")
    connected_through = relationship!(admin, linux, switch, "connected_through")

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      linux: linux,
      vm: vm,
      bmc: bmc,
      kubernetes: kubernetes,
      switch: switch,
      runs_on: runs_on,
      managed_by: managed_by,
      hosted_by: hosted_by,
      connected_through: connected_through
    }
  end

  test "Resolver traverses evidence-selected layers without family branches or inherited access",
       context do
    {incident, run, evidence, first_turn} = case_with_evidence!("layered", context)

    assert {:ok, request} = projection(first_turn, context)

    assert adjacent_target_ids(request, context.linux.id) ==
             MapSet.new([context.vm.id, context.kubernetes.id, context.switch.id])

    assert Enum.map(request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.linux.id)
           ]

    vm_source = complete_traversal!(first_turn, context.runs_on, context.vm, evidence)
    vm_turn = route_traversal!(vm_source)

    assert route_traversal!(vm_source).id == vm_turn.id
    assert vm_turn.intent["evidence_ids"] == [evidence.id]
    assert vm_turn.intent["reason"] == "The current evidence implicates the adjacent layer"

    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.vm.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "turn_id" => vm_turn.id,
             "source_turn_id" => vm_source.id
           }

    assert {:ok, vm_request} = projection(vm_turn, context)

    assert adjacent_target_ids(vm_request, context.vm.id) ==
             MapSet.new([context.linux.id, context.bmc.id])

    assert Enum.map(vm_request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.vm.id)
           ]

    bmc_turn =
      vm_turn
      |> complete_traversal!(context.managed_by, context.bmc, evidence)
      |> route_traversal!()

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == context.bmc.id
    assert selected.selected_target_revision == context.bmc.revision

    assert {:ok, bmc_request} = projection(bmc_turn, context)
    assert adjacent_target_ids(bmc_request, context.bmc.id) == MapSet.new([context.vm.id])

    assert Enum.map(bmc_request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.bmc.id)
           ]

    refreshed_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert refreshed_run.related_target_count == 2

    traversal_events =
      Cases.list_case_events!(actor: context.admin)
      |> Enum.filter(&(&1.event_type == "related_target_traversed"))

    assert Enum.map(traversal_events, & &1.data["relationship_revision"]) == [1, 1]

    assert Enum.map(traversal_events, & &1.data["next_target_id"]) == [
             context.vm.id,
             context.bmc.id
           ]
  end

  test "layer revisits are allowed until the related Target ceiling is reached",
       context do
    {cycle_case, cycle_run, cycle_evidence, cycle_first_turn} =
      case_with_evidence!("cycle", context)

    cycle_vm_turn =
      cycle_first_turn
      |> complete_traversal!(context.runs_on, context.vm, cycle_evidence)
      |> route_traversal!()

    cycle_source =
      complete_traversal!(cycle_vm_turn, context.runs_on, context.linux, cycle_evidence)

    linux_turn = route_traversal!(cycle_source)
    assert linux_turn.status == :started

    assert Cases.get_case!(cycle_case.id, authorize?: false).selected_target_id ==
             context.linux.id

    assert Cases.get_resolution_run!(cycle_run.id, authorize?: false).related_target_count == 2

    configure_limits!(context.admin, 1)
    {incident, run, evidence, first_turn} = case_with_evidence!("bounded", context)

    vm_turn =
      first_turn
      |> complete_traversal!(context.runs_on, context.vm, evidence)
      |> route_traversal!()

    bmc_source = complete_traversal!(vm_turn, context.managed_by, context.bmc, evidence)
    assert {:ok, exhausted} = Cases.route_related_target(bmc_source.id, authorize?: false)
    assert exhausted.status == :exhausted

    stopped_case = Cases.get_case!(incident.id, authorize?: false)
    assert stopped_case.status == :needs_attention
    assert stopped_case.stop_reason == "Related Target limit exhausted"
    assert stopped_case.selected_target_id == context.vm.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 1
  end

  test "a resumed run can traverse with the Case's current Signal evidence", context do
    source_ref = "resumed-relation"

    incident =
      Cases.open_case!(
        :signal,
        "alertmanager",
        source_ref,
        "Kubernetes workload is unavailable",
        :critical,
        :firing,
        %{},
        context.linux.id,
        :en,
        actor: context.operator
      )

    prior_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    signal =
      Cases.append_evidence!(
        incident.id,
        prior_run.id,
        nil,
        "resumed-relation-signal",
        "signal_event",
        "zabbix",
        "secondary-resumed-relation",
        %{"current" => true, "state" => "firing"},
        DateTime.utc_now(),
        authorize?: false
      )

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        prior_run.id,
        prior_run.revision,
        "resumed-relation-attention",
        "Resolver interrupted",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(prior_run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        paused_run.authority_mode,
        paused_run.max_elapsed_seconds,
        paused_run.max_resolver_turns,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "Continue autonomous resolution",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    next_turn =
      resumed_turn
      |> complete_traversal!(context.runs_on, context.vm, signal)
      |> route_traversal!()

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.status == :running
    assert selected.selected_target_id == context.vm.id
    assert next_turn.resolution_run_id == resumed_run.id
    refute evidence_for_source_turn!(resumed_turn.id, context.admin)
  end

  test "stale relationships, changed authority, and missing Access Methods become Evidence",
       context do
    {stale_case, stale_run, stale_evidence, stale_turn} =
      case_with_evidence!("stale-edge", context)

    stale_source =
      complete_traversal!(stale_turn, context.runs_on, context.vm, stale_evidence)

    Targets.update_relationship!(
      context.runs_on,
      context.runs_on.revision,
      %{facts: %{"rack" => "r2"}},
      actor: context.admin
    )

    assert {:ok, _next} = Cases.route_related_target(stale_source.id, authorize?: false)
    stale_failure = evidence_for_source_turn!(stale_source.id, context.admin)
    assert stale_failure.content["category"] == "stale_relationship"

    assert {:ok, replayed_stale} =
             Cases.route_related_target(stale_source.id, authorize?: false)

    assert replayed_stale.status == :duplicate

    assert Enum.count(
             Cases.list_evidence!(actor: context.admin),
             &(&1.turn_id == stale_source.id and &1.kind == "relationship_traversal_error")
           ) == 1

    assert Cases.get_case!(stale_case.id, authorize?: false).selected_target_id ==
             context.linux.id

    assert Cases.get_resolution_run!(stale_run.id, authorize?: false).related_target_count == 0

    denied_relationship =
      relationship!(context.admin, context.linux, context.vm, "supported_by")

    {denied_case, denied_run, denied_evidence, denied_turn} =
      case_with_evidence!("denied-owner", context)

    denied_source =
      complete_traversal!(denied_turn, denied_relationship, context.vm, denied_evidence)

    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:ok, _next} = Cases.route_related_target(denied_source.id, authorize?: false)
    denied_failure = evidence_for_source_turn!(denied_source.id, context.admin)
    assert denied_failure.content["category"] == "denied"

    assert Cases.get_case!(denied_case.id, authorize?: false).selected_target_id ==
             context.linux.id

    assert Cases.get_resolution_run!(denied_run.id, authorize?: false).related_target_count == 0

    Accounts.change_role!(
      Accounts.get_user!(context.operator.id, authorize?: false),
      :operator,
      actor: context.admin
    )

    unavailable =
      Targets.create_target!(
        "unavailable-01",
        "host",
        "freebsd",
        %{},
        nil,
        actor: context.admin
      )

    relationship = relationship!(context.admin, context.linux, unavailable, "peers_with")
    {incident, run, evidence, turn} = case_with_evidence!("missing-method", context)
    source_turn = complete_traversal!(turn, relationship, unavailable, evidence)

    assert {:ok, _next} = Cases.route_related_target(source_turn.id, authorize?: false)
    failure = evidence_for_source_turn!(source_turn.id, context.admin)
    assert failure.content["category"] == "unavailable"
    assert failure.content["message"] =~ "no available Access Method"
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.linux.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 0
  end

  defp case_with_evidence!(source_ref, context) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Investigate Linux I/O errors",
        :critical,
        :not_applicable,
        %{"symptom" => "I/O errors are increasing"},
        context.linux.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "signal-#{source_ref}",
        "signal",
        "zabbix",
        source_ref,
        %{"target_id" => context.linux.id, "message" => "I/O errors are increasing"},
        DateTime.utc_now(),
        authorize?: false
      )

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        "start-#{source_ref}",
        %{"objective" => "Find and resolve the I/O fault"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    {incident, run, evidence, turn}
  end

  defp complete_traversal!(turn, relationship, next_target, evidence) do
    incident = Cases.get_case!(turn.case_id, authorize?: false)

    result =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => traversal_intent(relationship, incident, next_target, evidence),
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      )

    result.value
  end

  defp traversal_intent(relationship, incident, next_target, evidence) do
    source = Targets.get_target!(relationship.source_target_id, authorize?: false)
    destination = Targets.get_target!(relationship.destination_target_id, authorize?: false)

    %{
      "type" => "target_traversal",
      "relationship_id" => relationship.id,
      "relationship_revision" => relationship.revision,
      "next_target_id" => next_target.id,
      "next_target_revision" => next_target.revision,
      "evidence_ids" => [evidence.id],
      "reason" => "The current evidence implicates the adjacent layer",
      "relationship" => %{
        "id" => relationship.id,
        "revision" => relationship.revision,
        "source_target_id" => source.id,
        "source_target_revision" => source.revision,
        "destination_target_id" => destination.id,
        "destination_target_revision" => destination.revision,
        "kind" => relationship.kind,
        "selected_target_id" => incident.selected_target_id
      }
    }
  end

  defp route_traversal!(source_turn) do
    Cases.route_related_target!(source_turn.id, authorize?: false).value
  end

  defp projection(turn, _context) do
    ResolverProjection.build(turn.id, selection(), %{
      test_pid: self(),
      respond: fn -> {:ok, capabilities()} end,
      cancelled?: fn -> false end
    })
  end

  defp adjacent_target_ids(request, current_target_id) do
    request.target_relations
    |> Enum.map(fn relationship ->
      if relationship.source_target.id == current_target_id,
        do: relationship.destination_target.id,
        else: relationship.source_target.id
    end)
    |> MapSet.new()
  end

  defp access_method_id!(target_id) do
    [method] = Targets.available_access_methods_for_target!(target_id, authorize?: false)
    method.id
  end

  defp evidence_for_source_turn!(turn_id, actor) do
    Cases.list_evidence!(actor: actor)
    |> Enum.find(&(&1.turn_id == turn_id and &1.kind == "relationship_traversal_error"))
  end

  defp target!(admin, provider, name, kind, platform, method_name) do
    target = Targets.create_target!(name, kind, platform, %{}, nil, actor: admin)

    Targets.create_access_method!(
      target.id,
      provider.id,
      method_name,
      platform,
      method_name,
      "fixture://#{name}",
      provider.revision,
      10,
      ["observe.system"],
      actor: admin
    )

    target
  end

  defp relationship!(admin, source, destination, kind) do
    Targets.create_relationship!(source.id, destination.id, kind, %{}, nil, actor: admin)
  end

  defp selection do
    %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }
  end

  defp capabilities do
    %Target.Capabilities{
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
          }
        }
      ],
      effects: []
    }
  end

  defp configure_limits!(admin, max_related_targets) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      600,
      20,
      20,
      5,
      max_related_targets,
      100_000,
      10,
      "configure related Target tests",
      actor: admin
    )
  end
end
