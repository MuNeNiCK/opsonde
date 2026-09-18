defmodule Opsonde.Providers.AITest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.Providers
  alias Opsonde.Providers.AI

  @password "correct horse battery staple"
  @api_key "ai-provider-secret"

  setup do
    admin = Accounts.bootstrap!("ai-admin@example.com", @password, @password, authorize?: true)

    provider =
      Providers.create_provider!(
        "ai-provider",
        :ai,
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => @api_key},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, provider: provider}
  end

  test "prior observations can change one available next choice", context do
    request = request(context.provider.revision)

    respond = fn request ->
      tool_id = if request.observation_results == [], do: "inspect-system", else: "inspect-disk"

      {:ok,
       %AI.Decision{
         usage: usage(),
         next_observation: %AI.ObservationChoice{
           tool_id: tool_id,
           parameters: %{},
           reason: "next fact"
         }
       }}
    end

    first = decide!(context, request, respond)
    assert first.next_observation.tool_id == "inspect-system"
    assert_receive {:decision, %{model: "test-model", api_key: @api_key}, ^request}

    with_observation = %{
      request
      | observation_results: [
          %AI.ObservationResult{
            tool_id: "inspect-system",
            target_id: "target-1",
            kind: :observation,
            status: :ok,
            content: %{load: 0.9}
          }
        ]
    }

    second = decide!(context, with_observation, respond)
    assert second.next_observation.tool_id == "inspect-disk"
  end

  test "structured conclusions preserve bounds and redact credential echoes", context do
    request = request(context.provider.revision)

    decision =
      decide!(context, request, fn _request ->
        {:ok,
         %AI.Decision{
           usage: usage(),
           findings: [
             %AI.Finding{
               summary: "leak #{@api_key}",
               confidence: 0.8,
               evidence_ids: ["evidence-1"]
             }
           ],
           proposals: [
             %AI.Proposal{
               target_id: "target-1",
               capability: :restart_service,
               parameters: %{service: "api"},
               reason: "recover service"
             }
           ]
         }}
      end)

    assert hd(decision.findings).summary == "leak [REDACTED]"
    assert decision.usage == usage()
    refute inspect(request) =~ @api_key
    refute inspect(decision) =~ @api_key
  end

  test "malformed and unavailable choices are rejected", context do
    request = request(context.provider.revision)

    invalid_choice = fn _request ->
      {:ok,
       %AI.Decision{
         usage: usage(),
         next_observation: %AI.ObservationChoice{
           tool_id: "missing-tool",
           parameters: %{},
           reason: "invalid"
         }
       }}
    end

    assert {:error, error} = decide(context, request, invalid_choice)
    assert ai_error(error).category == :invalid_output

    assert {:error, error} = decide(context, request, fn _request -> {:ok, %{}} end)
    assert ai_error(error).category == :invalid_output
  end

  test "token usage is nonnegative and cannot exceed the remaining budget", context do
    request = request(context.provider.revision)

    assert {:error, invalid} =
             decide(context, request, fn _request ->
               {:ok,
                %AI.Decision{
                  usage: %AI.Usage{input_tokens: -1, output_tokens: 1},
                  findings: []
                }}
             end)

    assert ai_error(invalid).category == :invalid_output

    assert {:error, exhausted} =
             decide(context, request, fn _request ->
               {:ok,
                %AI.Decision{
                  usage: %AI.Usage{input_tokens: 1_500, output_tokens: 501},
                  findings: []
                }}
             end)

    assert ai_error(exhausted).category == :budget_exhausted
  end

  test "connection failures remain typed and redact adapter messages", context do
    request = request(context.provider.revision)

    for category <- [:authentication, :unreachable, :timeout, :rate_limited, :failed] do
      assert {:error, error} =
               decide(context, request, fn _request ->
                 {:error, category, "credential #{@api_key} failed"}
               end)

      assert ai_error(error).category == category
      assert ai_error(error).message == "credential [REDACTED] failed"
      refute inspect(error) =~ @api_key
    end
  end

  test "cancellation, exhausted budget and disclosure bounds stop before dispatch", context do
    request = request(context.provider.revision)

    assert {:error, cancelled} =
             Providers.ai_decide(
               context.provider.id,
               request,
               %{cancelled?: fn -> true end},
               actor: context.admin
             )

    assert ai_error(cancelled).category == :cancelled

    exhausted = %{request | budget: %AI.Budget{remaining_turns: 0, remaining_tokens: 100}}
    assert {:error, error} = decide(context, exhausted, unreachable_response())
    assert ai_error(error).category == :budget_exhausted

    bounded = %{request | disclosure: %{request.disclosure | max_bytes: 1}}
    assert {:error, error} = decide(context, bounded, unreachable_response())
    assert ai_error(error).category == :disclosure_limit

    refute_receive {:decision, _, _}
  end

  defp decide(context, request, respond) do
    Providers.ai_decide(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp decide!(context, request, respond) do
    Providers.ai_decide!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp request(provider_revision) do
    %AI.Request{
      provider_revision: provider_revision,
      objective: "Restore service health",
      disclosure: %AI.Disclosure{
        allowed_target_ids: ["target-1"],
        allowed_evidence_kinds: [:signal, :observation],
        max_items: 10,
        max_bytes: 10_000
      },
      budget: %AI.Budget{remaining_turns: 4, remaining_tokens: 2_000},
      evidence: [
        %AI.Evidence{
          id: "evidence-1",
          kind: :signal,
          target_id: "target-1",
          content: %{alert: "high load"}
        }
      ],
      observation_results: [],
      tools: [
        %AI.ObservationTool{
          id: "inspect-system",
          target_id: "target-1",
          capability: :system,
          description: "Inspect system state",
          input_schema: %{}
        },
        %AI.ObservationTool{
          id: "inspect-disk",
          target_id: "target-1",
          capability: :disk,
          description: "Inspect disk state",
          input_schema: %{}
        }
      ]
    }
  end

  defp usage, do: %AI.Usage{input_tokens: 100, output_tokens: 50}

  defp unreachable_response,
    do: fn _request -> flunk("bounded request reached AI adapter") end

  defp ai_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %AI.Error{} = error -> error
      nested when is_map(nested) -> ai_error(nested)
      _other -> nil
    end)
  end

  defp ai_error(_error), do: nil
end
