defmodule Opsonde.TargetsTest do
  use Opsonde.DataCase, async: false

  alias Opsonde.{Accounts, Providers, Targets}

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)
    provider = enabled_target_provider!(admin)

    %{admin: admin, operator: operator, viewer: viewer, provider: provider}
  end

  test "manual catalog represents mandatory and layered targets without address identity",
       context do
    boundary =
      Targets.create_management_boundary!("primary-dc", "datacenter", %{"region" => "jp"},
        actor: context.admin
      )

    linux = create_target!(context.admin, "linux-01", "host", "linux", boundary.id)
    kubernetes = create_target!(context.admin, "cluster-01", "cluster", "kubernetes", boundary.id)

    ios_xe =
      create_target!(context.admin, "edge-01", "network_device", "cisco_ios_xe", boundary.id)

    bmc = create_target!(context.admin, "bmc-01", "bmc", "redfish", boundary.id)

    hypervisor =
      create_target!(context.admin, "esxi-01", "hypervisor", "vmware_esxi", boundary.id)

    vm = create_target!(context.admin, "vm-01", "virtual_machine", "vmware_vm", boundary.id)

    junos =
      create_target!(context.admin, "edge-unsupported", "network_device", "junos", boundary.id)

    common_endpoint = "ssh://192.0.2.10:22"

    linux_ssh =
      create_method!(context, linux, "ssh", "linux", "ssh", common_endpoint, ["observe.command"])

    ios_ssh =
      create_method!(context, ios_xe, "ssh", "cisco_ios_xe", "ssh_cli", common_endpoint, [
        "observe.command",
        "effect.command"
      ])

    _ios_netconf =
      create_method!(
        context,
        ios_xe,
        "netconf",
        "cisco_ios_xe",
        "netconf",
        "ssh://192.0.2.10:830",
        [
          "observe.config",
          "effect.config"
        ]
      )

    _ios_restconf =
      create_method!(
        context,
        ios_xe,
        "restconf",
        "cisco_ios_xe",
        "restconf",
        "https://192.0.2.10",
        [
          "observe.config",
          "effect.config"
        ]
      )

    generic_ssh =
      create_method!(context, junos, "generic-ssh", "generic", "ssh", "ssh://192.0.2.20:22", [
        "observe.command"
      ])

    assert linux.id != ios_xe.id
    assert linux_ssh.endpoint == ios_ssh.endpoint
    assert generic_ssh.platform == "generic"

    assert Enum.sort(Enum.map(Targets.list_targets!(actor: context.viewer), & &1.platform)) ==
             Enum.sort(~w(cisco_ios_xe kubernetes linux redfish vmware_esxi vmware_vm junos))

    assert Enum.map(
             Targets.available_access_methods!(ios_xe.id, "observe.config", authorize?: false),
             & &1.method
           ) == ["netconf", "restconf"]

    assert Targets.available_access_methods!(kubernetes.id, "observe.command", authorize?: false) ==
             []

    assert Targets.available_access_methods!(bmc.id, "observe.command", authorize?: false) == []

    assert Targets.available_access_methods!(hypervisor.id, "observe.command", authorize?: false) ==
             []

    assert Targets.available_access_methods!(vm.id, "observe.command", authorize?: false) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.create_target(
               "forbidden",
               "host",
               "linux",
               %{},
               boundary.id,
               actor: context.operator
             )
  end

  test "bounded search resolves current targets through facts, identities, and relationships",
       context do
    source =
      Targets.create_target!(
        "application-node",
        "host",
        "linux",
        %{"serial" => "SN-ALPHA-42", "site" => "Tokyo"},
        nil,
        actor: context.admin
      )

    destination = create_target!(context.admin, "compute-host", "hypervisor", "vmware_esxi")

    identity =
      Targets.create_external_identity!(source.id, "zabbix", "hostid", "10427",
        actor: context.admin
      )

    relationship =
      Targets.create_relationship!(
        source.id,
        destination.id,
        "runs_on",
        %{"cluster" => "production-a"},
        nil,
        actor: context.admin
      )

    assert target_ids(Targets.search_targets!("alpha-42", 20, actor: context.operator)) == [
             source.id
           ]

    assert target_ids(Targets.search_targets!("10427", 20, actor: context.operator)) == [
             source.id
           ]

    assert Enum.sort(
             target_ids(Targets.search_targets!("production-a", 20, actor: context.operator))
           ) ==
             Enum.sort([source.id, destination.id])

    assert Targets.available_access_methods!(source.id, "observe.command", authorize?: false) ==
             []

    later =
      Targets.create_target!(
        "late-added-node",
        "host",
        "freebsd",
        %{"incident_hint" => "signal-9001"},
        nil,
        actor: context.admin
      )

    assert target_ids(Targets.search_targets!("signal-9001", 20, actor: context.operator)) == [
             later.id
           ]

    Targets.deactivate_external_identity!(identity, 1, actor: context.admin)
    assert target_ids(Targets.search_targets!("10427", 20, actor: context.operator)) == []

    Targets.deactivate_relationship!(relationship, 1, actor: context.admin)
    assert target_ids(Targets.search_targets!("production-a", 20, actor: context.operator)) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.create_external_identity(
               source.id,
               "resolver",
               "guess",
               "temporary-alias",
               actor: context.operator
             )
  end

  test "method and relationship use requires current active revisions", context do
    source = create_target!(context.admin, "vm-01", "virtual_machine", "vmware_vm")
    destination = create_target!(context.admin, "esxi-01", "hypervisor", "vmware_esxi")

    method =
      create_method!(context, source, "ssh", "generic", "ssh", "ssh://192.0.2.30:22", [
        "observe.command"
      ])

    assert Targets.load_access_method_for_use!(
             method.id,
             1,
             "observe.command",
             authorize?: false
           ).id == method.id

    updated_method =
      Targets.update_access_method!(
        method,
        1,
        %{priority: 10},
        actor: context.admin
      )

    assert updated_method.revision == 2

    assert {:error, _error} =
             Targets.load_access_method_for_use(
               method.id,
               1,
               "observe.command",
               authorize?: false
             )

    assert Targets.load_access_method_for_use!(
             method.id,
             2,
             "observe.command",
             authorize?: false
           ).id == method.id

    relationship =
      Targets.create_relationship!(
        source.id,
        destination.id,
        "runs_on",
        %{},
        DateTime.add(DateTime.utc_now(), 60, :second),
        actor: context.admin
      )

    assert Targets.load_relationship_for_traversal!(relationship.id, 1, authorize?: false).id ==
             relationship.id

    changed =
      Targets.update_relationship!(relationship, 1, %{facts: %{"slot" => "a"}},
        actor: context.admin
      )

    assert changed.revision == 2

    assert {:error, _error} =
             Targets.load_relationship_for_traversal(relationship.id, 1, authorize?: false)

    expired =
      Targets.create_relationship!(
        destination.id,
        source.id,
        "hosts",
        %{},
        DateTime.add(DateTime.utc_now(), -60, :second),
        actor: context.admin
      )

    assert {:error, _error} =
             Targets.load_relationship_for_traversal(expired.id, 1, authorize?: false)

    Providers.update_provider!(
      context.provider,
      context.provider.revision,
      %{configuration: %{"endpoint" => "reachable"}},
      actor: context.admin
    )

    assert Targets.available_access_methods!(source.id, "observe.command", authorize?: false) ==
             []
  end

  test "relationships are directional and reject self-links", context do
    bmc = create_target!(context.admin, "bmc-01", "bmc", "redfish")
    hypervisor = create_target!(context.admin, "esxi-01", "hypervisor", "vmware_esxi")
    linux = create_target!(context.admin, "linux-01", "host", "linux")
    cluster = create_target!(context.admin, "cluster-01", "cluster", "kubernetes")

    managed_by =
      Targets.create_relationship!(
        hypervisor.id,
        bmc.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    runs_on =
      Targets.create_relationship!(linux.id, hypervisor.id, "runs_on", %{}, nil,
        actor: context.admin
      )

    hosted_by =
      Targets.create_relationship!(cluster.id, linux.id, "hosted_by", %{}, nil,
        actor: context.admin
      )

    assert managed_by.source_target_id == hypervisor.id
    assert managed_by.destination_target_id == bmc.id
    assert runs_on.destination_target_id == hypervisor.id
    assert hosted_by.destination_target_id == linux.id

    assert {:error, error} =
             Targets.create_relationship(
               bmc.id,
               bmc.id,
               "managed_by",
               %{},
               nil,
               actor: context.admin
             )

    assert Exception.message(error) =~ "must differ"
  end

  test "BMC Access Methods bind their checked Provider to a physical host", context do
    physical = create_target!(context.admin, "rack-host-01", "physical_host", "bare_metal")
    virtual = create_target!(context.admin, "vm-01", "virtual_machine", "linux")

    for {adapter_type, method, endpoint} <- [
          {"bmc-redfish", "redfish", "https://bmc.example.test:8443"},
          {"bmc-ipmi", "ipmi", "ipmi://bmc.example.test:623"}
        ] do
      provider =
        Providers.create_provider!(
          "#{adapter_type}-provider",
          :target,
          adapter_type,
          %{"endpoint" => endpoint},
          %{"username" => "admin", "password" => "test-only"},
          actor: context.admin
        )

      # Fixture: only the registration boundary is under test here; no BMC is contacted.
      checked =
        Providers.record_provider_check!(provider, provider.revision, :passed, nil, nil,
          authorize?: false
        )

      enabled = Providers.enable_provider!(checked, checked.revision, actor: context.admin)

      create = fn target_id, candidate_method, candidate_endpoint, capabilities ->
        Targets.create_access_method(
          target_id,
          enabled.id,
          "#{method}-management",
          "bare_metal",
          candidate_method,
          candidate_endpoint,
          enabled.revision,
          100,
          capabilities,
          actor: context.admin
        )
      end

      assert {:ok, registered} =
               create.(physical.id, method, endpoint, ["observe.power", "effect.power"])

      assert registered.target_id == physical.id
      assert registered.endpoint == endpoint

      for {target_id, candidate_method, candidate_endpoint, capabilities} <- [
            {virtual.id, method, endpoint, ["observe.power"]},
            {physical.id, "ssh", endpoint, ["observe.power"]},
            {physical.id, method, "#{endpoint}/other", ["observe.power"]},
            {physical.id, method, endpoint, ["effect.power"]},
            {physical.id, method, endpoint, ["observe.power", "native.ssh"]}
          ] do
        assert {:error, error} =
                 create.(target_id, candidate_method, candidate_endpoint, capabilities)

        assert Exception.message(error) =~ "BMC Access Method must match"
      end
    end
  end

  defp target_ids(%Targets.SearchResult{targets: targets}), do: Enum.map(targets, & &1.id)

  defp create_target!(admin, name, kind, platform, boundary_id \\ nil) do
    Targets.create_target!(name, kind, platform, %{}, boundary_id, actor: admin)
  end

  defp create_method!(context, target, name, platform, method, endpoint, capabilities) do
    Targets.create_access_method!(
      target.id,
      context.provider.id,
      name,
      platform,
      method,
      endpoint,
      context.provider.revision,
      100,
      capabilities,
      actor: context.admin
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
end
