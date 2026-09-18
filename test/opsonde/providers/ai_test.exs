defmodule Opsonde.Providers.AITest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.Providers
  alias Opsonde.Providers.AI

  @password "correct horse battery staple"
  @api_key "ai-provider-secret"

  setup do
    admin = Accounts.bootstrap!("ai-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("ai-operator@example.com", @password, :operator, actor: admin)

    provider = create_ai_provider!(admin, "ai-provider", "test-model")

    %{admin: admin, operator: operator, provider: provider}
  end

  test "one AI provider carries resolver and reviewer roles without connection duplication",
       context do
    resolver = assign!(context.admin, context.provider, :resolver, 20)
    reviewer = assign!(context.admin, context.provider, :reviewer, 10)

    assert resolver.provider_id == reviewer.provider_id
    assert resolver.role == :resolver
    assert reviewer.role == :reviewer

    for assignment <- Providers.list_ai_usage_role_assignments!(actor: context.admin) do
      fields = Map.from_struct(assignment)
      refute Map.has_key?(fields, :configuration)
      refute Map.has_key?(fields, :credentials)
    end

    assert {:error, _error} =
             Providers.create_ai_usage_role_assignment(
               context.provider.id,
               :resolver,
               30,
               actor: context.admin
             )

    target_provider =
      Providers.create_provider!(
        "not-ai",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "target-token"},
        actor: context.admin
      )

    assert {:error, wrong_kind} =
             Providers.create_ai_usage_role_assignment(
               target_provider.id,
               :reviewer,
               10,
               actor: context.admin
             )

    assert Exception.message(wrong_kind) =~ "must reference an AI provider"
  end

  test "selection uses priority and reviewer fallback reuses the exact resolver provider",
       context do
    resolver_assignment = assign!(context.admin, context.provider, :resolver, 50)
    reviewer_provider = create_ai_provider!(context.admin, "reviewer-provider", "review-model")
    reviewer_assignment = assign!(context.admin, reviewer_provider, :reviewer, 10)
    backup_reviewer = create_ai_provider!(context.admin, "backup-reviewer", "backup-model")
    backup_assignment = assign!(context.admin, backup_reviewer, :reviewer, 20)

    assert %AI.Selection{
             role: :resolver,
             provider_id: resolver_id,
             provider_revision: resolver_revision,
             source: :assignment,
             assignment_id: resolver_assignment_id,
             assignment_revision: resolver_assignment_revision
           } = Providers.select_resolver_ai!(actor: context.operator)

    assert resolver_id == context.provider.id
    assert resolver_revision == context.provider.revision
    assert resolver_assignment_id == resolver_assignment.id

    assert %AI.Selection{
             role: :reviewer,
             provider_id: reviewer_id,
             source: :assignment,
             assignment_id: reviewer_assignment_id
           } =
             Providers.select_reviewer_ai!(
               resolver_assignment_id,
               resolver_assignment_revision,
               resolver_revision,
               actor: context.operator
             )

    assert reviewer_id == reviewer_provider.id
    assert reviewer_assignment_id == reviewer_assignment.id

    Providers.update_ai_usage_role_assignment!(
      reviewer_assignment,
      reviewer_assignment.revision,
      %{enabled: false},
      actor: context.admin
    )

    Providers.update_ai_usage_role_assignment!(
      backup_assignment,
      backup_assignment.revision,
      %{enabled: false},
      actor: context.admin
    )

    assert %AI.Selection{
             role: :reviewer,
             provider_id: ^resolver_id,
             provider_revision: ^resolver_revision,
             source: :resolver_fallback,
             assignment_id: ^resolver_assignment_id,
             assignment_revision: ^resolver_assignment_revision
           } =
             Providers.select_reviewer_ai!(
               resolver_assignment_id,
               resolver_assignment_revision,
               resolver_revision,
               actor: context.operator
             )

    Providers.update_ai_usage_role_assignment!(
      resolver_assignment,
      resolver_assignment.revision,
      %{priority: 40},
      actor: context.admin
    )

    assert {:error, _stale_resolver} =
             Providers.select_reviewer_ai(
               resolver_assignment_id,
               resolver_assignment_revision,
               resolver_revision,
               actor: context.operator
             )
  end

  test "Resolver returns exactly one observation, proposal, recovery or handoff intent",
       context do
    request = resolver_request(context.provider.revision)

    observation = %AI.ObservationChoice{
      tool_id: "inspect-system",
      selectors: %{},
      parameters: %{},
      reason: "Collect current system state"
    }

    assert %AI.ResolverDecision{intent: ^observation} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: observation, usage: usage()}}
             end)

    assert_receive {:resolve, %{model: "test-model", api_key: @api_key}, ^request}

    proposal = proposal()
    later_request = %{request | turn: 2, observation_results: [observation_result()]}

    assert %AI.ResolverDecision{intent: ^proposal} =
             resolve!(context, later_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: proposal, usage: usage()}}
             end)

    recovered_request = %{later_request | turn: 3, alert_state: :recovered}

    recovery = %AI.RecoveryConclusion{
      reason: "The alert recovered after fresh verification",
      evidence_ids: ["observation-1"]
    }

    assert %AI.ResolverDecision{intent: ^recovery} =
             resolve!(context, recovered_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: recovery, usage: usage()}}
             end)

    handoff = %AI.Handoff{
      reason: "A physical inspection is required",
      required_input: "Confirm the drive fault LED"
    }

    assert %AI.ResolverDecision{intent: ^handoff} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: handoff, usage: usage()}}
             end)

    manual_request = %{later_request | alert_state: :not_applicable}

    assert %AI.ResolverDecision{intent: ^handoff} =
             resolve!(context, manual_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: handoff, usage: usage()}}
             end)

    assert %AI.ResolverDecision{intent: ^recovery} =
             resolve!(context, manual_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: recovery, usage: usage()}}
             end)
  end

  test "Resolver searches and selects only a bounded offered Target before tools are exposed",
       context do
    request = preselection_request(context.provider.revision)

    search = %AI.TargetSearch{
      query: "linux-01 disk error",
      reason: "Find the registered Target named by the alert facts"
    }

    assert %AI.ResolverDecision{intent: ^search} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: search, usage: usage()}}
             end)

    candidate = %AI.TargetCandidate{
      id: "target-1",
      revision: 3,
      name: "linux-01",
      kind: "host",
      platform: "linux",
      facts: %{"environment" => "production"}
    }

    candidate_request = %{request | turn: 2, target_candidates: [candidate]}

    selection = %AI.TargetSelection{
      target_id: candidate.id,
      target_revision: candidate.revision,
      evidence_ids: ["evidence-1"],
      reason: "The registered name and environment match the firing alert"
    }

    assert %AI.ResolverDecision{intent: ^selection} =
             resolve!(context, candidate_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: selection, usage: usage()}}
             end)

    for invalid <- [
          %{selection | target_id: "invented-target"},
          %{selection | target_revision: candidate.revision + 1}
        ] do
      assert {:error, error} =
               resolve(context, candidate_request, fn _request ->
                 {:ok, %AI.ResolverDecision{intent: invalid, usage: usage()}}
               end)

      assert ai_error(error).category == :invalid_output
    end

    [tool] = resolver_request(context.provider.revision).observation_tools
    premature_tools = %{request | observation_tools: [tool]}

    assert {:error, premature_error} =
             resolve(context, premature_tools, unreachable_response())

    assert ai_error(premature_error).category == :invalid_input

    selected_request = resolver_request(context.provider.revision)

    assert %AI.ResolverDecision{intent: ^search} =
             resolve!(context, selected_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: search, usage: usage()}}
             end)

    undisclosed_candidate = %{
      candidate_request
      | disclosure: %{request.disclosure | allowed_target_ids: []}
    }

    assert {:error, disclosure_error} =
             resolve(context, undisclosed_candidate, unreachable_response())

    assert ai_error(disclosure_error).category == :disclosure_limit
  end

  test "Resolver tool inputs must satisfy the exact offered JSON Schema", context do
    schema = %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => %{"service" => %{"type" => "string", "minLength" => 1}},
          "required" => ["service"],
          "additionalProperties" => false
        },
        "parameters" => %{"type" => "object", "maxProperties" => 0}
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }

    request = resolver_request(context.provider.revision)
    [observation_tool] = request.observation_tools
    [proposal_tool] = request.proposal_tools

    request = %{
      request
      | observation_tools: [%{observation_tool | input_schema: schema}],
        proposal_tools: [%{proposal_tool | input_schema: schema}]
    }

    valid_observation = %AI.ObservationChoice{
      tool_id: observation_tool.id,
      selectors: %{"service" => "api"},
      parameters: %{},
      reason: "Inspect the named service"
    }

    assert %AI.ResolverDecision{intent: ^valid_observation} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: valid_observation, usage: usage()}}
             end)

    self_verifying_proposal = %{
      proposal()
      | selectors: %{"service" => "api"},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: proposal_tool.id,
          selectors: %{"service" => "api"},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert %AI.ResolverDecision{intent: ^self_verifying_proposal} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: self_verifying_proposal, usage: usage()}}
             end)

    invalid_observation = %{valid_observation | selectors: %{"service" => 42}}

    assert {:error, invalid_observation_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_observation, usage: usage()}}
             end)

    assert ai_error(invalid_observation_error).category == :invalid_output

    invalid_proposal = %{
      proposal()
      | selectors: %{},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{"service" => "api"},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert {:error, invalid_proposal_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_proposal, usage: usage()}}
             end)

    assert ai_error(invalid_proposal_error).category == :invalid_output

    invalid_verification = %{
      proposal()
      | selectors: %{"service" => "api"},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{"service" => 42},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert {:error, invalid_verification_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_verification, usage: usage()}}
             end)

    assert ai_error(invalid_verification_error).category == :invalid_output

    invalid_schema_request = %{
      request
      | observation_tools: [
          %{observation_tool | input_schema: %{"type" => "unsupported-json-type"}}
        ]
    }

    assert {:error, invalid_schema_error} =
             resolve(context, invalid_schema_request, unreachable_response())

    assert ai_error(invalid_schema_error).category == :invalid_input
  end

  test "Resolver rejects invented effects and recovery without fresh recovered evidence",
       context do
    request = resolver_request(context.provider.revision)
    invented = %{proposal() | tool_id: "invented-effect"}

    assert {:error, proposal_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented, usage: usage()}}
             end)

    assert ai_error(proposal_error).category == :invalid_output

    invented_method = %{proposal() | access_method_id: "invented-method"}

    assert {:error, exact_tool_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented_method, usage: usage()}}
             end)

    assert ai_error(exact_tool_error).category == :invalid_output

    invented_verification = %{
      proposal()
      | verification_intent: %{
          proposal().verification_intent
          | tool_id: "invented-verification"
        }
    }

    assert {:error, verification_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented_verification, usage: usage()}}
             end)

    assert ai_error(verification_error).category == :invalid_output

    recovery = %AI.RecoveryConclusion{
      reason: "Assume recovered",
      evidence_ids: ["evidence-1"]
    }

    assert {:error, recovery_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: recovery, usage: usage()}}
             end)

    assert ai_error(recovery_error).category == :invalid_output

    malformed_request = %{request | evidence: [%{}]}
    assert {:error, malformed} = resolve(context, malformed_request, unreachable_response())
    assert ai_error(malformed).category == :invalid_input

    [observation_tool] = request.observation_tools
    atom_capability = %{request | observation_tools: [%{observation_tool | capability: :system}]}

    assert {:error, vocabulary_error} =
             resolve(context, atom_capability, unreachable_response())

    assert ai_error(vocabulary_error).category == :invalid_input

    atom_kind = %{request | evidence: [%{evidence() | kind: :signal}]}
    assert {:error, kind_error} = resolve(context, atom_kind, unreachable_response())
    assert ai_error(kind_error).category == :invalid_input
  end

  test "Reviewer receives an isolated proposal-only request", context do
    request = review_request(context.provider.revision)

    assert %AI.ReviewDecision{verdict: :approved} =
             review!(context, request, fn received ->
               fields = Map.from_struct(received)
               refute Map.has_key?(fields, :observation_tools)
               refute Map.has_key?(fields, :proposal_tools)
               refute Map.has_key?(fields, :observation_results)

               {:ok,
                %AI.ReviewDecision{
                  verdict: :approved,
                  reason: "Proposal matches the cited evidence and policy",
                  usage: usage()
                }}
             end)

    assert_receive {:review, %{model: "test-model", api_key: @api_key}, ^request}

    final_turn = %{request | budget: %{request.budget | remaining_turns: 0}}

    assert %AI.ReviewDecision{verdict: :approved} =
             review!(context, final_turn, fn _received ->
               {:ok,
                %AI.ReviewDecision{
                  verdict: :approved,
                  reason: "Review does not consume a Resolver Turn",
                  usage: usage()
                }}
             end)

    assert_receive {:review, _, ^final_turn}

    same_session = %{request | session_id: request.resolver_session_id}

    assert {:error, isolated_error} = review(context, same_session, unreachable_response())
    assert ai_error(isolated_error).category == :invalid_input
    refute_receive {:review, _, ^same_session}

    assert {:error, malformed_output} =
             review(context, request, fn _request -> {:ok, %{verdict: :approved}} end)

    assert ai_error(malformed_output).category == :invalid_output
  end

  test "budgets, disclosure, cancellation and stale providers stop before model dispatch",
       context do
    request = resolver_request(context.provider.revision)

    assert {:error, cancelled} =
             Providers.ai_resolve(
               context.provider.id,
               request,
               %{cancelled?: fn -> true end},
               actor: context.admin
             )

    assert ai_error(cancelled).category == :cancelled

    exhausted = %{request | budget: %{request.budget | remaining_turns: 0}}
    assert {:error, exhausted_error} = resolve(context, exhausted, unreachable_response())
    assert ai_error(exhausted_error).category == :budget_exhausted

    undisclosed = %{request | disclosure: %{request.disclosure | max_bytes: 1}}
    assert {:error, disclosure_error} = resolve(context, undisclosed, unreachable_response())
    assert ai_error(disclosure_error).category == :disclosure_limit

    limits = AI.resolver_disclosure_limits()

    for disclosure <- [
          %{request.disclosure | max_items: limits.max_items + 1},
          %{request.disclosure | max_bytes: limits.max_bytes + 1},
          %{
            request.disclosure
            | allowed_target_ids: Enum.map(1..(limits.max_items + 1), &"target-#{&1}")
          }
        ] do
      assert {:error, invalid_limit} =
               resolve(context, %{request | disclosure: disclosure}, unreachable_response())

      assert ai_error(invalid_limit).category == :invalid_input
    end

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)
    assert {:error, _stale_error} = resolve(context, request, unreachable_response())
    refute_receive {:resolve, _, _}
  end

  test "token usage and provider failures stay typed and redact secrets", context do
    request = resolver_request(context.provider.revision)
    intent = %AI.Handoff{reason: "Need human input", required_input: "Inspect hardware"}

    for oversized_intent <- [
          %AI.Handoff{
            reason: String.duplicate("r", 501),
            required_input: "Inspect hardware"
          },
          %AI.Handoff{
            reason: "Need human input",
            required_input: String.duplicate("i", 1_001)
          },
          %{proposal() | reason: String.duplicate("r", 501)}
        ] do
      assert {:error, oversized_error} =
               resolve(context, request, fn _request ->
                 {:ok, %AI.ResolverDecision{intent: oversized_intent, usage: usage()}}
               end)

      assert ai_error(oversized_error).category == :invalid_output
    end

    assert {:error, invalid_usage} =
             resolve(context, request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: intent,
                  usage: %AI.Usage{input_tokens: -1, output_tokens: 1}
                }}
             end)

    assert ai_error(invalid_usage).category == :invalid_output

    assert {:error, exceeded} =
             resolve(context, request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: intent,
                  usage: %AI.Usage{input_tokens: 1_500, output_tokens: 501}
                }}
             end)

    assert ai_error(exceeded).category == :budget_exhausted

    secret_intent = %{intent | reason: "credential #{@api_key} requires inspection"}

    assert %AI.ResolverDecision{intent: %AI.Handoff{reason: redacted_reason}} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: secret_intent, usage: usage()}}
             end)

    assert redacted_reason == "credential [REDACTED] requires inspection"

    for category <- [:authentication, :unreachable, :timeout, :rate_limited, :failed] do
      assert {:error, error} =
               resolve(context, request, fn _request ->
                 {:error, category, "credential #{@api_key} failed"}
               end)

      assert ai_error(error).category == category
      assert ai_error(error).message == "credential [REDACTED] failed"
      refute inspect(error) =~ @api_key
    end
  end

  defp create_ai_provider!(admin, name, model) do
    Providers.create_provider!(
      name,
      :ai,
      "fixture-ai",
      %{
        "model" => model,
        "timeout_ms" => 30_000,
        "max_output_tokens" => 2_000
      },
      %{"api_key" => @api_key},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp assign!(admin, provider, role, priority) do
    Providers.create_ai_usage_role_assignment!(provider.id, role, priority, actor: admin)
  end

  defp resolve(context, request, respond) do
    Providers.ai_resolve(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp resolve!(context, request, respond) do
    Providers.ai_resolve!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp review(context, request, respond) do
    Providers.ai_review(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp review!(context, request, respond) do
    Providers.ai_review!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp resolver_request(provider_revision) do
    %AI.ResolverRequest{
      provider_revision: provider_revision,
      session_id: "resolver-session-1",
      case_id: "case-1",
      turn: 1,
      objective: "Restore service health",
      alert_state: :firing,
      disclosure: %AI.Disclosure{
        allowed_target_ids: ["target-1", "target-2"],
        allowed_evidence_kinds: ["signal", "observation"],
        max_items: 20,
        max_bytes: 20_000
      },
      budget: budget(),
      evidence: [evidence()],
      target_candidates: [],
      selected_target_id: "target-1",
      selected_target_revision: 1,
      observation_results: [],
      target_relations: [
        %AI.TargetRelation{
          id: "relation-1",
          revision: 1,
          source_target: target_candidate("target-1", "linux"),
          destination_target: target_candidate("target-2", "vmware_esxi"),
          kind: "runs_on"
        }
      ],
      observation_tools: [
        %AI.ObservationTool{
          id: "inspect-system",
          target_id: "target-1",
          target_revision: 1,
          access_method_id: "access-method-observe",
          access_method_revision: 1,
          provider_id: "target-provider",
          provider_revision: 1,
          capability: "observe.command",
          operation: "system.inspect",
          description: "Inspect system state",
          input_schema: %{}
        }
      ],
      proposal_tools: [
        %AI.ProposalTool{
          id: "restart-service",
          target_id: "target-1",
          target_revision: 1,
          access_method_id: "access-method-effect",
          access_method_revision: 1,
          provider_id: "target-provider",
          provider_revision: 1,
          capability: "effect.command",
          operation: "service.restart",
          description: "Restart one service",
          input_schema: %{}
        }
      ]
    }
  end

  defp preselection_request(provider_revision) do
    request = resolver_request(provider_revision)

    %{
      request
      | selected_target_id: nil,
        selected_target_revision: nil,
        target_candidates: [],
        target_relations: [],
        observation_tools: [],
        proposal_tools: [],
        evidence: [%{evidence() | target_id: nil}]
    }
  end

  defp review_request(provider_revision) do
    %AI.ReviewRequest{
      provider_revision: provider_revision,
      session_id: "reviewer-session-1",
      resolver_session_id: "resolver-session-1",
      case_id: "case-1",
      objective: "Restore service health",
      policy_summary: "Target policy permits this exact restart request",
      proposal: proposal(),
      cited_evidence: [evidence()],
      budget: budget()
    }
  end

  defp evidence do
    %AI.Evidence{
      id: "evidence-1",
      kind: "signal",
      target_id: "target-1",
      content: %{alert: "high load"}
    }
  end

  defp target_candidate(id, platform) do
    %AI.TargetCandidate{
      id: id,
      revision: 1,
      name: id,
      kind: "host",
      platform: platform,
      facts: %{}
    }
  end

  defp observation_result do
    %AI.ObservationResult{
      id: "observation-1",
      tool_id: "inspect-system",
      target_id: "target-1",
      kind: "observation",
      status: :ok,
      content: %{service: "healthy"}
    }
  end

  defp proposal do
    %AI.Proposal{
      tool_id: "restart-service",
      target_id: "target-1",
      target_revision: 1,
      access_method_id: "access-method-effect",
      access_method_revision: 1,
      capability: "effect.command",
      operation: "service.restart",
      selectors: %{service: "api"},
      parameters: %{service: "api"},
      reason: "Restart the unhealthy service",
      evidence_ids: ["evidence-1"],
      expected_result: %{service: "running"},
      verification_intent: %AI.VerificationIntent{
        tool_id: "inspect-system",
        selectors: %{service: "api"},
        parameters: %{service: "api"},
        expected_result: %{service: "running"}
      }
    }
  end

  defp budget do
    %AI.Budget{
      remaining_turns: 4,
      remaining_tokens: 2_000,
      remaining_target_requests: 5,
      remaining_effects: 2,
      remaining_related_targets: 3
    }
  end

  defp usage, do: %AI.Usage{input_tokens: 100, output_tokens: 50}

  defp unreachable_response,
    do: fn _request -> flunk("invalid request reached AI adapter") end

  defp ai_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %AI.Error{} = error -> error
      nested when is_map(nested) -> ai_error(nested)
      _other -> nil
    end)
  end

  defp ai_error(_error), do: nil
end
