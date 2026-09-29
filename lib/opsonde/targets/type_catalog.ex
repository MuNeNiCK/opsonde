defmodule Opsonde.Targets.TypeCatalog do
  @moduledoc false

  @categories [
    %{id: "physical-server", label: "Physical server"},
    %{id: "network-device", label: "Network device"},
    %{id: "os", label: "Operating system"},
    %{id: "virtualization", label: "Virtualization"},
    %{id: "workload-platform", label: "Workload platform"},
    %{id: "storage", label: "Storage"},
    %{id: "data-service", label: "Data service"},
    %{id: "application-service", label: "Application / infrastructure service"},
    %{id: "power-facility", label: "Power / facility"}
  ]

  @types [
    %{
      id: "bmc",
      label: "BMC",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["bmc-redfish", "bmc-ipmi"]
    },
    %{
      id: "hpe-ilo",
      label: "HPE iLO",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["bmc-redfish", "bmc-ipmi"]
    },
    %{
      id: "dell-idrac",
      label: "Dell iDRAC",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["bmc-redfish", "bmc-ipmi"]
    },
    %{
      id: "custom-physical-server",
      label: "Custom physical server",
      category_id: "physical-server",
      kind: "physical_host",
      access_method_types: ["ssh-exec", "http-api"]
    },
    %{
      id: "cisco_ios_xe",
      label: "Cisco IOS XE",
      category_id: "network-device",
      kind: "network_device",
      access_method_types: [
        "ios-xe-ssh",
        "ios-xe-netconf",
        "ios-xe-restconf",
        "ssh-exec",
        "http-api"
      ]
    },
    %{
      id: "custom-network-device",
      label: "Custom network device",
      category_id: "network-device",
      kind: "network_device",
      access_method_types: ["ssh-exec", "http-api"]
    },
    %{
      id: "linux",
      label: "Linux",
      category_id: "os",
      kind: "host",
      access_method_types: ["linux-ssh", "ssh-exec", "http-api"]
    },
    %{
      id: "custom-os",
      label: "Custom operating system",
      category_id: "os",
      kind: "host",
      access_method_types: ["ssh-exec", "http-api"]
    },
    %{
      id: "custom-virtualization",
      label: "Custom virtualization platform",
      category_id: "virtualization",
      kind: "hypervisor",
      access_method_types: ["ssh-exec", "http-api"]
    },
    %{
      id: "custom-vm",
      label: "Custom virtual machine",
      category_id: "virtualization",
      kind: "virtual_machine",
      access_method_types: ["ssh-exec", "http-api"]
    },
    %{
      id: "kubernetes",
      label: "Kubernetes",
      category_id: "workload-platform",
      kind: "cluster",
      access_method_types: ["kubernetes-api"]
    }
  ]

  def snapshot, do: %{categories: @categories, types: @types}
  def fetch(id) when is_binary(id), do: Enum.find(@types, &(&1.id == id))
  def fetch(_id), do: nil

  def allows_method?(type_id, adapter_type) do
    case fetch(type_id) do
      %{access_method_types: allowed} -> adapter_type in allowed
      nil -> false
    end
  end
end
