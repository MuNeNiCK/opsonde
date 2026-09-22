defmodule Opsonde.ResolverProjectionTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Cases, Providers, Targets}
  alias Opsonde.Cases.ResolverProjection
  alias Opsonde.Providers.{AI, Target}

  @password "correct horse battery staple"
  @provider_secret "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("projection-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("projection-operator@example.com", @password, :operator, actor: admin)

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
      "configure Resolver projection",
      actor: admin
    )

    provider =
      Providers.create_provider!(
        "projection-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @provider_secret},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target =
      Targets.create_target!(
        "linux-01",
        "host",
        "linux",
        %{"site" => "tokyo"},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "primary-ssh",
        "linux",
        "ssh",
        "ssh://endpoint-secret",
        provider.revision,
        10,
        ["observe.system", "effect.service"],
        actor: admin
      )

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method
    }
  end

  test "selected Target projection exposes only the active method-operation intersection",
       context do
    other =
      Targets.create_target!("switch-01", "network", "ios-xe", %{}, nil, actor: context.admin)

    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    {incident, run} = open!("selected", operator, context.target)

    signal =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "projection-signal",
        "signal",
        "zabbix",
        "event-1",
        %{"target_id" => context.target.id, "message" => "disk errors increasing"},
        DateTime.utc_now(),
        authorize?: false
      )

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "projection-search",
        "switch-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    assert searched.value.content["targets"] |> hd() |> Map.fetch!("id") == other.id

    started = start!(incident, searched.run, "selected-turn")

    capabilities = %Target.Capabilities{
      observations: [
        operation("observe.system", "system.inspect", "Inspect using #{@provider_secret}"),
        operation("observe.network", "network.inspect", "Inspect network state")
      ],
      effects: [
        operation("effect.service", "service.restart", "Restart one service"),
        operation("effect.user", "user.disable", "Disable one user")
      ]
    }

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(capabilities)
             )

    assert request.case_id == incident.id
    assert request.turn == 1
    assert request.session_id == "resolver:#{run.id}"
    assert request.alert_state == :not_applicable
    assert request.report_language == :ja
    assert request.selected_target_id == context.target.id
    assert request.selected_target_revision == context.target.revision
    assert request.budget.remaining_turns == 4
    assert request.budget.remaining_target_requests == 4

    assert [%AI.ObservationTool{} = observation] = request.observation_tools
    assert observation.access_method_id == context.method.id
    assert observation.provider_id == context.provider.id
    assert observation.provider_revision == context.provider.revision
    assert observation.capability == "observe.system"
    assert observation.operation == "system.inspect"
    assert observation.description == "Inspect using [REDACTED]"

    assert [%AI.ProposalTool{} = observation_request, %AI.ProposalTool{} = proposal] =
             request.proposal_tools

    assert observation_request.request_kind == :observation
    assert proposal.request_kind == :effect
    assert proposal.provider_id == context.provider.id
    assert proposal.provider_revision == context.provider.revision
    assert proposal.capability == "effect.service"
    assert proposal.operation == "service.restart"

    assert Enum.any?(
             request.evidence,
             &(&1.id == signal.id and &1.target_id == context.target.id)
           )

    assert [%AI.TargetCandidate{id: candidate_id}] = request.target_candidates
    assert candidate_id == other.id
    assert other.id in request.disclosure.allowed_target_ids

    encoded = inspect(request)
    refute encoded =~ @provider_secret
    refute encoded =~ "endpoint-secret"

    assert_receive {:capabilities, %{token: @provider_secret}}
    refute_receive {:observe, _, _}
    refute_receive {:effect, _, _}
    refute_receive {:resolve, _, _}
  end

  test "effect tools require a matching observation fact before disclosure", context do
    {incident, run} = open!("evidence-gate", context.operator, context.target)
    started = start!(incident, run, "evidence-gate-turn")

    observation = operation("observe.system", "system.inspect", "Inspect system state")

    effect = %Target.Operation{
      capability: "effect.service",
      operation: "service.restart",
      description: "Restart using the observed state",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{"type" => "object", "maxProperties" => 0},
          "parameters" => %{
            "type" => "object",
            "properties" => %{"expected_status" => %{"type" => "string"}},
            "required" => ["expected_status"],
            "additionalProperties" => false
          }
        },
        "required" => ["selectors", "parameters"],
        "additionalProperties" => false
      },
      evidence_requirements: [
        %Target.EvidenceRequirement{
          parameter: "expected_status",
          fact: "status",
          observation: "system.inspect"
        }
      ]
    }

    capabilities = %Target.Capabilities{observations: [observation], effects: [effect]}

    assert {:ok, before_observation} =
             ResolverProjection.build(started.value.id, selection(), invocation(capabilities))

    assert [%AI.ObservationTool{id: observation_tool_id}] =
             before_observation.observation_tools

    assert [%AI.ProposalTool{request_kind: :observation}] =
             before_observation.proposal_tools

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-gate-observation",
        "observation",
        "target_provider",
        observation_tool_id,
        %{
          "target_id" => context.target.id,
          "tool_id" => observation_tool_id,
          "facts" => %{"status" => "inactive"}
        },
        DateTime.utc_now(),
        authorize?: false
      )

    assert {:ok, after_observation} =
             ResolverProjection.build(started.value.id, selection(), invocation(capabilities))

    assert [_observation_request, %AI.ProposalTool{} = proposal] =
             after_observation.proposal_tools

    assert proposal.operation == "service.restart"
    assert proposal.evidence_requirements == effect.evidence_requirements
    assert Enum.any?(after_observation.evidence, &(&1.id == evidence.id))
  end

  test "preselection projection exposes candidates without probing Target providers", context do
    {incident, run} = open!("preselection", context.operator)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "preselection-search",
        "linux-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    started = start!(incident, searched.run, "preselection-turn")

    assert {:ok, request} =
             ResolverProjection.build(started.value.id, selection(), %{
               test_pid: self(),
               respond: fn -> flunk("preselection reached a Target provider") end
             })

    assert is_nil(request.selected_target_id)
    assert request.observation_tools == []
    assert request.proposal_tools == []
    assert [%AI.TargetCandidate{id: target_id}] = request.target_candidates
    assert target_id == context.target.id
    refute_receive {:capabilities, _}
  end

  test "projection enforces the AI contract byte and item ceilings", context do
    {incident, run} = open!("bounded", context.operator, context.target)

    for index <- 1..50 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "bounded-evidence-#{index}",
        "observation",
        "fixture",
        "observation-#{index}",
        %{
          "target_id" => context.target.id,
          "ordinal" => index,
          "payload" => String.duplicate("x", 2_000)
        },
        DateTime.utc_now(),
        authorize?: false
      )
    end

    started = start!(incident, run, "bounded-turn")

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(%Target.Capabilities{observations: [], effects: []})
             )

    limits = AI.resolver_disclosure_limits()
    assert length(AI.resolver_disclosure_items(request)) <= limits.max_items
    assert AI.resolver_disclosure_size(request) <= limits.max_bytes
    assert length(request.evidence) <= limits.max_items
    assert :ok = AI.Validator.validate_request(:resolve, request)
  end

  test "projection keeps structured facts and bounds only indispensable diagnostics", context do
    {incident, run} = open!("compact-evidence", context.operator, context.target)

    applied =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-applied-observation",
        "observation",
        "operation",
        Ecto.UUID.generate(),
        %{
          "request_kind" => "observation",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "observe.service",
          "operation" => "service.inspect",
          "selectors" => %{"unit" => "api.service"},
          "parameters" => %{},
          "status" => "applied",
          "category" => "target_observed",
          "facts" => %{"active_state" => "inactive"},
          "details" => %{
            "stdout" => %{"encoding" => "utf-8", "value" => String.duplicate("x", 8_000)}
          }
        },
        DateTime.utc_now(),
        authorize?: false
      )

    failed =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-failed-effect",
        "operation_outcome",
        "operation",
        Ecto.UUID.generate(),
        %{
          "request_kind" => "effect",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "native.ssh",
          "operation" => "command.execute",
          "selectors" => %{},
          "parameters" => %{"command" => "systemctl start api.service"},
          "status" => "failed",
          "category" => "target_failed",
          "facts" => %{},
          "details" => %{
            "exit_status" => 1,
            "stderr" => %{
              "encoding" => "utf-8",
              "value" => "Interactive authentication required\n" <> String.duplicate("x", 4_000)
            }
          }
        },
        DateTime.add(DateTime.utc_now(), 1, :second),
        authorize?: false
      )

    verification =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-verification",
        "target_verification",
        "verification",
        Ecto.UUID.generate(),
        %{
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "operation_id" => Ecto.UUID.generate(),
          "status" => "not_verified",
          "category" => "target_not_verified",
          "expected" => %{"active_state" => "active"},
          "facts" => %{"active_state" => "inactive"},
          "provider_evidence" => %{"raw" => String.duplicate("x", 8_000)}
        },
        DateTime.add(DateTime.utc_now(), 2, :second),
        authorize?: false
      )

    started = start!(incident, run, "compact-evidence-turn")

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(%Target.Capabilities{observations: [], effects: []})
             )

    projected_applied = Enum.find(request.evidence, &(&1.id == applied.id))
    assert projected_applied.content["facts"] == %{"active_state" => "inactive"}
    refute Map.has_key?(projected_applied.content, "details")
    refute Map.has_key?(projected_applied.content, "diagnostics")

    projected_failed = Enum.find(request.evidence, &(&1.id == failed.id))
    assert projected_failed.content["diagnostics"]["exit_status"] == 1
    assert projected_failed.content["diagnostics"]["stderr"]["truncated"]

    assert String.starts_with?(
             projected_failed.content["diagnostics"]["stderr"]["value"],
             "Interactive authentication required"
           )

    projected_verification = Enum.find(request.evidence, &(&1.id == verification.id))
    assert projected_verification.content["facts"] == %{"active_state" => "inactive"}
    refute Map.has_key?(projected_verification.content, "provider_evidence")
  end

  test "projection reserves the latest context from every correlated Signal source", context do
    incident =
      Cases.open_case!(
        :signal,
        "alertmanager",
        "alert-fingerprint",
        "Kubernetes workload is unavailable",
        :critical,
        :firing,
        %{"target_ref" => %{"kind" => "instance", "value" => "cluster-01"}},
        context.target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    now = DateTime.utc_now()

    stale =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "multi-source-alert-stale",
        "signal_event",
        "alertmanager",
        "alert-fingerprint",
        %{
          "current" => true,
          "state" => "firing",
          "attributes" => %{"title" => "Stale alert title"}
        },
        DateTime.add(now, -2, :second),
        authorize?: false
      )

    alertmanager =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "multi-source-alert-current",
        "signal_event",
        "alertmanager",
        "alert-fingerprint",
        %{
          "current" => true,
          "state" => "firing",
          "attributes" => %{"title" => "Kubernetes workload is unavailable"}
        },
        now,
        authorize?: false
      )

    zabbix =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "multi-source-zabbix-current",
        "signal_event",
        "zabbix",
        "zabbix-event-42",
        %{
          "current" => true,
          "state" => "firing",
          "attributes" => %{
            "title" => "opsonde-validation.service is inactive on linux-01"
          }
        },
        DateTime.add(now, 1, :second),
        authorize?: false
      )

    other =
      Targets.create_target!("candidate-01", "host", "linux", %{}, nil, actor: context.admin)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "multi-source-search",
        "candidate-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    for index <- 1..50 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "multi-source-history-#{index}",
        "observation",
        "fixture",
        "history-#{index}",
        %{
          "target_id" => context.target.id,
          "payload" => String.duplicate("x", 2_000),
          "ordinal" => index
        },
        DateTime.add(now, index + 1, :second),
        authorize?: false
      )
    end

    started = start!(incident, searched.run, "multi-source-turn")

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(%Target.Capabilities{observations: [], effects: []})
             )

    signal_evidence = Enum.filter(request.evidence, &(&1.kind == "signal_event"))

    assert MapSet.new(Enum.map(signal_evidence, & &1.id)) ==
             MapSet.new([alertmanager.id, zabbix.id])

    refute Enum.any?(request.evidence, &(&1.id == stale.id))

    assert Enum.any?(signal_evidence, fn evidence ->
             get_in(evidence.content, ["attributes", "title"]) ==
               "opsonde-validation.service is inactive on linux-01"
           end)

    assert Enum.any?(request.target_candidates, &(&1.id == other.id))
    assert :ok = AI.Validator.validate_request(:resolve, request)
  end

  test "projection keeps only the latest result of an identical Target request", context do
    {incident, run} = open!("repeated-observation", context.operator, context.target)
    now = DateTime.utc_now()

    evidence = fn key, selectors, observed_at ->
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        key,
        "observation",
        "operation",
        key,
        %{
          "request_kind" => "observation",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "observe.service",
          "operation" => "service.inspect",
          "selectors" => selectors,
          "parameters" => %{},
          "status" => "failed"
        },
        observed_at,
        authorize?: false
      )
    end

    older = evidence.("same-request-older", %{"unit" => "api.service"}, DateTime.add(now, -2))
    newest = evidence.("same-request-newest", %{"unit" => "api.service"}, now)

    different =
      evidence.("different-request", %{"unit" => "worker.service"}, DateTime.add(now, -1))

    started = start!(incident, run, "repeated-observation-turn")

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(%Target.Capabilities{observations: [], effects: []})
             )

    evidence_ids = Enum.map(request.evidence, & &1.id)
    assert newest.id in evidence_ids
    assert different.id in evidence_ids
    refute older.id in evidence_ids
  end

  test "only a current-run Target observation after source recovery is recovery eligible",
       context do
    {incident, run} = open!("recovery-observation", context.operator, context.target)
    recovered_at = DateTime.utc_now()

    incident =
      Cases.update_case_record!(
        incident,
        incident.revision,
        %{source_recovered_at: recovered_at},
        authorize?: false
      )

    stale =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "recovery-observation-stale",
        "observation",
        "operation",
        Ecto.UUID.generate(),
        target_observation(context, %{"ready" => false}),
        DateTime.add(recovered_at, -1, :second),
        authorize?: false
      )

    fresh =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "recovery-observation-fresh",
        "observation",
        "operation",
        Ecto.UUID.generate(),
        target_observation(context, %{"ready" => true}),
        DateTime.add(recovered_at, 1, :second),
        authorize?: false
      )

    started = start!(incident, run, "recovery-observation-turn")

    assert {:ok, request} =
             ResolverProjection.build(
               started.value.id,
               selection(),
               invocation(%Target.Capabilities{observations: [], effects: []})
             )

    projected_stale = Enum.find(request.evidence, &(&1.id == stale.id))
    projected_fresh = Enum.find(request.evidence, &(&1.id == fresh.id))

    assert projected_stale.content["recovery_eligible"] == false
    assert projected_fresh.content["recovery_eligible"] == true
    assert AI.recovery_evidence_ids(request) == [fresh.id]
  end

  test "inactive methods and disabled Providers are never exposed as tools", context do
    {method_case, method_run} = open!("inactive-method", context.operator, context.target)
    method_turn = start!(method_case, method_run, "inactive-method-turn")

    Targets.deactivate_access_method!(context.method, context.method.revision,
      actor: context.admin
    )

    assert {:ok, method_request} =
             ResolverProjection.build(method_turn.value.id, selection(), unreachable_invocation())

    assert method_request.observation_tools == []
    assert method_request.proposal_tools == []

    second_method =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "secondary-ssh",
        "linux",
        "ssh",
        "ssh://secondary",
        context.provider.revision,
        20,
        ["observe.system"],
        actor: context.admin
      )

    assert second_method.active
    {provider_case, provider_run} = open!("disabled-provider", context.operator, context.target)
    provider_turn = start!(provider_case, provider_run, "disabled-provider-turn")

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    assert {:ok, provider_request} =
             ResolverProjection.build(
               provider_turn.value.id,
               selection(),
               unreachable_invocation()
             )

    assert provider_request.observation_tools == []
    assert provider_request.proposal_tools == []
    refute_receive {:capabilities, _}
  end

  test "cancelled Cases and stale selected Targets stop before capability probing", context do
    {incident, run} = open!("cancelled", context.operator, context.target)
    started = start!(incident, run, "cancelled-turn")
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert {:error, "Case cancellation was requested"} =
             ResolverProjection.build(started.value.id, selection(), unreachable_invocation())

    {stale_case, stale_run} = open!("stale", context.operator, context.target)
    stale_turn = start!(stale_case, stale_run, "stale-turn")

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{facts: %{"site" => "osaka"}},
      actor: context.admin
    )

    assert {:error, "Selected Target revision changed"} =
             ResolverProjection.build(stale_turn.value.id, selection(), unreachable_invocation())

    refute_receive {:capabilities, _}
  end

  defp open!(source_ref, actor, target \\ nil) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        :not_applicable,
        %{"symptom" => "service unavailable"},
        target && target.id,
        :en,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp start!(incident, run, key) do
    Cases.start_turn!(
      incident.id,
      run.id,
      key,
      %{"objective" => "Identify and resolve the incident"},
      %{"action" => "continue"},
      "Review Resolver limits",
      authorize?: false
    )
  end

  defp selection do
    %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 7,
      source: :assignment
    }
  end

  defp operation(capability, operation, description) do
    %Target.Operation{
      capability: capability,
      operation: operation,
      description: description,
      input_schema: %{"type" => "object"},
      output_schema: %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      verification_schema: %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "minProperties" => 1,
        "additionalProperties" => false
      }
    }
  end

  defp target_observation(context, facts) do
    %{
      "status" => "applied",
      "category" => "target_observed",
      "request_kind" => "observation",
      "target_id" => context.target.id,
      "access_method_id" => context.method.id,
      "capability" => "observe.system",
      "operation" => "system.inspect",
      "selectors" => %{},
      "parameters" => facts,
      "facts" => facts
    }
  end

  defp invocation(capabilities) do
    %{
      test_pid: self(),
      respond: fn -> {:ok, capabilities} end,
      cancelled?: fn -> false end
    }
  end

  defp unreachable_invocation do
    %{
      test_pid: self(),
      respond: fn -> flunk("ineligible projection reached a Target provider") end
    }
  end
end
