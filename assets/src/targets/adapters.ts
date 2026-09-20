export const targetAdapterOptions = [
  { type: "linux-ssh", label: "Linux SSH", platform: "linux", method: "ssh", family: "ssh" },
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
