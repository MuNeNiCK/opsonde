defmodule Opsonde.TargetPolicyTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Providers.Target, as: ProviderTarget
  alias Opsonde.Targets.{PolicyError, PolicyRequest, RequestClearance}

  @password "correct horse battery staple"
  @modes [:readonly, :ask, :auto, :full_access]

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)

    provider = enabled_target_provider!(admin)
    linux = create_target!(admin, "linux-01", "host", "linux")

    ssh =
      create_method!(admin, provider, linux, "ssh", "linux", "ssh", "ssh://192.0.2.10:22")

    api =
      create_method!(admin, provider, linux, "api", "linux", "agent", "https://192.0.2.10")

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

  test "one Target deny rule blocks observations and effects through every method and mode",
       context do
    policy =
      create_policy!(
        context,
        context.linux,
        "protect-credentials",
        [:observation, :effect],
        [],
        [],
        %{"path" => %{"prefix" => "/usr/credential"}},
        %{},
        "credential directory is forbidden"
      )

    assert policy.target_id == context.linux.id

    for mode <- @modes,
        method <- [context.ssh, context.api],
        kind <- [:observation, :effect] do
      request =
        request(context.linux, method, kind, mode,
          capability: capability(kind),
          operation: if(kind == :effect, do: "filesystem.delete", else: "filesystem.read"),
          selectors: %{"path" => "/usr/credential/service/token"}
        )

      assert {:error, error} =
               Targets.clear_target_request(request, actor: context.operator)

      assert policy_error(error).category == :denied
      assert policy_error(error).policy_id == policy.id
    end

    refute_receive {:observe, _, _}
    refute_receive {:effect, _, _}
  end

  test "policy affects only its Target and cleared request dispatches the exact snapshot",
       context do
    create_policy!(
      context,
      context.linux,
      "protect-credentials",
      [:observation],
      ["observe.command"],
      ["filesystem.read"],
      %{"path" => %{"prefix" => "/usr/credential"}},
      %{},
      "credential directory is forbidden"
    )

    other = create_target!(context.admin, "linux-02", "host", "linux")

    other_method =
      create_method!(
        context.admin,
        context.provider,
        other,
        "ssh",
        "generic",
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

    assert %RequestClearance{} =
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

  test "canonical and generic rules deny Cisco port shutdown without blocking another port",
       context do
    ios = create_target!(context.admin, "edge-01", "network_device", "cisco_ios_xe")

    netconf =
      create_method!(
        context.admin,
        context.provider,
        ios,
        "netconf",
        "cisco_ios_xe",
        "netconf",
        "ssh://192.0.2.20:830"
      )

    generic =
      create_method!(
        context.admin,
        context.provider,
        ios,
        "generic-ssh",
        "generic",
        "ssh",
        "ssh://192.0.2.20:22"
      )

    create_policy!(
      context,
      ios,
      "keep-port-6-up",
      [:effect],
      ["effect.command"],
      ["interface.shutdown"],
      %{"interface" => %{"eq" => "GigabitEthernet1/0/6"}},
      %{},
      "port 6 must remain up"
    )

    blocked =
      request(ios, netconf, :effect, :full_access,
        capability: "effect.command",
        operation: "interface.shutdown",
        selectors: %{"interface" => "GigabitEthernet1/0/6"}
      )

    assert {:error, error} = Targets.clear_target_request(blocked, actor: context.admin)
    assert policy_error(error).category == :denied

    allowed =
      request(ios, netconf, :effect, :auto,
        capability: "effect.command",
        operation: "interface.shutdown",
        selectors: %{"interface" => "GigabitEthernet1/0/7"}
      )

    clearance = Targets.clear_target_request!(allowed, actor: context.admin)
    result = %ProviderTarget.EffectResult{status: :applied}

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.dispatch_target_effect(clearance, invocation(result), actor: context.admin)

    assert ^result =
             Targets.dispatch_target_effect!(clearance, invocation(result),
               actor: context.admin,
               authorize?: false
             )

    assert_receive {:effect, _state, %{access_method_id: id} = dispatched_effect}
    assert id == netconf.id
    assert dispatched_effect.connection.endpoint == netconf.endpoint

    create_policy!(
      context,
      ios,
      "generic-command-guard",
      [:effect],
      ["effect.command"],
      ["command.execute"],
      %{},
      %{"command" => %{"contains" => "shutdown interface GigabitEthernet1/0/6"}},
      "generic command targets protected port"
    )

    raw =
      request(ios, generic, :effect, :ask,
        capability: "effect.command",
        operation: "command.execute",
        parameters: %{"command" => "configure; shutdown interface GigabitEthernet1/0/6"}
      )

    assert {:error, raw_error} = Targets.clear_target_request(raw, actor: context.admin)
    assert policy_error(raw_error).category == :denied
    refute_receive {:effect, _, _}
  end

  test "ambiguous match fails closed and invalid matcher cannot be stored", context do
    create_policy!(
      context,
      context.linux,
      "path-guard",
      [:observation],
      [],
      [],
      %{"path" => %{"prefix" => "/usr/credential"}},
      %{},
      "path must be evaluated"
    )

    ambiguous =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "filesystem.read",
        selectors: %{"path" => 42}
      )

    assert {:error, error} = Targets.clear_target_request(ambiguous, actor: context.operator)
    assert policy_error(error).category == :ambiguous_policy

    assert {:error, invalid} =
             Targets.create_target_policy(
               context.linux.id,
               "invalid",
               [:effect],
               [],
               [],
               %{},
               %{"command" => %{"regex" => ".*"}},
               "unsupported matcher",
               actor: context.admin
             )

    assert Exception.message(invalid) =~ "operator map"
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

    assert policy_error(tampered_error).category == :clearance_mismatch

    policy =
      create_policy!(
        context,
        context.linux,
        "nonmatching",
        [:effect],
        [],
        ["service.restart"],
        %{},
        %{},
        "unrelated effect"
      )

    assert {:error, policy_error_result} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert policy_error(policy_error_result).category == :stale_policy

    current_clearance = Targets.clear_target_request!(base, actor: context.operator)

    Targets.update_target_policy!(policy, 1, %{reason: "changed policy"}, actor: context.admin)

    assert {:error, changed_policy_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert policy_error(changed_policy_error).category == :stale_policy

    current_clearance = Targets.clear_target_request!(base, actor: context.operator)

    Targets.update_access_method!(context.ssh, 1, %{priority: 10}, actor: context.admin)

    assert {:error, method_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert policy_error(method_error).category == :stale_context

    current_request = %{base | access_method_revision: 2}
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

    assert policy_error(provider_error).category == :stale_context
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

    assert policy_error(error).category == :forbidden
    refute_receive {:observe, _, _}
  end

  test "readonly permits observations but rejects effects before dispatch", context do
    observation =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "system.inspect"
      )

    assert %RequestClearance{} =
             Targets.clear_target_request!(observation, actor: context.operator)

    effect =
      request(context.linux, context.ssh, :effect, :readonly,
        capability: "effect.command",
        operation: "command.execute",
        parameters: %{"command" => "systemctl restart service"}
      )

    assert {:error, error} = Targets.clear_target_request(effect, actor: context.operator)
    assert policy_error(error).category == :forbidden
    refute_receive {:effect, _, _}
  end

  defp request(target, method, kind, mode, opts) do
    struct!(PolicyRequest,
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

  defp create_policy!(
         context,
         target,
         name,
         kinds,
         capabilities,
         operations,
         selectors,
         parameters,
         reason
       ) do
    Targets.create_target_policy!(
      target.id,
      name,
      kinds,
      capabilities,
      operations,
      selectors,
      parameters,
      reason,
      actor: context.admin
    )
  end

  defp create_target!(admin, name, kind, platform) do
    Targets.create_target!(name, kind, platform, %{}, nil, actor: admin)
  end

  defp create_method!(admin, provider, target, name, platform, method, endpoint) do
    Targets.create_access_method!(
      target.id,
      provider.id,
      name,
      platform,
      method,
      endpoint,
      provider.revision,
      100,
      ["observe.command", "effect.command"],
      actor: admin
    )
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

    checked = Providers.check_provider!(provider.id, provider.revision, %{}, actor: admin)
    Providers.enable_provider!(checked, checked.revision, actor: admin)
  end

  defp capability(:effect), do: "effect.command"
  defp capability(_kind), do: "observe.command"

  defp invocation(%_{} = response),
    do: %{test_pid: self(), respond: fn -> {:ok, response} end}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response.() end}

  defp flunk_response, do: fn -> flunk("denied request reached adapter") end

  defp policy_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %PolicyError{} = error -> error
      nested when is_map(nested) -> policy_error(nested)
      _other -> nil
    end)
  end

  defp policy_error(_error), do: nil
end
