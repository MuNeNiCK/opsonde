defmodule Opsonde.AI.ReqLLMTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.AI.ReqLLM, as: Adapter
  alias Opsonde.Providers
  alias Opsonde.Providers.AI

  import ExUnit.CaptureLog

  defmodule ProviderStub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn)

      request = %{
        path: conn.request_path,
        headers: conn.req_headers,
        body: body
      }

      mode =
        Agent.get_and_update(agent, fn state ->
          {mode, state} = next_mode(state)
          {mode, %{state | requests: [request | state.requests]}}
        end)

      respond(conn, request, check_decision(request.body, mode))
    end

    defp next_mode(%{mode: {:sequence, [mode | remaining]}} = state),
      do: {mode, %{state | mode: {:sequence, remaining}}}

    defp next_mode(%{mode: {:sequence, []}} = state),
      do: {{:raw_text, ""}, state}

    defp next_mode(state), do: {state.mode, state}

    defp respond(conn, request, {:sleep, milliseconds}) do
      Process.sleep(milliseconds)
      respond(conn, request, {:decision, handoff()})
    end

    defp respond(conn, request, {:decision, decision}) do
      decision = wire_decision(decision)

      cond do
        request.path == "/v1/messages" and
            String.contains?(request.body, "\"output_format\"") ->
          json(conn, anthropic_text_response(decision))

        request.path == "/v1/messages" ->
          json(conn, anthropic_response(decision))

        String.contains?(request.body, "\"tool_choice\"") ->
          json(conn, openai_tool_response(decision))

        true ->
          json(conn, openai_text_response(decision))
      end
    end

    defp respond(conn, _request, {:raw_text, text}) do
      json(conn, openai_text_response(text, false))
    end

    defp respond(conn, _request, {:raw_tool_arguments, arguments}) do
      json(conn, openai_tool_response(arguments, :raw))
    end

    defp respond(conn, _request, {:raw_text_length, text}) do
      response = openai_text_response(text, false)
      choices = Enum.map(response["choices"], &Map.put(&1, "finish_reason", "length"))
      json(conn, %{response | "choices" => choices})
    end

    defp respond(conn, _request, {:stream, decision}) do
      decision = wire_decision(decision)

      first = %{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "created" => 1,
        "model" => "test-model",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => Jason.encode!(decision)},
            "finish_reason" => nil
          }
        ]
      }

      last = %{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "created" => 1,
        "model" => "test-model",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
      }

      body =
        "data: #{Jason.encode!(first)}\n\n" <>
          "data: #{Jason.encode!(last)}\n\n" <>
          "data: [DONE]\n\n"

      conn
      |> put_resp_content_type("text/event-stream")
      |> send_resp(200, body)
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end

    defp openai_text_response(decision) do
      openai_text_response(decision, true)
    end

    defp openai_text_response(decision, encode?) do
      content = if encode?, do: Jason.encode!(decision), else: decision
      base_response(%{"role" => "assistant", "content" => content}, "stop")
    end

    defp openai_tool_response(decision), do: openai_tool_response(Jason.encode!(decision), :raw)

    defp openai_tool_response(arguments, :raw) do
      base_response(
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call_test",
              "type" => "function",
              "function" => %{
                "name" => "structured_output",
                "arguments" => arguments
              }
            }
          ]
        },
        "tool_calls"
      )
    end

    defp base_response(message, finish_reason) do
      %{
        "id" => "chatcmpl-test",
        "object" => "chat.completion",
        "created" => 1,
        "model" => "test-model",
        "choices" => [
          %{"index" => 0, "message" => message, "finish_reason" => finish_reason}
        ],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
      }
    end

    defp anthropic_text_response(decision) do
      %{
        "id" => "msg_test",
        "type" => "message",
        "role" => "assistant",
        "model" => "test-model",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => Jason.encode!(decision)}],
        "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
      }
    end

    defp anthropic_response(decision) do
      %{
        "id" => "msg-test",
        "type" => "message",
        "role" => "assistant",
        "model" => "test-model",
        "stop_reason" => "tool_use",
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_test",
            "name" => "structured_output",
            "input" => decision
          }
        ],
        "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
      }
    end

    defp check_decision(body, {:decision, _decision} = mode) do
      if String.contains?(body, "Return the required connection-check object"),
        do: {:decision, %{"status" => "ready"}},
        else: mode
    end

    defp check_decision(_body, mode), do: mode

    defp wire_decision(%{"type" => "proposal", "reason" => reason} = decision) do
      verification = decision["verification"]

      %{
        "reason" => reason,
        "intent" => %{
          "type" => "proposal",
          "action" => Map.take(decision, ~w(tool_id selectors parameters)),
          "evidence_ids" => decision["evidence_ids"],
          "affected_conditions" => decision["affected_conditions"],
          "verification" =>
            verification
            |> Map.take(~w(tool_id selectors parameters))
            |> Map.put("expected_result_json", Jason.encode!(verification["expected_result"]))
        }
      }
    end

    defp wire_decision(%{"type" => "observation", "reason" => reason} = decision) do
      %{
        "reason" => reason,
        "intent" => %{
          "type" => "observation",
          "tool_input" => Map.take(decision, ~w(tool_id selectors parameters))
        }
      }
    end

    defp wire_decision(%{"type" => _type, "reason" => reason} = decision) do
      %{
        "reason" => reason,
        "intent" => Map.drop(decision, ["reason"])
      }
    end

    defp wire_decision(decision), do: decision

    defp handoff, do: %{"type" => "handoff", "reason" => "probe", "required_input" => "human"}
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{mode: {:decision, handoff()}, requests: []} end})

    server =
      start_supervised!({Bandit, plug: {ProviderStub, agent}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{agent: agent, endpoint: "http://127.0.0.1:#{port}"}
  end

  test "one adapter handles OpenAI and Anthropic without putting credentials in prompts",
       context do
    providers = [
      {"openai", context.endpoint <> "/v1", %{"api_key" => "openai-secret"}},
      {"anthropic", context.endpoint, %{"api_key" => "anthropic-secret"}}
    ]

    for {provider, endpoint, credentials} <- providers do
      state = state!(provider, endpoint, credentials)

      assert {:ok,
              %AI.ResolverDecision{
                intent: %AI.Handoff{reason: "probe", required_input: "human"},
                usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
              }} = Adapter.resolve(state, resolver_request(), %{})
    end

    requests = requests(context.agent)

    assert Enum.map(requests, & &1.path) == [
             "/v1/chat/completions",
             "/v1/messages"
           ]

    refute Enum.any?(requests, &String.contains?(&1.body, "openai-secret"))
    refute Enum.any?(requests, &String.contains?(&1.body, "anthropic-secret"))
    assert Enum.all?(requests, &String.contains?(&1.body, "report_language"))
    assert Enum.all?(requests, &String.contains?(&1.body, "human-facing reason"))

    assert Enum.all?(requests, &String.contains?(&1.body, "one intent allowed"))
    assert Enum.all?(requests, &String.contains?(&1.body, "expected_result_json"))

    assert Enum.all?(requests, fn request ->
             String.contains?(request.body, "Recovery is a terminal intent") and
               String.contains?(request.body, "current observation") and
               String.contains?(request.body, "Do not propose an effect when") and
               String.contains?(request.body, "returned facts can directly establish") and
               String.contains?(request.body, "tool's verification_schema")
           end)

    for request <- requests do
      schema = output_schema(request)
      assert schema["additionalProperties"] == false
      assert MapSet.new(schema["required"]) == MapSet.new(Map.keys(schema["properties"]))
      assert schema["properties"]["reason"]["type"] == "string"

      if request.path != "/v1/messages" do
        assert schema["properties"]["reason"]["maxLength"] == 500
      end

      refute Map.has_key?(schema["properties"], "arguments_json")

      assert Enum.any?(schema["properties"]["intent"]["anyOf"], fn variant ->
               get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
             end)

      target_search =
        Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
          get_in(variant, ["properties", "type", "enum"]) == ["target_search"]
        end)

      handoff =
        Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
          get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
        end)

      if request.path != "/v1/messages" do
        assert get_in(target_search, ["properties", "query", "maxLength"]) == 200
        assert get_in(handoff, ["properties", "required_input", "maxLength"]) == 250
      end
    end
  end

  test "Resolver accepts a Target search query within the Target catalog limit", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    query = String.duplicate("a", 120)

    set_mode(
      context.agent,
      {:decision, %{"type" => "target_search", "reason" => "find", "query" => query}}
    )

    assert {:ok, %AI.ResolverDecision{intent: %AI.TargetSearch{query: ^query}}} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Resolver selects one of 22 mapped Targets by offered ref and carries its native citation",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    candidates =
      for index <- 1..22 do
        %AI.TargetCandidate{
          id: "target-#{index}",
          revision: 1,
          name: "node-#{index}",
          kind: "network_device",
          platform: "generic",
          facts: %{}
        }
      end

    conditions =
      for index <- 1..22 do
        %AI.Condition{
          id: "condition-#{index}",
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: "node-#{index}",
          subject_ref: %{"name" => "node-#{index}"},
          state: :firing,
          target_id: "target-#{index}",
          current_occurred_at_us: 1
        }
      end

    evidence =
      for index <- 1..22 do
        %AI.Evidence{
          id: "source-#{index}",
          kind: "signal_event",
          target_id: "target-#{index}",
          content: %{
            "current" => true,
            "condition_id" => "condition-#{index}",
            "condition_revision" => 1
          }
        }
      end

    request = %{
      resolver_request()
      | conditions: conditions,
        evidence: evidence,
        target_candidates: candidates
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate the independently signaled core node",
        "intent" => %{"type" => "target_selection", "candidate_ref" => "candidate-22"},
        "condition_groups" => [
          %{
            "condition_ids" => Enum.map(1..22, &"condition-#{&1}"),
            "assessment" => "unknown",
            "reason" => "The source events do not establish a common cause",
            "evidence_ids" => Enum.map(1..22, &"source-#{&1}")
          }
        ]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              condition_groups: [group],
              intent: %AI.TargetSelection{
                target_id: "target-22",
                target_revision: 1,
                evidence_ids: ["source-22"]
              }
            }} = Adapter.resolve(state, request, %{})

    assert length(group["evidence_ids"]) == 22
    assert [^group] = AI.normalize_condition_groups([group], conditions, evidence)

    [wire] = requests(context.agent)
    payload = user_payload(wire)
    assert length(payload["target_candidates"]) == 22

    assert Enum.find(payload["target_candidates"], &(&1["candidate_ref"] == "candidate-22"))[
             "supporting_evidence_ids"
           ] == ["source-22"]

    selection_schema =
      Enum.find(output_schema(wire)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["target_selection"]
      end)

    assert get_in(selection_schema, ["properties", "candidate_ref", "enum"]) ==
             Enum.map(1..22, &"candidate-#{&1}")

    refute Map.has_key?(selection_schema["properties"], "target_id")
    refute Map.has_key?(selection_schema["properties"], "evidence_ids")
  end

  test "Resolver object output carries optional bounded Condition hypotheses beside one intent",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      Enum.map(~w(condition-a condition-b), fn id ->
        %AI.Condition{
          id: id,
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: id,
          subject_ref: %{"name" => id},
          state: :firing,
          target_id: nil,
          current_occurred_at_us: 1
        }
      end)

    request = %{resolver_request() | conditions: conditions}

    group = %{
      "condition_ids" => ~w(condition-a condition-b),
      "assessment" => "unknown",
      "reason" => "The two alerts have no shared cause observation",
      "evidence_ids" => []
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Observe the affected devices",
        "intent" => %{"type" => "handoff", "required_input" => "Provide a safe observation"},
        "condition_groups" => [group]
      }
    })

    assert {:ok, %AI.ResolverDecision{condition_groups: [^group]}} =
             Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)
    assert output_schema(wire)["properties"]["condition_groups"]["maxItems"] == 32
    assert length(user_payload(wire)["conditions"]) == 2
  end

  test "Case split is a distinct Resolver intent with citations for both scopes", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      Enum.map(~w(condition-a condition-b), fn id ->
        %AI.Condition{
          id: id,
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: id,
          subject_ref: %{"name" => id},
          state: :firing,
          target_id: id,
          current_occurred_at_us: 1
        }
      end)

    evidence =
      Enum.map(conditions, fn condition ->
        %AI.Evidence{
          id: "observation-#{condition.id}",
          kind: "observation",
          target_id: condition.target_id,
          observed_at_us: 2,
          content: %{"status" => "applied", "target_id" => condition.target_id}
        }
      end)

    request = %{resolver_request() | conditions: conditions, evidence: evidence}

    source_only = %{
      request
      | evidence:
          Enum.map(conditions, fn condition ->
            %AI.Evidence{
              id: "source-#{condition.id}",
              kind: "signal_event",
              target_id: condition.target_id,
              observed_at_us: 2,
              content: %{"status" => "firing"}
            }
          end)
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate both",
        "intent" => %{"type" => "target_search", "query" => "nodes"}
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.TargetSearch{}}} =
             Adapter.resolve(state, source_only, %{})

    [source_wire] = requests(context.agent)
    refute "case_split" in user_payload(source_wire)["allowed_intents"]

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate both faults separately",
        "intent" => %{
          "type" => "case_split",
          "condition_ids" => ["condition-a"],
          "evidence_ids" => ["observation-condition-a"],
          "remaining_evidence_ids" => ["observation-condition-b"]
        }
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.CaseSplit{condition_ids: ["condition-a"]}}} =
             Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)
    assert "case_split" in user_payload(wire)["allowed_intents"]
  end

  test "ReqLLM object responses retain usage when the returned schema is invalid", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: "probe", required_input: "human"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)

    assert get_in(body, ["tool_choice", "function", "name"]) == "structured_output"
    assert get_in(body, ["tools", Access.at(0), "function", "name"]) == "structured_output"
    refute Map.has_key?(body, "response_format")
    assert output_schema(hd(requests(context.agent)))["additionalProperties"] == false

    set_mode(context.agent, {:decision, %{"status" => "ready"}})
    assert :ok = Adapter.check(state, %{})

    set_mode(context.agent, {:decision, %{"verdict" => "approved", "reason" => "bounded"}})

    assert {:ok, %AI.ReviewDecision{verdict: :approved, reason: "bounded"}} =
             Adapter.review(state, review_request(), %{})

    set_mode(context.agent, {:decision, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, "```json\n{\"status\":\"ready\"}\n```"})
    assert :ok = Adapter.check(state, %{})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "ReqLLM repaired object output is rejected with metered usage", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(
      context.agent,
      {:raw_tool_arguments,
       ~s({"reason":"probe","intent":{"type":"handoff","required_input":"human",},})}
    )

    assert {:error, :invalid_output, "AI provider output required repair",
            %AI.Usage{input_tokens: 7, output_tokens: 5}, "repair_required"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "plain output requests preserve timeout and cancellation", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 100
      })

    set_mode(context.agent, {:sleep, 500})
    assert {:error, :timeout, _message} = Adapter.resolve(state, resolver_request(), %{})

    cancellation =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    set_mode(context.agent, {:sleep, 500})

    cancelled? = fn ->
      Agent.get_and_update(cancellation, fn count -> {count >= 1, count + 1} end)
    end

    assert {:error, :cancelled, _message} =
             Adapter.resolve(state, resolver_request(), %{cancelled?: cancelled?})
  end

  test "object requests accept complete JSON text through the same schema and retain usage",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {:raw_text, ~s({"status":"ready"})})
    assert :ok = Adapter.check(state, %{})

    valid = %{"reason" => "確認", "intent" => %{"type" => "handoff", "required_input" => "確認"}}
    set_mode(context.agent, {:raw_text, Jason.encode!(valid)})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: "確認", required_input: "確認"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} =
             Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)
    assert get_in(body, ["tools", Access.at(0), "function", "name"]) == "structured_output"
    refute Map.has_key?(body, "response_format")

    set_mode(context.agent, {:raw_text, ~s({"verdict":"rejected","reason":"証拠不足"})})

    assert {:ok,
            %AI.ReviewDecision{
              verdict: :rejected,
              reason: "証拠不足",
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} =
             Adapter.review(state, review_request(), %{})

    set_mode(
      context.agent,
      {:raw_text,
       ~s({"reason":"確認","intent":{"type":"handoff","required_input":"確認"},"extra":true})}
    )

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(
      context.agent,
      {:raw_text, ~s({"reason":"bad","intent":{"type":"recovery","evidence_ids":["invented"]}})}
    )

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, ~s({"reason":)})

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "missing_structured_object"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, ~s(["not an object"])})

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "missing_structured_object"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text_length, Jason.encode!(valid)})

    assert {:error, :invalid_output, "AI provider JSON was truncated",
            %AI.Usage{finish_reason: "length"}, "truncated"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Reviewer receives the registered Case Target link as inventory context", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    request = review_request()

    guest = %AI.TargetCandidate{
      id: "guest-1",
      revision: 1,
      name: "linux-r8",
      kind: "host",
      platform: "linux",
      facts: %{}
    }

    host = %AI.TargetCandidate{
      id: request.proposal.target_id,
      revision: request.proposal.target_revision,
      name: "physical-host-r8",
      kind: "physical_host",
      platform: "bare_metal",
      facts: %{}
    }

    relation = %AI.TargetRelation{
      id: "hosted-by-1",
      revision: 2,
      source_target: guest,
      destination_target: host,
      kind: "hosted_by",
      attributes: %{}
    }

    request = %{request | initial_target_id: guest.id, target_relations: [relation]}
    set_mode(context.agent, {:decision, %{"verdict" => "approved", "reason" => "linked"}})

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} = Adapter.review(state, request, %{})

    [sent] = requests(context.agent)
    payload = reviewer_payload(sent)
    assert payload["case_initial_target_id"] == guest.id
    assert get_in(payload, ["registered_target_relations", Access.at(0), "id"]) == relation.id

    assert get_in(payload, ["registered_target_relations", Access.at(0), "source_target", "name"]) ==
             guest.name

    assert get_in(payload, [
             "registered_target_relations",
             Access.at(0),
             "destination_target",
             "id"
           ]) ==
             host.id
  end

  test "Reviewer receives a bounded schema correction after a paid invalid response", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      review_request()
      | retry_context: %{
          "category" => "invalid_output",
          "rejection_code" => "schema_validation"
        }
    }

    set_mode(context.agent, {:decision, %{"verdict" => "rejected", "reason" => "No proof"}})
    assert {:ok, %AI.ReviewDecision{verdict: :rejected}} = Adapter.review(state, request, %{})

    assert reviewer_payload(hd(requests(context.agent)))["retry_context"] ==
             request.retry_context
  end

  test "eligible Target traversal removes avoidable handoff from the Resolver contract",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    source = %AI.TargetCandidate{
      id: "target-1",
      revision: 1,
      name: "cluster",
      kind: "cluster",
      platform: "kubernetes",
      facts: %{}
    }

    destination = %AI.TargetCandidate{
      id: "target-2",
      revision: 1,
      name: "host",
      kind: "host",
      platform: "linux",
      facts: %{}
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 1,
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "observation",
            target_id: "target-1",
            content: %{"status" => "applied"}
          }
        ],
        target_relations: [
          %AI.TargetRelation{
            id: "relationship-1",
            revision: 1,
            source_target: source,
            destination_target: destination,
            kind: "hosted_by"
          }
        ],
        traversable_relation_ids: ["relationship-1"],
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1", "target-2"],
            allowed_evidence_kinds: ["observation"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "target_traversal",
        "reason" => "Inspect the related host",
        "relationship_id" => "relationship-1",
        "evidence_ids" => ["evidence-1"]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.TargetTraversal{relationship_id: "relationship-1"}
            }} = Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)
    variants = output_schema(provider_request)["properties"]["intent"]["anyOf"]
    payload = user_payload(provider_request)

    assert "target_traversal" in payload["allowed_intents"]

    assert payload["traversal_options"] == [
             %{
               "relationship_id" => "relationship-1",
               "relationship_kind" => "hosted_by",
               "direction" => "source_to_destination",
               "next_target_id" => "target-2",
               "next_target_name" => "host",
               "next_target_kind" => "host",
               "next_target_platform" => "linux"
             }
           ]

    refute "handoff" in payload["allowed_intents"]

    refute Enum.any?(variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
           end)

    set_mode(context.agent, {:decision, handoff()})
    unavailable = %{request | traversable_relation_ids: []}

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, unavailable, %{})

    [unavailable_request] = requests(context.agent)
    unavailable_payload = user_payload(unavailable_request)
    assert length(unavailable_payload["target_relations"]) == 1
    assert unavailable_payload["traversable_relation_ids"] == []
    assert unavailable_payload["traversal_options"] == []
    refute "target_traversal" in unavailable_payload["allowed_intents"]
  end

  test "effect schema exposes the observed precondition rather than the desired result",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    observation = %{observation_tool() | operation: "bmc.power.inspect"}

    observation_request = %AI.ProposalTool{
      proposal_tool()
      | id: "request-observation",
        request_kind: :observation,
        capability: "observe.power",
        operation: "bmc.power.inspect",
        input_schema: tool_input_schema(),
        evidence_requirements: []
    }

    effect = %AI.ProposalTool{
      proposal_tool()
      | operation: "bmc.power.on",
        input_schema:
          tool_input_schema(
            %{"observed_power_state" => %{"type" => "string", "enum" => ["on", "off"]}},
            ["observed_power_state"]
          ),
        evidence_requirements: [
          %Opsonde.Providers.Target.EvidenceRequirement{
            parameter: "observed_power_state",
            fact: "power_state",
            observation: "bmc.power.inspect"
          }
        ]
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        evidence: [
          %AI.Evidence{
            id: "observed-off",
            kind: "observation",
            target_id: "target-1",
            content: %{
              "tool_id" => observation_request.id,
              "facts" => %{"power_state" => "off"}
            }
          }
        ],
        observation_tools: [observation],
        proposal_tools: [observation_request, effect]
    }

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)

    effect_schema =
      provider_request
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.flat_map(&Map.get(&1, "anyOf", []))
      |> Enum.find(&Map.has_key?(Map.get(&1, "properties", %{}), "verification"))

    effect_action =
      effect_schema["properties"]["action"]["anyOf"]
      |> Enum.find(&(get_in(&1, ["properties", "tool_id", "enum"]) == [effect.id]))

    assert get_in(effect_action, [
             "properties",
             "parameters",
             "properties",
             "observed_power_state",
             "enum"
           ]) == ["off"]

    recovered = %AI.Condition{
      id: "power-condition",
      revision: 2,
      occurrence: 1,
      predicate: "Power is off",
      subject_key: "host-1",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["observed-off"]
    }

    request = %{
      request
      | alert_state: :recovered,
        conditions: [recovered],
        recovery_evidence_ids: ["observed-off"]
    }

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    recovered_schema =
      context.agent
      |> requests()
      |> List.last()
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.flat_map(&Map.get(&1, "anyOf", []))
      |> Enum.find(&Map.has_key?(Map.get(&1, "properties", %{}), "verification"))

    assert get_in(recovered_schema, [
             "properties",
             "affected_conditions",
             "items",
             "properties",
             "condition_id",
             "enum"
           ]) ==
             [recovered.id]
  end

  test "Resolver schema retries receive explicit bounded correction context", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      resolver_request()
      | retry_context: %{
          "category" => "invalid_output",
          "rejection_code" => "schema_validation",
          "rejection_path" => "/intent/type"
        }
    }

    assert :ok = AI.Validator.validate_request(:resolve, request)

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    body = Jason.decode!(wire_request.body)
    user_payload = user_payload(wire_request)

    assert user_payload["retry_context"] == request.retry_context

    assert Enum.any?(body["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "previous response was rejected") and
               String.contains?(message["content"], "Copy enum values exactly") and
               String.contains?(message["content"], "at most 250 Unicode codepoints")
           end)
  end

  test "Resolver receives a rejected recovery reason and guidance to seek new symptom evidence",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    objective =
      Jason.encode!(%{
        "case_title" => "Metrics unavailable",
        "turn_intent" => %{
          "source" => "recovery_review_rejected",
          "review_reason" => "A unit list does not show that the endpoint responds"
        }
      })

    request = %{resolver_request() | objective: objective}
    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    assert user_payload(wire_request)["objective"] == objective

    assert Enum.any?(Jason.decode!(wire_request.body)["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "Do not repeat a recovery claim") and
               String.contains?(message["content"], "direct observation")
           end)
  end

  test "schema rejection logs only bounded structural diagnostics", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      ~s({"reason":"test-secret","intent":{"type":"handoff","required_input":"test-secret"},"unexpected_private_key":"test-secret"})
    })

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation"} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "AI object schema mismatch"
    assert output =~ "intent=handoff"
    assert output =~ "root_extra=1"
    assert output =~ "action_shape=absent"
    refute output =~ "test-secret"
    refute output =~ "unexpected_private_key"
  end

  test "nested proposal diagnostics expose keys but no untrusted values", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      ~s({"reason":"Review the proposed action","intent":{"type":"proposal","action":{"tool_id":"test-secret","unexpected_private_key":"test-secret"},"evidence_ids":[],"affected_conditions":[]}})
    })

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation"} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "action_shape=unoffered:tool_id"
    refute output =~ "test-secret"
    refute output =~ "unexpected_private_key"
  end

  test "missing object logs its shape without response text", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    set_mode(context.agent, {:raw_text, "test-secret"})

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, "AI provider did not return a structured object",
                %AI.Usage{}, "missing_structured_object"} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "AI object missing"
    assert output =~ "raw_kind=text"
    assert output =~ "bytes=11"
    refute output =~ "test-secret"
  end

  test "a text object with a nested schema error reports the rejected location", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    set_mode(context.agent, {:raw_text, ~s({"reason":"inspect","intent":{"type":"handoff"}})})

    assert {:error, :invalid_output,
            "AI provider JSON does not match the requested schema at /intent/required_input",
            %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "a complete JSON code fence preserves the exact decision and its metered usage", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      "```json\n{\"reason\":\"確認\",\"intent\":{\"type\":\"handoff\",\"required_input\":\"確認\"}}\n```"
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{required_input: "確認"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {
      :raw_text,
      "```json\n{\"reason\":\"確認\",\"intent\":{\"type\":\"handoff\",\"required_input\":\"確認\"},\"extra\":true}\n```"
    })

    assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Resolver truncated retry requests one compact complete JSON decision", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      resolver_request()
      | retry_context: %{"category" => "invalid_output", "rejection_code" => "truncated"}
    }

    assert :ok = AI.Validator.validate_request(:resolve, request)
    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    body = Jason.decode!(wire_request.body)
    assert user_payload(wire_request)["retry_context"] == request.retry_context

    assert Enum.any?(body["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "rejection_code is truncated") and
               String.contains?(message["content"], "compact complete JSON object")
           end)
  end

  test "local validation rejects schema-invalid arguments without a second request", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "The monitoring source recovered",
        "intent" => %{"type" => "recovery", "evidence_ids" => ["stale-evidence"]}
      }
    })

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})

    assert [_request] = requests(context.agent)
  end

  test "schema rejection includes a bounded JSON path for the corrective Resolver turn",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :decision,
      %{"reason" => "Check this", "intent" => %{"type" => "handoff", "required_input" => 42}}
    })

    assert {:error, :invalid_output, message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} = Adapter.resolve(state, resolver_request(), %{})

    assert message =~ "AI provider JSON does not match the requested schema at /intent"
    assert [_request] = requests(context.agent)
  end

  test "buffered AI calls support the resolver queue concurrency", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 8_000
      })

    set_mode(context.agent, {:sleep, 5_500})

    results =
      1..10
      |> Task.async_stream(
        fn _index -> Adapter.resolve(state, resolver_request(), %{}) end,
        max_concurrency: 10,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}}} -> true
             _other -> false
           end)

    assert length(requests(context.agent)) == 10
  end

  test "multilingual output stays within the codepoint-bounded AI contract", context do
    reason = String.duplicate("界", 500)
    required_input = String.duplicate("界", 250)

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "handoff",
        "reason" => reason,
        "required_input" => required_input
      }
    })

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: ^reason, required_input: ^required_input}
            }} = Adapter.resolve(state, resolver_request(), %{})

    [resolver_request] = requests(context.agent)
    resolver_schema = output_schema(resolver_request)
    assert resolver_schema["properties"]["reason"]["maxLength"] == 500

    set_mode(context.agent, {
      :decision,
      %{"verdict" => "approved", "reason" => String.duplicate("界", 1_000)}
    })

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} =
             Adapter.review(state, review_request(), %{})

    [review_request] = requests(context.agent)
    assert output_schema(review_request)["properties"]["reason"]["maxLength"] == 1_000

    set_mode(context.agent, {
      :decision,
      %{"type" => "handoff", "reason" => String.duplicate("界", 501), "required_input" => "x"}
    })

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "recovered Condition assessments survive ReqLLM object decoding", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["direct-observation"]
    }

    observation = %AI.Evidence{
      id: "direct-observation",
      kind: "observation",
      target_id: "target-1",
      observed_at_us: 11,
      content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        conditions: [condition],
        evidence: [observation],
        recovery_evidence_ids: [observation.id]
    }

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "status" => "still_failing",
      "evidence_ids" => [observation.id],
      "reason" => "The endpoint still fails"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Continue investigating the endpoint",
        "intent" => %{
          "type" => "handoff",
          "required_input" => "Inspect the endpoint"
        },
        "condition_assessments" => [claim]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{},
              condition_assessments: [^claim]
            }} = Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    schema = output_schema(wire_request)
    assert get_in(schema, ["properties", "condition_assessments", "maxItems"]) == 1

    assert get_in(schema, [
             "properties",
             "condition_assessments",
             "items",
             "properties",
             "evidence_ids",
             "items",
             "enum"
           ]) ==
             [observation.id]

    assert get_in(schema, [
             "properties",
             "condition_assessments",
             "items",
             "properties",
             "evidence_ids",
             "minItems"
           ]) == 1

    assert get_in(user_payload(wire_request), [
             "conditions",
             Access.at(0),
             "recovery_evidence_ids"
           ]) ==
             [observation.id]
  end

  test "each recovered Condition assessment schema exposes only its own current citations",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      for number <- 1..2 do
        %AI.Condition{
          id: "condition-#{number}",
          revision: number,
          occurrence: 1,
          predicate: "Endpoint unavailable",
          subject_key: "endpoint-#{number}",
          subject_ref: %{},
          state: :recovered,
          target_id: "target-#{number}",
          current_occurred_at_us: 10,
          recovery_status: :ready_for_review,
          recovery_evidence_ids: ["current-#{number}"]
        }
      end

    evidence =
      for number <- 1..2 do
        %AI.Evidence{
          id: "current-#{number}",
          kind: "observation",
          target_id: "target-#{number}",
          observed_at_us: 11,
          content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
        }
      end

    request = %{
      resolver_request()
      | alert_state: :recovered,
        conditions: conditions,
        evidence: evidence,
        recovery_evidence_ids: Enum.map(evidence, & &1.id)
    }

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)

    variants =
      get_in(output_schema(wire_request), [
        "properties",
        "condition_assessments",
        "items",
        "anyOf"
      ])

    assert get_in(output_schema(wire_request), [
             "properties",
             "condition_assessments",
             "minItems"
           ]) == 0

    assert Enum.map(variants, fn variant ->
             properties = variant["properties"]

             {properties["condition_id"]["enum"], properties["revision"]["enum"],
              properties["evidence_ids"]["items"]["enum"]}
           end) == [
             {["condition-1"], [1], ["current-1"]},
             {["condition-2"], [2], ["current-2"]}
           ]

    partial = %{
      "condition_id" => "condition-1",
      "revision" => 1,
      "status" => "still_failing",
      "evidence_ids" => ["current-1"],
      "reason" => "The cited endpoint is still unavailable"
    }

    for assessments <- [[], [partial]] do
      set_mode(context.agent, {
        :decision,
        %{
          "reason" => "Continue the per-Condition investigation",
          "intent" => %{"type" => "handoff", "required_input" => "Observe the other endpoint"},
          "condition_assessments" => assessments
        }
      })

      assert {:ok, %AI.ResolverDecision{condition_assessments: ^assessments}} =
               Adapter.resolve(state, request, %{})
    end
  end

  test "recovered Condition without current citations can only be assessed unknown", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :needs_observation,
      recovery_evidence_ids: []
    }

    request = %{resolver_request() | alert_state: :recovered, conditions: [condition]}

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "status" => "unknown",
      "evidence_ids" => [],
      "reason" => "The endpoint has not been measured after the recovery event"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Request a current endpoint measurement",
        "intent" => %{"type" => "handoff", "required_input" => "Measure the endpoint"},
        "condition_assessments" => [claim]
      }
    })

    assert {:ok, %AI.ResolverDecision{condition_assessments: [^claim]}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    schema = output_schema(wire_request)
    assessment = get_in(schema, ["properties", "condition_assessments", "items", "properties"])

    assert assessment["status"]["enum"] == ["unknown"]
    assert assessment["evidence_ids"]["maxItems"] == 0
  end

  test "recovery schema exposes only eligible Target recovery Evidence", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    ordinary = %AI.Evidence{
      id: "observation-1",
      kind: "observation",
      content: %{"status" => "observed"}
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        evidence: [ordinary],
        disclosure: %{
          resolver_request().disclosure
          | allowed_evidence_kinds: ["observation"]
        }
    }

    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, request, %{})
    [ordinary_request] = requests(context.agent)
    ordinary_variants = output_schema(ordinary_request)["properties"]["intent"]["anyOf"]
    ordinary_payload = user_payload(ordinary_request)

    refute "recovery" in ordinary_payload["allowed_intents"]
    assert "target_search" in ordinary_payload["allowed_intents"]

    refute Enum.any?(ordinary_variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
           end)

    assert Enum.any?(ordinary_variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["target_search"]
           end)

    verified = %AI.Evidence{
      id: "verification-1",
      kind: "target_verification",
      content: %{"status" => "verified", "operation_id" => "operation-1"}
    }

    second_verified = %AI.Evidence{
      id: "verification-2",
      kind: "target_verification",
      content: %{"status" => "verified", "operation_id" => "operation-2"}
    }

    request = %{
      request
      | evidence: [ordinary, verified, second_verified],
        recovery_evidence_ids: ["verification-1", "verification-2"],
        disclosure: %{
          request.disclosure
          | allowed_evidence_kinds: ["observation", "target_verification"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh verification and monitoring agree",
        "evidence_ids" => ["verification-1", "verification-2", "verification-1"],
        "condition_claims" => []
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.RecoveryConclusion{
                evidence_ids: ["verification-1", "verification-2"]
              }
            }} = Adapter.resolve(state, request, %{})

    verified_request = requests(context.agent) |> List.last()
    assert "recovery" in user_payload(verified_request)["allowed_intents"]
    assert "handoff" in user_payload(verified_request)["allowed_intents"]

    recovery =
      Enum.find(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
      end)

    terminal_types =
      Enum.map(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"])
      end)

    assert ["recovery"] in terminal_types
    assert ["handoff"] in terminal_types

    assert get_in(recovery, ["properties", "evidence_ids", "items", "enum"]) == [
             "verification-1",
             "verification-2"
           ]

    observed = %AI.Evidence{
      id: "observation-recovered",
      kind: "observation",
      target_id: "target-1",
      content: %{
        "status" => "applied",
        "category" => "target_observed",
        "facts" => %{"ready" => true}
      }
    }

    observed_request = %{
      request
      | evidence: [ordinary, observed],
        recovery_evidence_ids: ["observation-recovered"],
        selected_target_id: "target-1",
        selected_target_revision: 1
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh Target observation confirms recovery",
        "evidence_ids" => ["observation-recovered"],
        "condition_claims" => []
      }
    })

    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, observed_request, %{})

    recovery =
      requests(context.agent)
      |> List.last()
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
      end)

    assert get_in(recovery, ["properties", "evidence_ids", "items", "enum"]) == [
             "observation-recovered"
           ]
  end

  test "manual recovery schema binds original symptom to current cited fact keys", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    symptom_id = String.duplicate("a", 64)

    observed = %AI.Evidence{
      id: "observation-current",
      kind: "observation",
      target_id: "target-1",
      content: %{"status" => "applied", "facts" => %{"service_state" => "active"}}
    }

    request = %{
      resolver_request()
      | alert_state: :not_applicable,
        case_symptom: %{
          id: symptom_id,
          text: "The API service is unavailable",
          desired_outcome: "The API service responds to health checks"
        },
        evidence: [observed],
        recovery_evidence_ids: [observed.id],
        disclosure: %{
          resolver_request().disclosure
          | allowed_evidence_kinds: ["observation"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "The API service is active",
        "evidence_ids" => [observed.id],
        "condition_claims" => [],
        "desired_outcome_claims" => [
          %{
            "symptom_id" => symptom_id,
            "evidence_id" => observed.id,
            "fact_keys" => ["service_state"],
            "reason" => "The observed state is active"
          }
        ]
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.RecoveryConclusion{} = conclusion}} =
             Adapter.resolve(state, request, %{})

    assert [%{"symptom_id" => ^symptom_id}] = conclusion.desired_outcome_claims
    [wire_request] = requests(context.agent)

    assert user_payload(wire_request)["case_symptom"] == %{
             "id" => symptom_id,
             "text" => "The API service is unavailable",
             "desired_outcome" => "The API service responds to health checks"
           }

    recovery =
      wire_request
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["recovery"]))

    claim = get_in(recovery, ["properties", "desired_outcome_claims"])
    assert claim["minItems"] == 1
    assert get_in(claim, ["items", "properties", "symptom_id", "enum"]) == [symptom_id]

    assert get_in(claim, ["items", "properties", "fact_keys", "items", "enum"]) == [
             "service_state"
           ]
  end

  test "streamed and buffered responses produce the same decision", context do
    buffered = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    streamed =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "stream" => true
      })

    assert {:ok, buffered_decision} = Adapter.resolve(buffered, resolver_request(), %{})
    set_mode(context.agent, {:stream, handoff()})
    assert {:ok, streamed_decision} = Adapter.resolve(streamed, resolver_request(), %{})
    assert streamed_decision.intent == buffered_decision.intent
    assert streamed_decision.usage.input_tokens == buffered_decision.usage.input_tokens
    assert streamed_decision.usage.output_tokens == buffered_decision.usage.output_tokens

    set_mode(context.agent, {:stream, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(streamed, resolver_request(), %{})
  end

  test "review uses an isolated prompt without resolver sessions or Target tools", context do
    set_mode(context.agent, {:decision, %{"verdict" => "approved", "reason" => "bounded"}})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ReviewDecision{
              verdict: :approved,
              reason: "bounded",
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.review(state, review_request(), %{})

    [request] = requests(context.agent)
    assert request.body =~ "proposal-tool"
    assert request.body =~ "authoritative-request-value"
    assert request.body =~ "recent_case_evidence"
    assert request.body =~ "Check recent Case evidence for facts"
    assert request.body =~ "may be truncated"
    assert request.body =~ "validated_contract"
    assert request.body =~ "Do not infer an Access Method's capability set from cited evidence"
    assert request.body =~ "Write the human-facing reason in the report_language"

    assert %{
             "report_language" => "ja",
             "validated_contract" => %{
               "access_method_current_and_authorized" => true,
               "input_matches_provider_schema" => true,
               "proposal_matches_disclosed_provider_tool" => true,
               "target_revision_current" => true
             }
           } = reviewer_payload(request)

    refute request.body =~ "resolver-private-session"
    refute request.body =~ "observation_tools"
    refute request.body =~ "proposal_tools"
  end

  test "manual Recovery Reviewer must assess the original symptom and exact citations", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    symptom_id = String.duplicate("c", 64)

    evidence = %AI.Evidence{
      id: "observation-current",
      kind: "observation",
      target_id: "target-1",
      content: %{"facts" => %{"service_state" => "active"}}
    }

    claim = %{
      "symptom_id" => symptom_id,
      "evidence_id" => evidence.id,
      "fact_keys" => ["service_state"],
      "reason" => "The service is active"
    }

    request = %AI.RecoveryReviewRequest{
      provider_revision: 1,
      session_id: "reviewer:turn-1",
      resolver_session_id: "resolver:run-1",
      case_id: "case-1",
      objective: "Restore the API service",
      report_language: :en,
      conditions: [],
      case_symptom: %{
        id: symptom_id,
        text: "The API service is unavailable",
        desired_outcome: "The API service responds to health checks"
      },
      source_evidence: [],
      cited_evidence: [evidence],
      conclusion: %AI.RecoveryConclusion{
        reason: "The service is active",
        evidence_ids: [evidence.id],
        desired_outcome_claims: [claim]
      },
      budget: budget()
    }

    assessment = %{
      "symptom_id" => symptom_id,
      "desired_outcome" => "The API service responds to health checks",
      "evidence_ids" => [evidence.id],
      "status" => "supported",
      "reason" => "The observed service state satisfies the desired outcome"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "verdict" => "approved",
        "reason" => "The current service observation supports recovery",
        "desired_outcome_assessment" => assessment
      }
    })

    assert {:ok, %AI.ReviewDecision{desired_outcome_assessment: ^assessment} = decision} =
             Adapter.review_recovery(state, request, %{})

    assert :ok = AI.Validator.validate_decision(:review_recovery, decision, request)
    [wire] = requests(context.agent)

    assert reviewer_payload(wire)["case_symptom"] == %{
             "id" => symptom_id,
             "text" => "The API service is unavailable",
             "desired_outcome" => "The API service responds to health checks"
           }

    schema = output_schema(wire)
    assert "desired_outcome_assessment" in schema["required"]

    assert get_in(schema, [
             "properties",
             "desired_outcome_assessment",
             "properties",
             "symptom_id",
             "enum"
           ]) ==
             [symptom_id]

    assert get_in(schema, [
             "properties",
             "desired_outcome_assessment",
             "properties",
             "desired_outcome",
             "enum"
           ]) ==
             ["The API service responds to health checks"]

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{assessment | "status" => "unsupported"}
               },
               request
             )

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{assessment | "evidence_ids" => ["other"]}
               },
               request
             )

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{
                     assessment
                     | "desired_outcome" => "The API service is unavailable"
                   }
               },
               request
             )
  end

  test "Reviewer sees monitor state and current observations without a recovery verdict",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "service inactive",
      subject_key: "api.service",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["evidence-1"]
    }

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}

    request = %{
      review_request()
      | conditions: [condition],
        proposal: %{proposal() | affected_conditions: [claim]}
    }

    set_mode(
      context.agent,
      {:decision, %{"verdict" => "approved", "reason" => "Measured inactive"}}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} = Adapter.review(state, request, %{})

    [wire_request] = requests(context.agent)
    [visible] = reviewer_payload(wire_request)["current_conditions"]

    assert visible["monitor_state"] == "recovered"
    assert visible["current_target_observation_ids"] == ["evidence-1"]
    refute Map.has_key?(visible, "recovery_status")
    refute Map.has_key?(visible, "recovery_evidence_ids")
    refute Map.has_key?(visible, "state")
  end

  test "tool choices are rebound to the exact registered Target and Access Method", context do
    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1"],
            allowed_evidence_kinds: ["observation"]
        },
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "observation",
            target_id: "target-1",
            content: %{"status" => "stopped"}
          },
          %AI.Evidence{
            id: "source-evidence-1",
            kind: "signal_event",
            target_id: nil,
            content: %{"current" => true, "state" => "firing"}
          },
          %AI.Evidence{
            id: "verification-1",
            kind: "target_verification",
            target_id: "target-1",
            content: %{"status" => "verified"}
          }
        ],
        observation_tools: [observation_tool()],
        proposal_tools: [proposal_tool()]
    }

    decision = %{
      "type" => "proposal",
      "reason" => "Restore availability",
      "tool_id" => "proposal-tool",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"grace_seconds" => 5},
      "evidence_ids" => ["evidence-1"],
      "affected_conditions" => [],
      "expected_result" => %{"status" => "running"},
      "verification" => %{
        "tool_id" => "observe-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{},
        "expected_result" => %{"status" => "running"}
      }
    }

    set_mode(context.agent, {:decision, decision})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Proposal{
                tool_id: "proposal-tool",
                target_id: "target-1",
                target_revision: 4,
                access_method_id: "access-1",
                access_method_revision: 3,
                request_kind: :effect,
                capability: "effect.command",
                operation: "service.restart",
                expected_result: %{"status" => "running"},
                verification_intent: %AI.VerificationIntent{
                  tool_id: "observe-tool",
                  expected_result: %{"status" => "running"}
                }
              }
            }} = Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)
    assert String.contains?(provider_request.body, "output_schema")
    assert String.contains?(provider_request.body, "verification_schema")
    assert user_payload(provider_request)["effect_evidence_ids"] == ["evidence-1"]
    schema = output_schema(provider_request)

    proposal_variant =
      Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["proposal"]
      end)

    refute Map.has_key?(proposal_variant["properties"], "expected_result_json")

    assert get_in(proposal_variant, ["properties", "evidence_ids", "items", "enum"]) == [
             "evidence-1"
           ]

    [action_schema] = get_in(proposal_variant, ["properties", "action", "anyOf"])
    assert get_in(action_schema, ["properties", "tool_id", "enum"]) == ["proposal-tool"]

    assert action_schema["properties"]["selectors"] ==
             tool_input_schema()["properties"]["selectors"]

    assert action_schema["properties"]["parameters"] ==
             tool_input_schema(
               %{
                 "grace_seconds" => %{
                   "type" => "integer",
                   "minimum" => 0,
                   "maximum" => 30
                 }
               },
               ["grace_seconds"]
             )["properties"]["parameters"]

    verification_schemas =
      get_in(proposal_variant, ["properties", "verification", "anyOf"])

    assert Enum.any?(verification_schemas, fn variant ->
             get_in(variant, ["properties", "tool_id", "enum"]) == ["observe-tool"] and
               Map.has_key?(variant["properties"], "expected_result_json")
           end)

    refute Enum.any?(verification_schemas, fn variant ->
             get_in(variant, ["properties", "tool_id", "enum"]) == ["proposal-tool"]
           end)

    invalid_citation = %{
      "reason" => "Restore availability",
      "intent" => %{
        "type" => "proposal",
        "action" => Map.take(decision, ~w(tool_id selectors parameters)),
        "evidence_ids" => ["source-evidence-1"],
        "affected_conditions" => [],
        "verification" =>
          decision["verification"]
          |> Map.take(~w(tool_id selectors parameters))
          |> Map.put(
            "expected_result_json",
            Jason.encode!(decision["verification"]["expected_result"])
          )
      }
    }

    set_mode(context.agent, {:raw_text, Jason.encode!(invalid_citation)})

    assert {:error, :invalid_output,
            "AI provider JSON does not match the requested schema at /intent/evidence_ids",
            %AI.Usage{}, "schema_validation"} = Adapter.resolve(state, request, %{})

    set_mode(context.agent, {:decision, %{decision | "tool_id" => "invented-tool"}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, request, %{})

    set_mode(context.agent, {:decision, Map.delete(decision, "tool_id")})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, request, %{})

    malformed = put_in(decision, ["verification", "expected_result"], "not-an-object")
    set_mode(context.agent, {:decision, malformed})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "decision_validation"} =
             Adapter.resolve(state, request, %{})
  end

  test "observation proposals may name current investigative Conditions without effect authority",
       context do
    condition = %AI.Condition{
      id: "condition-1",
      revision: 3,
      occurrence: 1,
      predicate: "service unavailable",
      subject_key: "service",
      subject_ref: %{},
      state: :firing,
      target_id: "target-1",
      current_occurred_at_us: 1
    }

    tool = %{
      proposal_tool()
      | request_kind: :observation,
        capability: "observe.command",
        operation: "service.inspect"
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        conditions: [condition],
        disclosure: %{disclosure() | allowed_target_ids: ["target-1"]},
        proposal_tools: [tool]
    }

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}

    set_mode(context.agent, {
      :raw_text,
      Jason.encode!(%{
        "reason" => "Inspect this service",
        "intent" => %{
          "type" => "proposal",
          "action" => %{
            "tool_id" => tool.id,
            "selectors" => %{"service" => "api"},
            "parameters" => %{"grace_seconds" => 5}
          },
          "evidence_ids" => [],
          "affected_conditions" => [claim]
        }
      })
    })

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Proposal{
                request_kind: :observation,
                affected_conditions: [^claim],
                verification_intent: nil
              }
            }} = Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)

    proposal_schema =
      output_schema(wire)["properties"]["intent"]["anyOf"]
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["proposal"]))

    assert proposal_schema["properties"]["affected_conditions"]["minItems"] == 0
  end

  test "effect proposal carries a cited related Condition and exact relationship revision",
       context do
    effect_target = %AI.TargetCandidate{
      id: "target-1",
      revision: 4,
      name: "controller",
      kind: "host",
      platform: "generic",
      facts: %{}
    }

    condition_target = %AI.TargetCandidate{
      id: "target-2",
      revision: 2,
      name: "guest",
      kind: "host",
      platform: "linux",
      facts: %{}
    }

    condition = %AI.Condition{
      id: "condition-2",
      revision: 3,
      occurrence: 1,
      predicate: "service unavailable",
      subject_key: "service",
      subject_ref: %{},
      state: :recovered,
      target_id: condition_target.id,
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["symptom-observation"]
    }

    relation = %AI.TargetRelation{
      id: "relation-1",
      revision: 7,
      source_target: condition_target,
      destination_target: effect_target,
      kind: "managed_by"
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        selected_target_id: effect_target.id,
        selected_target_revision: effect_target.revision,
        conditions: [condition],
        recovery_evidence_ids: ["symptom-observation"],
        disclosure: %{
          disclosure()
          | allowed_target_ids: [effect_target.id, condition_target.id],
            allowed_evidence_kinds: ["observation"]
        },
        evidence: [
          %AI.Evidence{
            id: "effect-observation",
            kind: "observation",
            target_id: effect_target.id,
            observed_at_us: 12,
            content: %{"status" => "applied", "facts" => %{"power_state" => "off"}}
          },
          %AI.Evidence{
            id: "symptom-observation",
            kind: "observation",
            target_id: condition_target.id,
            observed_at_us: 13,
            content: %{"status" => "applied", "facts" => %{"service" => "inactive"}}
          }
        ],
        target_relations: [relation],
        observation_tools: [observation_tool()],
        proposal_tools: [proposal_tool()]
    }

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    result = %{
      "reason" => "The guest remains unavailable while its controller reports power off",
      "intent" => %{
        "type" => "proposal",
        "action" => %{
          "tool_id" => "proposal-tool",
          "selectors" => %{"service" => "api"},
          "parameters" => %{"grace_seconds" => 5}
        },
        "evidence_ids" => ["effect-observation", "symptom-observation"],
        "affected_conditions" => [claim],
        "verification" => %{
          "tool_id" => "observe-tool",
          "selectors" => %{"service" => "api"},
          "parameters" => %{},
          "expected_result_json" => Jason.encode!(%{"status" => "running"})
        }
      }
    }

    assert AI.proposal_evidence_ids(request) == [
             "effect-observation",
             "symptom-observation"
           ]

    set_mode(context.agent, {:raw_text, Jason.encode!(result)})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{intent: %AI.Proposal{affected_conditions: [^claim]}} =
              accepted} = Adapter.resolve(state, request, %{})

    assert :ok = AI.Validator.validate_decision(:resolve, accepted, request)

    for ids <- [["effect-observation"], ["symptom-observation"]] do
      incomplete = %{accepted | intent: %{accepted.intent | evidence_ids: ids}}

      assert {:error, %AI.Error{category: :invalid_output}} =
               AI.Validator.validate_decision(:resolve, incomplete, request)
    end

    [wire] = requests(context.agent)
    assert user_payload(wire)["effect_evidence_ids"] == result["intent"]["evidence_ids"]

    proposal_schema =
      output_schema(wire)["properties"]["intent"]["anyOf"]
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["proposal"]))

    assert get_in(proposal_schema, [
             "properties",
             "affected_conditions",
             "items",
             "properties",
             "relationship_id",
             "enum"
           ]) ==
             [relation.id]

    changed =
      put_in(result, ["intent", "affected_conditions"], [
        %{claim | "relationship_revision" => relation.revision + 1}
      ])

    set_mode(context.agent, {:raw_text, Jason.encode!(changed)})

    assert {:ok, %AI.ResolverDecision{} = stale_decision} =
             Adapter.resolve(state, request, %{})

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(:resolve, stale_decision, request)

    failed_request = %{
      request
      | conditions: [
          %{
            condition
            | recovery_status: :needs_observation,
              recovery_evidence_ids: [],
              failed_observation_ids: ["symptom-observation"]
          }
        ],
        recovery_evidence_ids: [],
        evidence:
          Enum.map(request.evidence, fn
            %{id: "symptom-observation"} = item ->
              %{item | content: %{"status" => "failed", "category" => "observation_failed"}}

            item ->
              item
          end)
    }

    set_mode(context.agent, {:raw_text, Jason.encode!(result)})

    assert {:ok, %AI.ResolverDecision{} = failed_observation_decision} =
             Adapter.resolve(state, failed_request, %{})

    assert :ok =
             AI.Validator.validate_decision(:resolve, failed_observation_decision, failed_request)

    assert AI.recovery_evidence_ids(failed_request) == []
  end

  test "malformed output, deadline, and caller cancellation stay typed", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 500
      })

    set_mode(context.agent, {:decision, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:sleep, 1_000})
    assert {:error, :timeout, _message} = Adapter.resolve(state, resolver_request(), %{})

    cancellation =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: make_ref()))

    set_mode(context.agent, {:sleep, 1_000})

    cancelled? = fn ->
      Agent.get_and_update(cancellation, fn count -> {count >= 1, count + 1} end)
    end

    assert {:error, :cancelled, _message} =
             Adapter.resolve(state, resolver_request(), %{cancelled?: cancelled?})
  end

  test "configuration rejects unknown fields and invalid provider credentials", context do
    base = %{
      "provider" => "openai",
      "model" => "test-model",
      "endpoint" => context.endpoint <> "/v1"
    }

    credentials = %{"api_key" => "secret"}

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "typo", true), credentials)

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "output_mode", "structured"), credentials)

    assert {:error, :invalid_configuration} =
             Adapter.build(base, %{})

    assert {:error, :invalid_configuration} =
             Adapter.build(%{base | "provider" => "unknown"}, %{"api_key" => "secret"})

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "reasoning_effort", "unbounded"), credentials)

    assert {:ok, %{reasoning_effort: :low}} =
             Adapter.build(Map.put(base, "reasoning_effort", "low"), credentials)
  end

  test "the public service catalog includes every installed object provider and excludes other operations" do
    services = Adapter.services()
    registered = ReqLLM.Providers.list() |> Enum.map(&Atom.to_string/1)

    assert Enum.map(services, & &1.id) ==
             Enum.reject(registered, &(&1 in ~w(cohere elevenlabs typesafe)))

    assert Enum.find(services, &(&1.id == "ollama")).auth == "none"
    assert Enum.find(services, &(&1.id == "google_vertex")).auth == "service_account_json"
    assert Enum.find(services, &(&1.id == "openai_codex")).auth == "oauth_access_token"
  end

  test "every catalog service can build a model connection using its supported credential profile" do
    for service <- Adapter.services() do
      configuration =
        %{"provider" => service.id, "model" => "opsonde-test-model"}
        |> Map.merge(
          case service.id do
            "azure" -> %{"endpoint" => "https://example.openai.azure.com"}
            "amazon_bedrock" -> %{"region" => "us-east-1"}
            "google_vertex" -> %{"project_id" => "opsonde-test"}
            "openai_codex" -> %{"chatgpt_account_id" => "test-account"}
            _ -> %{}
          end
        )

      credentials =
        case service.auth do
          "none" ->
            %{}

          "optional_api_key" ->
            %{}

          "service_account_json" ->
            %{
              "service_account_json" =>
                ~s({"client_email":"test@example.com","private_key":"test"})
            }

          "oauth_access_token" ->
            %{"access_token" => "test-token"}

          "api_key" ->
            %{"api_key" => "test-key"}
        end

      assert {:ok, state} = Adapter.build(configuration, credentials), service.id
      assert state.provider == String.to_existing_atom(service.id)
      assert state.model.provider == state.provider
    end

    assert {:error, :invalid_configuration} =
             Adapter.build(%{"provider" => "ollama", "model" => "llama3"}, %{
               "api_key" => "ignored"
             })

    assert {:error, :invalid_configuration} =
             Adapter.build(%{"provider" => "google_vertex", "model" => "gemini"}, %{})
  end

  test "unsupported Azure model family is reported as capability, not network failure" do
    assert {:ok, state} =
             Adapter.build(
               %{
                 "provider" => "azure",
                 "model" => "model-outside-azure-families",
                 "endpoint" => "https://example.openai.azure.com"
               },
               %{"api_key" => "test-key"}
             )

    assert {:error, :capability, "AI model family is not supported by this service"} =
             Adapter.check(state, %{})
  end

  test "OpenRouter catalog structured-output metadata selects its schema path without tools" do
    assert {:ok, state} =
             Adapter.build(
               %{"provider" => "openrouter", "model" => "gryphe/mythomax-l2-13b"},
               %{"api_key" => "test-key"}
             )

    assert state.model.extra["structured_output"] == true
    assert state.model.capabilities == nil
    assert state.provider_options[:openrouter_structured_output_mode] == :json_schema
  end

  test "OpenRouter models without tool metadata send a schema request through Resolver",
       context do
    state =
      state!("openrouter", context.endpoint <> "/v1", %{"api_key" => "test-key"}, %{
        "model" => "gryphe/mythomax-l2-13b"
      })

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)
    assert body["response_format"]["type"] == "json_schema"
    refute Map.has_key?(body, "tools")
  end

  test "known models retain LLMDB metadata while unknown model IDs remain usable", context do
    known =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "model" => "gpt-4o-mini"
      })

    unknown =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "model" => "model-released-after-opsonde"
      })

    assert known.model.id == "gpt-4o-mini"
    assert known.model.capabilities != nil
    assert known.model.execution != nil

    assert unknown.model.id == "model-released-after-opsonde"
    assert unknown.model.provider == :openai
    assert unknown.model.capabilities == nil
    assert unknown.model.execution == nil
  end

  test "reasoning effort is passed through the provider-neutral adapter", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "reasoning_effort" => "high"
      })

    set_mode(context.agent, {:decision, handoff()})
    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    assert Jason.decode!(request.body)["reasoning_effort"] == "high"
  end

  test "hosted Provider lifecycles and public AI actions invoke the registered adapter",
       context do
    admin =
      Accounts.bootstrap!(
        "req-llm-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    for {provider_name, endpoint} <- [
          {"openai", context.endpoint <> "/v1"},
          {"anthropic", context.endpoint},
          {"ollama", context.endpoint <> "/v1"}
        ] do
      set_mode(context.agent, {:decision, handoff()})

      provider =
        Providers.create_provider!(
          "#{provider_name}-ai",
          :ai,
          Adapter.type(),
          %{
            "provider" => provider_name,
            "model" => "test-model",
            "endpoint" => endpoint
          },
          if(provider_name == "ollama", do: %{}, else: %{"api_key" => "provider-secret"}),
          actor: admin
        )

      provider = Providers.check_provider!(provider.id, 1, %{}, actor: admin)

      assert provider.check_status == :passed,
             inspect({provider_name, provider.check_category, provider.check_message})

      provider = Providers.enable_provider!(provider, 1, actor: admin)

      assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{reason: "probe"}}} =
               Providers.ai_resolve(provider.id, resolver_request(), %{}, actor: admin)

      set_mode(context.agent, {:decision, %{"verdict" => "approved", "reason" => "bounded"}})

      assert {:ok, %AI.ReviewDecision{verdict: :approved, reason: "bounded"}} =
               Providers.ai_review(provider.id, review_request(), %{}, actor: admin)

      set_mode(context.agent, {:decision, %{"unexpected" => true}})

      assert {:error, error} =
               Providers.ai_resolve(provider.id, resolver_request(), %{}, actor: admin)

      assert %AI.Error{
               category: :invalid_output,
               usage: %AI.Usage{input_tokens: 7, output_tokens: 5},
               dispatched?: true
             } = ai_error(error)
    end
  end

  defp ai_error(%AI.Error{} = error), do: error
  defp ai_error(%{errors: errors}), do: Enum.find_value(errors, &ai_error/1)
  defp ai_error(_error), do: nil

  defp state!(provider, endpoint, credentials, extra_configuration \\ %{}) do
    configuration =
      Map.merge(
        %{
          "provider" => provider,
          "model" => "test-model",
          "endpoint" => endpoint
        },
        extra_configuration
      )

    assert {:ok, state} = Adapter.build(configuration, credentials)
    state
  end

  defp resolver_request do
    %AI.ResolverRequest{
      provider_revision: 1,
      session_id: "resolver-session",
      case_id: "case-1",
      turn: 1,
      objective: "Restore service health",
      alert_state: :firing,
      report_language: :en,
      disclosure: disclosure(),
      budget: budget(),
      evidence: [],
      target_candidates: [],
      observation_results: [],
      target_relations: [],
      observation_tools: [],
      proposal_tools: []
    }
  end

  defp review_request do
    %AI.ReviewRequest{
      provider_revision: 1,
      session_id: "review-session",
      resolver_session_id: "resolver-private-session",
      case_id: "case-1",
      objective: "Restore service health",
      report_language: :ja,
      policy_summary: "No destructive action",
      proposal: proposal(),
      source_evidence: [
        %AI.Evidence{
          id: "source-evidence-1",
          kind: "signal_event",
          target_id: nil,
          content: %{"requirement" => "authoritative-request-value"}
        }
      ],
      cited_evidence: [
        %AI.Evidence{
          id: "evidence-1",
          kind: "observation",
          target_id: "target-1",
          content: %{"status" => "stopped"}
        }
      ],
      context_evidence: [
        %AI.Evidence{
          id: "independent-responsive-guest",
          kind: "observation",
          target_id: "target-1",
          observed_at_us: 1_000_000,
          content: %{"facts" => %{"machine_id" => "responsive-guest"}}
        }
      ],
      budget: budget()
    }
  end

  defp reviewer_payload(request) do
    request.body
    |> Jason.decode!()
    |> get_in(["messages", Access.at(1), "content"])
    |> Jason.decode!()
  end

  defp proposal do
    %AI.Proposal{
      tool_id: "proposal-tool",
      target_id: "target-1",
      target_revision: 1,
      access_method_id: "access-1",
      access_method_revision: 1,
      request_kind: :effect,
      capability: "effect.command",
      operation: "service.restart",
      selectors: %{"service" => "api"},
      parameters: %{},
      reason: "Restore availability",
      evidence_ids: ["evidence-1"],
      expected_result: %{"status" => "running"},
      verification_intent: %AI.VerificationIntent{
        tool_id: "observe-tool",
        selectors: %{"service" => "api"},
        parameters: %{},
        expected_result: %{"status" => "running"}
      }
    }
  end

  defp observation_tool do
    %AI.ObservationTool{
      id: "observe-tool",
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-1",
      access_method_revision: 3,
      provider_id: "target-provider",
      provider_revision: 2,
      capability: "observe.command",
      operation: "service.inspect",
      description: "Inspect one service",
      input_schema: tool_input_schema(),
      output_schema: verification_schema(),
      verification_schema: verification_schema()
    }
  end

  defp proposal_tool do
    %AI.ProposalTool{
      id: "proposal-tool",
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-1",
      access_method_revision: 3,
      provider_id: "target-provider",
      provider_revision: 2,
      request_kind: :effect,
      capability: "effect.command",
      operation: "service.restart",
      description: "Restart one service",
      input_schema:
        tool_input_schema(
          %{
            "grace_seconds" => %{"type" => "integer", "minimum" => 0, "maximum" => 30}
          },
          ["grace_seconds"]
        )
    }
  end

  defp disclosure do
    %AI.Disclosure{
      allowed_target_ids: [],
      allowed_evidence_kinds: [],
      max_items: 20,
      max_bytes: 20_000
    }
  end

  defp budget do
    %AI.Budget{
      remaining_turns: 3,
      remaining_tokens: 2_000,
      remaining_target_requests: 3,
      remaining_effects: 1,
      remaining_related_targets: 2
    }
  end

  defp handoff,
    do: %{"type" => "handoff", "reason" => "probe", "required_input" => "human"}

  defp tool_input_schema(parameter_properties \\ %{}, parameter_required \\ []) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => %{"service" => %{"type" => "string", "minLength" => 1}},
          "required" => ["service"],
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameter_properties,
          "required" => parameter_required,
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp verification_schema,
    do: %{
      "type" => "object",
      "properties" => %{"status" => %{"type" => "string"}},
      "minProperties" => 1,
      "additionalProperties" => false
    }

  defp output_schema(request) do
    body = Jason.decode!(request.body)

    case request.path do
      "/v1/messages" ->
        get_in(body, ["output_format", "schema"]) ||
          get_in(body, ["tools", Access.at(0), "input_schema"])

      _other ->
        get_in(body, ["tools", Access.at(0), "function", "parameters"])
    end
  end

  defp set_mode(agent, mode),
    do: Agent.update(agent, &%{&1 | mode: mode, requests: []})

  defp requests(agent),
    do: Agent.get(agent, &Enum.reverse(&1.requests))

  defp user_payload(request) do
    request.body
    |> Jason.decode!()
    |> Map.fetch!("messages")
    |> Enum.find(fn message ->
      message["role"] == "user" and
        match?({:ok, %{"case_id" => _}}, Jason.decode(message["content"]))
    end)
    |> Map.fetch!("content")
    |> Jason.decode!()
  end
end
