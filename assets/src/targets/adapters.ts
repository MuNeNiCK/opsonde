export const targetAdapterOptions = [
  { type: "linux-ssh", label: "Linux SSH", family: "ssh" },
  {
    type: "bmc-redfish",
    label: "Redfish",
    family: "bmc-redfish",
  },
  {
    type: "bmc-ipmi",
    label: "IPMI (RMCP+)",
    family: "bmc-ipmi",
  },
  {
    type: "kubernetes-api",
    label: "Kubernetes API",
    family: "kubernetes",
  },
  {
    type: "ios-xe-ssh",
    label: "Cisco IOS XE SSH/CLI",
    family: "ssh",
  },
  {
    type: "ios-xe-netconf",
    label: "Cisco IOS XE NETCONF",
    family: "ssh",
  },
  {
    type: "ios-xe-restconf",
    label: "Cisco IOS XE RESTCONF",
    family: "restconf",
  },
  {
    type: "ssh-exec",
    label: "SSH command",
    family: "ssh",
  },
  {
    type: "http-api",
    label: "HTTP API",
    family: "http",
  },
] as const;

export function targetAdapter(type: string) {
  return targetAdapterOptions.find((option) => option.type === type);
}

export const targetProviderChoices = [
  { id: "bmc", adapterTypes: ["bmc-redfish", "bmc-ipmi"] },
  { id: "linux", adapterTypes: ["linux-ssh", "http-api"] },
  {
    id: "cisco-ios-xe",
    adapterTypes: ["ios-xe-ssh", "ios-xe-netconf", "ios-xe-restconf"],
  },
  { id: "kubernetes", adapterTypes: ["kubernetes-api"] },
  { id: "protocol", adapterTypes: ["ssh-exec", "http-api"] },
  { id: "netbox", adapterTypes: ["netbox-api"] },
] as const;

export type TargetProviderChoice = (typeof targetProviderChoices)[number]["id"];

export function targetProviderChoice(id: string | undefined) {
  return targetProviderChoices.find((choice) => choice.id === id);
}
