defmodule Opsonde.BMCOperationTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}
  alias Opsonde.Targets.{PolicyRequest, PolicyError}
  alias Opsonde.Targets.BMC.OperationKey

  @password "correct horse battery staple"
  @input_schema %{
    "type" => "object",
    "properties" => %{
      "selectors" => %{"type" => "object", "additionalProperties" => false},
      "parameters" => %{"type" => "object", "additionalProperties" => false}
    },
    "required" => ["selectors", "parameters"],
    "additionalProperties" => false
  }
  @output_schema %{"type" => "object", "additionalProperties" => true}

  setup do
    admin = Accounts.bootstrap!("bmc-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("bmc-operator@example.com", @password, :operator, actor: admin)

    target =
      Targets.create_target!("rack-01", "physical_host", "bare_metal", %{}, nil, actor: admin)

    redfish = method!(admin, target, "bmc-redfish", "redfish", "https://bmc.example.test:8443")
    ipmi = method!(admin, target, "bmc-ipmi", "ipmi", "ipmi://bmc.example.test:623")

    %{admin: admin, operator: operator, target: target, redfish: redfish, ipmi: ipmi}
  end

  test "two Methods own independent standard and OEM operation definitions", context do
    redfish =
      create_definition!(
        context.admin,
        context.redfish,
        "Read thermal status",
        :observation,
        %{"method" => "GET", "uri" => "/redfish/v1/Chassis/1/Thermal"}
      )

    ipmi =
      create_definition!(
        context.admin,
        context.ipmi,
        "Get device ID",
        :observation,
        %{"netfn" => 6, "command" => 1}
      )

    assert redfish.access_method_id == context.redfish.id
    assert ipmi.access_method_id == context.ipmi.id

    assert %{} =
             Targets.clear_target_request!(request(context, context.redfish, redfish),
               actor: context.operator
             )

    assert %{} =
             Targets.clear_target_request!(request(context, context.ipmi, ipmi),
               actor: context.operator
             )

    assert {:error, error} =
             Targets.clear_target_request(
               request(context, context.ipmi, redfish),
               actor: context.operator
             )

    assert policy_error(error).category == :denied
  end

  test "unregistered or stale BMC operation cannot gain clearance", context do
    definition =
      create_definition!(
        context.admin,
        context.redfish,
        "Reset manager",
        :effect,
        %{"method" => "POST", "uri" => "/redfish/v1/Managers/1/Actions/Manager.Reset"}
      )

    request = request(context, context.redfish, definition, :effect)

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_effect(
               %{clearance | authority_mode: :readonly},
               %{},
               actor: context.operator,
               authorize?: false
             )

    assert policy_error(error).category == :clearance_mismatch

    readonly_clearance =
      Targets.clear_target_request!(%{request | authority_mode: :readonly},
        actor: context.operator
      )

    assert {:error, error} =
             Targets.dispatch_target_effect(readonly_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert policy_error(error).category == :forbidden

    assert {:error, error} =
             Targets.clear_target_request(%{request | kind: :observation},
               actor: context.operator
             )

    assert policy_error(error).category == :denied

    updated =
      Targets.update_bmc_operation!(definition, definition.revision, %{description: "Revised"},
        actor: context.admin
      )

    assert updated.revision > definition.revision
    assert {:error, error} = Targets.clear_target_request(request, actor: context.operator)
    assert policy_error(error).category == :denied

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert policy_error(error).category == :denied
  end

  test "operation shape and administrator permission are validated", context do
    assert {:error, _error} =
             Targets.create_bmc_operation(
               context.redfish.id,
               "Unsafe URL",
               "Invalid endpoint",
               :observation,
               %{"method" => "GET", "uri" => "https://other.example/redfish/v1"},
               @input_schema,
               @output_schema,
               nil,
               actor: context.admin
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.create_bmc_operation(
               context.ipmi.id,
               "OEM command",
               "Read vendor bytes",
               :observation,
               %{"netfn" => 48, "command" => 32},
               @input_schema,
               @output_schema,
               nil,
               actor: context.operator
             )
  end

  defp method!(admin, target, adapter, method, endpoint) do
    provider =
      Providers.create_provider!(
        "#{adapter}-provider",
        :target,
        adapter,
        %{"endpoint" => endpoint},
        %{"username" => "admin", "password" => "test-only"},
        actor: admin
      )

    checked =
      Providers.record_provider_check!(provider, provider.revision, :passed, nil, nil,
        authorize?: false
      )

    enabled = Providers.enable_provider!(checked, checked.revision, actor: admin)

    Targets.create_access_method!(
      target.id,
      enabled.id,
      method,
      "bare_metal",
      method,
      endpoint,
      enabled.revision,
      100,
      ["observe.power", "observe.bmc_api", "effect.bmc_api"],
      actor: admin
    )
  end

  defp create_definition!(admin, method, name, kind, protocol_request) do
    Targets.create_bmc_operation!(
      method.id,
      name,
      name,
      kind,
      protocol_request,
      @input_schema,
      @output_schema,
      nil,
      actor: admin
    )
  end

  defp request(context, method, definition, kind \\ :observation) do
    %PolicyRequest{
      kind: kind,
      authority_mode: :ask,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: OperationKey.capability(definition.request_kind),
      operation: OperationKey.format(definition),
      operation_id: if(kind == :effect, do: Ecto.UUID.generate(), else: nil),
      idempotency_key: if(kind == :effect, do: Ecto.UUID.generate(), else: nil)
    }
  end

  defp policy_error(%PolicyError{} = error), do: error
  defp policy_error(%{errors: errors}), do: Enum.find_value(errors, &policy_error/1)
  defp policy_error(_error), do: nil
end
