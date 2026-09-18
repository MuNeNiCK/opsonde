defmodule Opsonde.Providers.TargetTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.Accounts
  alias Opsonde.Providers
  alias Opsonde.Providers.Target

  @password "correct horse battery staple"
  @token "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("target-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("target-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("target-viewer@example.com", @password, :viewer, actor: admin)

    provider =
      Providers.create_provider!(
        "target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @token},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, operator: operator, viewer: viewer, provider: provider}
  end

  test "capabilities use the Ash interface, current gate and kind policy", context do
    capabilities = %Target.Capabilities{
      observations: ["observe.system"],
      effects: ["effect.restart_service"]
    }

    assert ^capabilities =
             Providers.target_capabilities!(
               context.provider.id,
               context.provider.revision,
               invocation(capabilities),
               actor: context.operator
             )

    assert_receive {:capabilities, %{token: @token}}

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.target_capabilities(
               context.provider.id,
               context.provider.revision,
               invocation(capabilities),
               actor: context.viewer
             )
  end

  test "observations retry bounded read failures and redact results", context do
    request = observation_request(context.provider.revision, 3)

    observation = %Target.Observation{
      facts: %{output: @token},
      observed_at: DateTime.utc_now(),
      evidence: ["credential=#{@token}"]
    }

    Process.put(:target_attempt, 0)

    invocation = %{
      test_pid: self(),
      respond: fn ->
        attempt = Process.get(:target_attempt, 0) + 1
        Process.put(:target_attempt, attempt)

        if attempt == 1,
          do: {:error, :retryable, "connection reset"},
          else: {:ok, observation}
      end
    }

    assert %Target.Observation{} =
             observed =
             Providers.target_observe!(context.provider.id, request, invocation,
               actor: context.admin
             )

    assert observed.facts == %{output: "[REDACTED]"}
    assert observed.evidence == ["credential=[REDACTED]"]
    assert_receive {:observe, %{token: @token}, ^request}
    assert_receive {:observe, %{token: @token}, ^request}
    refute_receive {:observe, _, _}
  end

  test "timeouts remain typed and cancellation or stale revision prevents dispatch", context do
    timeout_request = observation_request(context.provider.revision, 1)

    assert {:error, error} =
             Providers.target_observe(
               context.provider.id,
               timeout_request,
               invocation({:error, :timeout, "read deadline exceeded"}),
               actor: context.admin
             )

    assert target_error(error).category == :timeout
    assert_receive {:observe, %{token: @token}, ^timeout_request}

    cancelled_request = observation_request(context.provider.revision, 2)

    assert {:error, error} =
             Providers.target_observe(
               context.provider.id,
               cancelled_request,
               %{cancelled?: fn -> true end, test_pid: self()},
               actor: context.admin
             )

    assert target_error(error).category == :cancelled
    refute_receive {:observe, _, _}

    stale_request = observation_request(context.provider.revision + 1, 1)

    assert {:error, _error} =
             Providers.target_observe(
               context.provider.id,
               stale_request,
               invocation(flunk_response()),
               actor: context.admin
             )

    refute_receive {:observe, _, _}
  end

  test "request retry and payload bounds stop before dispatch", context do
    invalid_vocabulary = %{
      observation_request(context.provider.revision, 1)
      | capability: :system,
        operation: ""
    }

    assert {:error, vocabulary_error} =
             Providers.target_observe(
               context.provider.id,
               invalid_vocabulary,
               invocation(flunk_response()),
               actor: context.admin
             )

    assert target_error(vocabulary_error).message == "Invalid observation request"
    refute_receive {:observe, _, _}

    excessive_retries = observation_request(context.provider.revision, 6)

    assert {:error, retry_error} =
             Providers.target_observe(
               context.provider.id,
               excessive_retries,
               invocation(flunk_response()),
               actor: context.admin
             )

    assert target_error(retry_error).message == "Invalid observation request"
    refute_receive {:observe, _, _}

    oversized_effect = %{
      effect_request(context.provider.revision, "operation-oversized")
      | parameters: %{"payload" => String.duplicate("x", 65_537)}
    }

    assert {:error, effect_error} =
             Providers.target_effect(
               context.provider.id,
               oversized_effect,
               invocation(flunk_response()),
               actor: context.admin
             )

    assert target_error(effect_error).message == "Invalid effect request"
    refute_receive {:effect, _, _}
  end

  test "effects dispatch once and preserve applied, unknown, partial and failed results",
       context do
    for status <- [:applied, :unknown, :partial, :failed] do
      request = effect_request(context.provider.revision, "operation-#{status}")
      result = %Target.EffectResult{status: status, details: %{status: status}}

      assert ^result =
               Providers.target_effect!(context.provider.id, request, invocation(result),
                 actor: context.operator
               )

      assert_receive {:effect, %{token: @token}, ^request}
      refute_receive {:effect, _, _}
    end

    request = effect_request(context.provider.revision, "operation-retry")

    assert {:error, error} =
             Providers.target_effect(
               context.provider.id,
               request,
               invocation({:error, :retryable, "unsafe retry"}),
               actor: context.admin
             )

    assert target_error(error).category == :failed
    assert_receive {:effect, %{token: @token}, ^request}
    refute_receive {:effect, _, _}

    raised_request = effect_request(context.provider.revision, "operation-lost-response")

    assert %Target.EffectResult{status: :unknown, details: %{error: message}} =
             Providers.target_effect!(
               context.provider.id,
               raised_request,
               %{test_pid: self(), respond: fn -> raise "lost #{@token}" end},
               actor: context.admin
             )

    assert message == "lost [REDACTED]"
    assert_receive {:effect, %{token: @token}, ^raised_request}
    refute_receive {:effect, _, _}
  end

  test "verification is independent and malformed or raised adapter results are rejected",
       context do
    request = verification_request(context.provider.revision)
    verification = %Target.Verification{status: :verified, observed_at: DateTime.utc_now()}

    assert ^verification =
             Providers.target_verify!(context.provider.id, request, invocation(verification),
               actor: context.admin
             )

    assert_receive {:verify, %{token: @token}, ^request}

    assert {:error, malformed} =
             Providers.target_verify(
               context.provider.id,
               request,
               invocation(%{status: :verified}),
               actor: context.admin
             )

    assert target_error(malformed).message == "Invalid verification result"

    assert {:error, raised} =
             Providers.target_verify(
               context.provider.id,
               request,
               %{respond: fn -> raise "credential #{@token} failed" end},
               actor: context.admin
             )

    assert target_error(raised).message == "credential [REDACTED] failed"
    refute inspect(raised) =~ @token
  end

  test "adapter observation and verification facts are bounded", context do
    oversized = %{"payload" => String.duplicate("x", 65_537)}
    observation_request = observation_request(context.provider.revision, 1)

    assert {:error, observation_error} =
             Providers.target_observe(
               context.provider.id,
               observation_request,
               invocation(%Target.Observation{facts: oversized, observed_at: DateTime.utc_now()}),
               actor: context.admin
             )

    assert target_error(observation_error).message == "Invalid observation result"

    verification_request = verification_request(context.provider.revision)

    assert {:error, verification_error} =
             Providers.target_verify(
               context.provider.id,
               verification_request,
               invocation(%Target.Verification{
                 status: :verified,
                 observed_at: DateTime.utc_now(),
                 facts: oversized
               }),
               actor: context.admin
             )

    assert target_error(verification_error).message == "Invalid verification result"
  end

  defp observation_request(provider_revision, max_attempts) do
    struct!(Target.ObservationRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      capability: "observe.command",
      operation: "system.inspect",
      authorization_digest: "authorization-digest",
      max_attempts: max_attempts
    )
  end

  defp effect_request(provider_revision, operation_id) do
    struct!(Target.EffectRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      capability: "effect.command",
      operation: "service.restart",
      authorization_digest: "authorization-digest",
      operation_id: operation_id,
      idempotency_key: "idempotency-#{operation_id}"
    )
  end

  defp verification_request(provider_revision) do
    struct!(Target.VerificationRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      capability: "observe.command",
      operation: "service.inspect",
      authorization_digest: "authorization-digest",
      operation_id: "operation-1"
    )
  end

  defp invocation(%_{} = response),
    do: %{test_pid: self(), respond: fn -> {:ok, response} end}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response end}

  defp flunk_response, do: fn -> flunk("stale invocation reached adapter") end

  defp target_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Target.Error{} = error -> error
      nested when is_map(nested) -> target_error(nested)
      _other -> nil
    end)
  end

  defp target_error(_error), do: nil
end
