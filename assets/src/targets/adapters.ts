export const targetAdapterOptions = [
  { type: "linux-ssh", label: "Linux SSH", platform: "linux", method: "ssh", family: "ssh" },
  {
    type: "bmc-redfish",
    label: "Redfish",
    platform: "bare_metal",
    method: "redfish",
    family: "bmc-redfish",
  },
  {
    type: "bmc-ipmi",
    label: "IPMI (RMCP+)",
    platform: "bare_metal",
    method: "ipmi",
    family: "bmc-ipmi",
  },
  {
    type: "kubernetes-api",
    label: "Kubernetes API",
    platform: "kubernetes",
    method: "api",
    family: "kubernetes",
  },
  {
    type: "ios-xe-ssh",
    label: "Cisco IOS XE SSH/CLI",
    platform: "cisco_ios_xe",
    method: "ssh_cli",
    family: "ssh",
  },
  {
    type: "ios-xe-netconf",
    label: "Cisco IOS XE NETCONF",
    platform: "cisco_ios_xe",
    method: "netconf",
    family: "ssh",
  },
  {
    type: "ios-xe-restconf",
    label: "Cisco IOS XE RESTCONF",
    platform: "cisco_ios_xe",
    method: "restconf",
    family: "restconf",
  },
  {
    type: "generic-ssh",
    label: "Generic SSH",
    platform: "generic",
    method: "ssh",
    family: "ssh",
  },
] as const;

export function targetAdapter(type: string) {
  return targetAdapterOptions.find((option) => option.type === type);
}

export const targetProviderChoices = [
  { id: "physical-host", adapterTypes: ["bmc-redfish", "bmc-ipmi"] },
  { id: "linux", adapterTypes: ["linux-ssh"] },
  {
    id: "cisco-ios-xe",
    adapterTypes: ["ios-xe-ssh", "ios-xe-netconf", "ios-xe-restconf"],
  },
  { id: "kubernetes", adapterTypes: ["kubernetes-api"] },
  { id: "generic", adapterTypes: ["generic-ssh"] },
  { id: "netbox", adapterTypes: ["netbox-api"] },
] as const;

export type TargetProviderChoice = (typeof targetProviderChoices)[number]["id"];

export function targetProviderChoice(id: string | undefined) {
  return targetProviderChoices.find((choice) => choice.id === id);
}
