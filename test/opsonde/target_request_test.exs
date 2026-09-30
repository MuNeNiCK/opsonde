defmodule Opsonde.TargetRequestTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.TargetRequest.{RequestError, Request, Clearance}

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)

    provider = enabled_target_provider!(admin)
    linux = create_target!(admin, "linux-01", "host", "linux")

    ssh =
      create_method!(admin, provider, linux, "ssh", "ssh", "ssh://192.0.2.10:22")

    api =
      create_method!(admin, provider, linux, "api", "agent", "https://192.0.2.10")

    %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      provider: provider,
      linux: linux,
      ssh: ssh,
      api: api
    }
  end

  test "cleared request dispatches the exact registered Method snapshot",
       context do
    other = create_target!(context.admin, "linux-02", "host", "linux")

    other_method =
      create_method!(
        context.admin,
        context.provider,
        other,
        "ssh",
        "ssh",
        "ssh://192.0.2.11:22"
      )

    request =
      request(other, other_method, :observation, :auto,
        capability: "observe.command",
        operation: "filesystem.read",
        selectors: %{"path" => "/usr/credential/service/token"},
        parameters: %{"command" => "cat /usr/credential/service/token"}
      )

    assert %Clearance{} =
             clearance = Targets.clear_target_request!(request, actor: context.operator)

    observation = %ProviderTarget.Observation{
      facts: %{"exists" => true},
      observed_at: DateTime.utc_now()
    }

    assert ^observation =
             Targets.dispatch_target_observation!(
               clearance,
               invocation(observation),
               actor: context.operator
             )

    assert_receive {:observe, _state, dispatched}
    assert dispatched.target_id == other.id
    assert dispatched.access_method_id == other_method.id
    assert dispatched.operation == "filesystem.read"
    assert dispatched.selectors == request.selectors
    assert dispatched.parameters == request.parameters
    assert dispatched.authorization_digest == clearance.digest
    assert dispatched.connection.endpoint == other_method.endpoint

    verification_request =
      request(other, other_method, :verification, :auto,
        capability: "observe.command",
        operation: "filesystem.verify",
        selectors: %{"path" => "/usr/credential/service/token"}
      )

    verification_clearance =
      Targets.clear_target_request!(verification_request, actor: context.operator)

    verification = %ProviderTarget.Verification{
      status: :verified,
      observed_at: DateTime.utc_now()
    }

    assert ^verification =
             Targets.dispatch_target_verification!(
               verification_clearance,
               invocation(verification),
               actor: context.operator
             )

    assert_receive {:verify, _state, verify_request}
    assert verify_request.access_method_id == other_method.id
    assert verify_request.operation == "filesystem.verify"
    assert verify_request.connection.endpoint == other_method.endpoint

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.target_observe(
               context.provider.id,
               dispatched,
               invocation(observation),
               actor: context.operator
             )

    refute_receive {:observe, _, _}
  end

  test "tampered or stale clearance and downgraded actors stop before dispatch", context do
    base =
      request(context.linux, context.ssh, :observation, :auto,
        capability: "observe.command",
        operation: "system.inspect"
      )

    clearance = Targets.clear_target_request!(base, actor: context.operator)
    tampered = %{clearance | parameters: %{"command" => "different"}}

    assert {:error, tampered_error} =
             Targets.dispatch_target_observation(
               tampered,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(tampered_error).category == :clearance_mismatch

    Targets.update_target!(
      context.linux,
      context.linux.revision,
      %{operating_instructions: "Do not modify root"},
      actor: context.admin
    )

    assert {:error, target_error} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(target_error).category == :stale_context

    rechecked =
      Targets.check_access_method!(context.ssh.id, context.ssh.revision, %{},
        actor: context.admin
      )

    current_request = %{
      base
      | target_revision: context.linux.revision + 1,
        access_method_revision: rechecked.revision
    }

    current_clearance = Targets.clear_target_request!(current_request, actor: context.operator)

    edited =
      Targets.update_access_method!(rechecked, rechecked.revision, %{priority: 10},
        actor: context.admin
      )

    assert {:error, method_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(method_error).category == :stale_context

    current_request = %{current_request | access_method_revision: edited.revision}
    current_clearance = Targets.clear_target_request!(current_request, actor: context.operator)

    Providers.update_provider!(
      context.provider,
      context.provider.revision,
      %{configuration: %{"endpoint" => "reachable"}},
      actor: context.admin
    )

    assert {:error, provider_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(provider_error).category == :stale_context
    refute_receive {:observe, _, _}
  end

  test "clearance reloads actor authorization before dispatch", context do
    request =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "system.inspect"
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, error} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(error).category == :forbidden
    refute_receive {:observe, _, _}
  end

  test "readonly permits effect recommendations but rejects their dispatch", context do
    observation =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "system.inspect"
      )

    assert %Clearance{} =
             Targets.clear_target_request!(observation, actor: context.operator)

    effect =
      request(context.linux, context.ssh, :effect, :readonly,
        capability: "effect.command",
        operation: "command.execute",
        parameters: %{"command" => "systemctl restart service"}
      )

    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, invocation(flunk_response()),
               actor: context.operator,
               authorize?: false
             )

    assert request_error(error).category == :forbidden
    refute_receive {:effect, _, _}
  end

  defp request(target, method, kind, mode, opts) do
    struct!(Request,
      kind: kind,
      authority_mode: mode,
      target_id: target.id,
      target_revision: target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: Keyword.fetch!(opts, :capability),
      operation: Keyword.fetch!(opts, :operation),
      selectors: Keyword.get(opts, :selectors, %{}),
      parameters: Keyword.get(opts, :parameters, %{}),
      operation_id: if(kind in [:effect, :verification], do: "operation-1"),
      idempotency_key: if(kind == :effect, do: "idempotency-1")
    )
  end

  defp create_target!(admin, name, kind, type_id) do
    Targets.create_target!(name, kind, type_id, %{}, nil, actor: admin)
  end

  defp create_method!(admin, provider, target, name, method, endpoint) do
    Targets.create_access_method!(
      target.id,
      provider.id,
      name,
      method,
      endpoint,
      provider.revision,
      100,
      ["observe.command", "effect.command"],
      actor: admin
    )
    |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))
  end

  defp enabled_target_provider!(admin) do
    provider =
      Providers.create_provider!(
        "target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-token"},
        actor: admin
      )

    Providers.enable_provider!(provider, provider.revision, actor: admin)
  end

  defp invocation(%_{} = response),
    do: %{test_pid: self(), respond: fn -> {:ok, response} end}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response.() end}

  defp flunk_response, do: fn -> flunk("denied request reached adapter") end

  defp request_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %RequestError{} = error -> error
      nested when is_map(nested) -> request_error(nested)
      _other -> nil
    end)
  end

  defp request_error(_error), do: nil
end
