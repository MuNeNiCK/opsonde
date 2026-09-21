defmodule Opsonde.AI.ReqLLMTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.AI.ReqLLM, as: Adapter
  alias Opsonde.Providers
  alias Opsonde.Providers.AI

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
          {state.mode, %{state | requests: [request | state.requests]}}
        end)

      respond(conn, request, check_decision(request.body, mode))
    end

    defp respond(conn, _request, {:sleep, milliseconds}) do
      Process.sleep(milliseconds)
      json(conn, openai_text_response(wire_decision(handoff())))
    end

    defp respond(conn, request, {:decision, decision}) do
      decision = wire_decision(decision)

      cond do
        request.path == "/v1/messages" -> json(conn, anthropic_response(decision))
        authorization?(request.headers) -> json(conn, openai_response(decision))
        true -> json(conn, openai_text_response(decision))
      end
    end

    defp respond(conn, _request, {:text_decision, decision}) do
      json(conn, openai_text_response(wire_decision(decision)))
    end

    defp respond(conn, _request, {:raw_text, text}) do
      json(conn, openai_text_response(text, false))
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

    defp openai_response(decision) do
      base_response(
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "call-test",
              "type" => "function",
              "function" => %{
                "name" => "structured_output",
                "arguments" => Jason.encode!(decision)
              }
            }
          ]
        },
        "tool_calls"
      )
    end

    defp openai_text_response(decision) do
      openai_text_response(decision, true)
    end

    defp openai_text_response(decision, encode?) do
      content = if encode?, do: Jason.encode!(decision), else: decision
      base_response(%{"role" => "assistant", "content" => content}, "stop")
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
            "id" => "tool-test",
            "name" => "structured_output",
            "input" => decision
          }
        ],
        "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
      }
    end

    defp authorization?(headers), do: List.keymember?(headers, "authorization", 0)

    defp check_decision(body, {:decision, _decision} = mode) do
      if String.contains?(body, "Return the single value ready"),
        do: {:decision, %{"value" => "ready"}},
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
          "expected_result_json" => Jason.encode!(decision["expected_result"]),
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

  test "one adapter handles OpenAI, Anthropic, and Ollama without putting credentials in prompts",
       context do
    providers = [
      {"openai", context.endpoint <> "/v1", %{"api_key" => "openai-secret"}},
      {"anthropic", context.endpoint, %{"api_key" => "anthropic-secret"}},
      {"ollama", context.endpoint <> "/v1", %{}}
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
             "/v1/messages",
             "/v1/chat/completions"
           ]

    refute Enum.any?(requests, &String.contains?(&1.body, "openai-secret"))
    refute Enum.any?(requests, &String.contains?(&1.body, "anthropic-secret"))
    assert Enum.all?(requests, &String.contains?(&1.body, "report_language"))
    assert Enum.all?(requests, &String.contains?(&1.body, "human-facing reason"))

    assert Enum.all?(requests, &String.contains?(&1.body, "one intent allowed"))
    assert Enum.all?(requests, &String.contains?(&1.body, "expected_result_json"))

    assert Enum.all?(requests, fn request ->
             String.contains?(request.body, "Recovery is a terminal intent") and
               String.contains?(request.body, "fresh successful Target observation") and
               String.contains?(request.body, "never propose an effect when") and
               String.contains?(request.body, "returned facts can directly establish") and
               String.contains?(request.body, "tool's verification_schema")
           end)

    for request <- requests do
      schema = output_schema(request)
      assert schema["additionalProperties"] == false
      assert MapSet.new(schema["required"]) == MapSet.new(Map.keys(schema["properties"]))
      assert schema["properties"]["reason"]["type"] == "string"

      if Map.has_key?(schema["properties"]["reason"], "maxLength") do
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

      assert get_in(target_search, ["properties", "query", "maxLength"]) == 50
      assert get_in(handoff, ["properties", "required_input", "maxLength"]) == 250
    end
  end

  test "Ollama Cloud uses exact JSON text with the existing strict output schemas", context do
    state =
      state!("ollama", context.endpoint <> "/v1", %{}, %{"model" => "test-model:cloud"})

    set_mode(context.agent, {:text_decision, handoff()})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: "probe", required_input: "human"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)
    refute Map.has_key?(body, "tools")
    refute Map.has_key?(body, "response_format")
    assert body["temperature"] == 0
    assert body["reasoning_effort"] == "low"

    assert Enum.any?(body["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "exactly one JSON value") and
               String.contains?(message["content"], "JSON Schema") and
               String.contains?(message["content"], "additionalProperties")
           end)

    set_mode(context.agent, {:text_decision, %{"value" => "ready"}})
    assert :ok = Adapter.check(state, %{})

    set_mode(context.agent, {:text_decision, %{"verdict" => "approved", "reason" => "bounded"}})

    assert {:ok, %AI.ReviewDecision{verdict: :approved, reason: "bounded"}} =
             Adapter.review(state, review_request(), %{})

    set_mode(context.agent, {:text_decision, %{"unexpected" => true}})

    assert {:error, :invalid_output, "AI provider JSON does not match the requested schema"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, "```json\n{\"value\":\"ready\"}\n```"})
    assert {:error, :capability, _message} = Adapter.check(state, %{})

    assert {:error, :invalid_output, "AI provider output is not valid JSON"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, String.duplicate("x", 65_537)})

    assert {:error, :invalid_output, "AI provider JSON text is too large"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Ollama Cloud JSON requests preserve timeout and cancellation", context do
    state =
      state!("ollama", context.endpoint <> "/v1", %{}, %{
        "model" => "test-model:cloud",
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

  test "buffered AI calls support the resolver queue concurrency", context do
    state =
      state!("ollama", context.endpoint <> "/v1", %{}, %{
        "model" => "test-model:cloud",
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

  test "multilingual output stays within the byte-bounded AI contract", context do
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

    state = state!("ollama", context.endpoint <> "/v1", %{})

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

    assert {:error, :invalid_output, _message} = Adapter.resolve(state, resolver_request(), %{})
  end

  test "recovery schema exposes only eligible Target recovery Evidence", context do
    state = state!("ollama", context.endpoint <> "/v1", %{})

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
        disclosure: %{
          request.disclosure
          | allowed_evidence_kinds: ["observation", "target_verification"]
        }
    }

    set_mode(context.agent, {
      :text_decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh verification and monitoring agree",
        "evidence_ids" => ["verification-1", "verification-2", "verification-1"]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.RecoveryConclusion{
                evidence_ids: ["verification-1", "verification-2"]
              }
            }} = Adapter.resolve(state, request, %{})

    verified_request = requests(context.agent) |> List.last()

    recovery =
      Enum.find(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
      end)

    terminal_types =
      Enum.map(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"])
      end)

    assert terminal_types == [["recovery"]]

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
        "facts" => %{"ready" => true},
        "recovery_eligible" => true
      }
    }

    observed_request = %{
      request
      | evidence: [ordinary, observed],
        selected_target_id: "target-1",
        selected_target_revision: 1
    }

    set_mode(context.agent, {
      :text_decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh Target observation confirms recovery",
        "evidence_ids" => ["observation-recovered"]
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

  test "streamed and buffered responses produce the same decision", context do
    buffered = state!("ollama", context.endpoint <> "/v1", %{})
    streamed = state!("ollama", context.endpoint <> "/v1", %{}, %{"stream" => true})

    assert {:ok, buffered_decision} = Adapter.resolve(buffered, resolver_request(), %{})
    set_mode(context.agent, {:stream, handoff()})
    assert {:ok, streamed_decision} = Adapter.resolve(streamed, resolver_request(), %{})
    assert streamed_decision == buffered_decision
  end

  test "review uses an isolated prompt without resolver sessions or Target tools", context do
    set_mode(context.agent, {:decision, %{"verdict" => "approved", "reason" => "bounded"}})
    state = state!("ollama", context.endpoint <> "/v1", %{})

    assert {:ok,
            %AI.ReviewDecision{
              verdict: :approved,
              reason: "bounded",
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.review(state, review_request(), %{})

    [request] = requests(context.agent)
    assert request.body =~ "proposal-tool"
    assert request.body =~ "authoritative-request-value"
    assert request.body =~ "may be truncated"
    assert request.body =~ "Write the human-facing reason in the report_language"
    assert %{"report_language" => "ja"} = reviewer_payload(request)
    refute request.body =~ "resolver-private-session"
    refute request.body =~ "observation_tools"
    refute request.body =~ "proposal_tools"
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
      "expected_result" => %{"status" => "running"},
      "verification" => %{
        "tool_id" => "observe-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{},
        "expected_result" => %{"status" => "running"}
      }
    }

    set_mode(context.agent, {:decision, decision})
    state = state!("ollama", context.endpoint <> "/v1", %{})

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
                verification_intent: %AI.VerificationIntent{tool_id: "observe-tool"}
              }
            }} = Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)
    assert String.contains?(provider_request.body, "output_schema")
    assert String.contains?(provider_request.body, "verification_schema")
    schema = output_schema(provider_request)

    proposal_variant =
      Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["proposal"]
      end)

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

    set_mode(context.agent, {:decision, %{decision | "tool_id" => "invented-tool"}})
    assert {:error, :invalid_output, _message} = Adapter.resolve(state, request, %{})

    set_mode(context.agent, {:decision, Map.delete(decision, "tool_id")})
    assert {:error, :invalid_output, _message} = Adapter.resolve(state, request, %{})

    malformed = %{decision | "expected_result" => "not-an-object"}
    set_mode(context.agent, {:decision, malformed})
    assert {:error, :invalid_output, _message} = Adapter.resolve(state, request, %{})
  end

  test "malformed output, deadline, and caller cancellation stay typed", context do
    state = state!("ollama", context.endpoint <> "/v1", %{}, %{"timeout_ms" => 500})

    set_mode(context.agent, {:decision, %{"unexpected" => true}})
    assert {:error, :invalid_output, _message} = Adapter.resolve(state, resolver_request(), %{})

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
      "provider" => "ollama",
      "model" => "test-model",
      "endpoint" => context.endpoint <> "/v1"
    }

    assert {:error, :invalid_configuration} = Adapter.build(Map.put(base, "typo", true), %{})

    assert {:error, :invalid_configuration} =
             Adapter.build(%{base | "provider" => "openai"}, %{})

    assert {:error, :invalid_configuration} =
             Adapter.build(%{base | "provider" => "unknown"}, %{"api_key" => "secret"})

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "reasoning_effort", "unbounded"), %{})

    assert {:error, :invalid_configuration} =
             Adapter.build(
               %{base | "provider" => "openai"} |> Map.put("reasoning_effort", "low"),
               %{"api_key" => "secret"}
             )
  end

  test "Ollama Cloud reasoning effort can be overridden", context do
    state =
      state!("ollama", context.endpoint <> "/v1", %{}, %{
        "model" => "test-model:cloud",
        "reasoning_effort" => "high"
      })

    set_mode(context.agent, {:text_decision, handoff()})
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
          {"anthropic", context.endpoint}
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
          %{"api_key" => "provider-secret"},
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
    end
  end

  defp state!(provider, endpoint, credentials, extra_configuration \\ %{}) do
    configuration =
      Map.merge(
        %{"provider" => provider, "model" => "test-model", "endpoint" => endpoint},
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

    cond do
      schema = get_in(body, ["response_format", "json_schema", "schema"]) ->
        schema

      schema = get_in(body, ["tools", Access.at(0), "function", "parameters"]) ->
        schema

      schema = get_in(body, ["tools", Access.at(0), "input_schema"]) ->
        schema

      schema = get_in(body, ["output_format", "schema"]) ->
        schema

      true ->
        flunk("structured output schema missing from request: #{inspect(body)}")
    end
  end

  defp set_mode(agent, mode),
    do: Agent.update(agent, &%{&1 | mode: mode, requests: []})

  defp requests(agent),
    do: Agent.get(agent, &Enum.reverse(&1.requests))
end
