import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetConnectionCreatePage } from "@/targets/connection-create-page";
import type { TargetTypeCatalog } from "@/targets/data";

const catalog: TargetTypeCatalog = {
  categories: [
    { id: "physical-server", label: "Physical server" },
    { id: "network-device", label: "Network device" },
  ],
  types: [
    {
      id: "custom-bmc",
      label: "Custom BMC",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["redfish", "ipmi"],
    },
    {
      id: "hpe-ilo",
      label: "HPE iLO",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["redfish", "ipmi", "hpe-ilo-ipmi"],
    },
    {
      id: "custom-network-device",
      label: "Custom network device",
      category_id: "network-device",
      kind: "network_device",
      access_method_types: ["netconf", "restconf"],
    },
  ],
  methods: [
    { adapter_type: "redfish", label: "Redfish", protocol: "redfish" },
    { adapter_type: "ipmi", label: "IPMI (RMCP+)", protocol: "ipmi" },
    { adapter_type: "hpe-ilo-ipmi", label: "HPE iLO IPMI", protocol: "ipmi" },
    { adapter_type: "netconf", label: "NETCONF", protocol: "netconf" },
    { adapter_type: "restconf", label: "RESTCONF", protocol: "restconf" },
  ],
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

async function renderPage(path: string) {
  await i18n.changeLanguage("en");
  const calls: { path: string; options: unknown }[] = [];
  vi.spyOn(apiClient, "GET").mockImplementation((() =>
    Promise.resolve({
      data: { data: catalog },
      response: new Response(),
    })) as typeof apiClient.GET);
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    calls.push({ path, options });
    return Promise.resolve({
      data: {
        data: {
          id: "provider-1",
          revision: 1,
          enabled: path.endsWith("/enable"),
          check: { status: null },
        },
      },
      response: new Response(),
    });
  }) as typeof apiClient.POST);
  render(
    <AuthenticationContext.Provider value={{ account: { role: "admin" } } as Authentication}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/targets/connections/new" element={<TargetConnectionCreatePage />} />
          <Route path="/targets/connections/new/:family" element={<TargetConnectionCreatePage />} />
          <Route path="/targets/connections" element={<p>Connection saved</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  return { calls, user: userEvent.setup() };
}

test("connection choices are exactly the published Target types plus Inventory", async () => {
  await renderPage("/targets/connections/new");
  expect(await screen.findByRole("link", { name: /Custom BMC/ })).toBeTruthy();
  expect(screen.getByRole("link", { name: /HPE iLO/ })).toBeTruthy();
  expect(screen.getByRole("link", { name: /Custom network device/ })).toBeTruthy();
  expect(screen.getByRole("link", { name: /NetBox/ })).toBeTruthy();
  expect(screen.getByText("NETCONF · RESTCONF")).toBeTruthy();
});

test("named controller profile uses the published IPMI form and exact Provider identity", async () => {
  const { calls, user } = await renderPage("/targets/connections/new/hpe-ilo");
  await screen.findByRole("textbox", { name: "Name" });
  await user.click(screen.getByRole("combobox", { name: "Connection type" }));
  await user.click(screen.getByRole("option", { name: "HPE iLO IPMI" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "rack-controller");
  await user.type(
    screen.getByRole("textbox", { name: "Endpoint" }),
    "ipmi://controller.example:623",
  );
  await user.type(screen.getByRole("textbox", { name: "Username" }), "operator");
  await user.type(screen.getByLabelText("Password"), "test-secret");
  await user.click(screen.getByRole("button", { name: "Add Target connection" }));
  await waitFor(() => expect(screen.getByText("Connection saved")).toBeTruthy());
  expect(calls).toEqual([
    {
      path: "/api/v1/providers",
      options: {
        body: {
          provider: {
            name: "rack-controller",
            kind: "target",
            adapter_type: "hpe-ilo-ipmi",
            configuration: {},
            credentials: { username: "operator", password: "test-secret" },
          },
        },
      },
    },
    {
      path: "/api/v1/providers/{id}/enable",
      options: {
        params: { path: { id: "provider-1" } },
        body: {
          provider: {
            expected_revision: 1,
          },
        },
      },
    },
  ]);
});

test("Custom network NETCONF preserves protocol auth and host fingerprint", async () => {
  const { calls, user } = await renderPage("/targets/connections/new/custom-network-device");
  await screen.findByRole("textbox", { name: "Name" });
  await user.type(screen.getByRole("textbox", { name: "Name" }), "edge-netconf");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "ssh://edge.example:830");
  await user.type(screen.getByRole("textbox", { name: "Host key fingerprint" }), "SHA256:fixture");
  await user.type(screen.getByRole("textbox", { name: "Username" }), "operator");
  await user.type(screen.getByLabelText("Password"), "test-only-password");
  await user.click(screen.getByRole("button", { name: "Add Target connection" }));
  await waitFor(() => expect(screen.getByText("Connection saved")).toBeTruthy());
  expect(calls[0]).toEqual({
    path: "/api/v1/providers",
    options: {
      body: {
        provider: {
          name: "edge-netconf",
          kind: "target",
          adapter_type: "netconf",
          configuration: { host_key_fingerprints: { "ssh://edge.example:830": "SHA256:fixture" } },
          credentials: {
            username: "operator",
            auth_method: "password",
            password: "test-only-password",
          },
        },
      },
    },
  });
});

test.each([false, true])(
  "activation response loss retains one connection; current enabled=%s",
  async (enabled) => {
    const { user } = await renderPage("/targets/connections/new/custom-bmc");
    let created = 0;
    let activated = 0;
    vi.mocked(apiClient.GET).mockImplementation(((path: string) =>
      Promise.resolve({
        data: {
          data:
            path === "/api/v1/target-types"
              ? catalog
              : { id: "provider-1", revision: enabled ? 2 : 1, enabled },
        },
        response: new Response(),
      })) as typeof apiClient.GET);
    vi.mocked(apiClient.POST).mockImplementation(((path: string) => {
      if (path === "/api/v1/providers") created++;
      if (path.endsWith("/enable") && ++activated === 1)
        return Promise.reject(new Error("Lost response"));
      return Promise.resolve({
        data: { data: { id: "provider-1", revision: 1, enabled: path.endsWith("/enable") } },
        response: new Response(),
      });
    }) as typeof apiClient.POST);
    await screen.findByRole("textbox", { name: "Name" });
    await user.type(screen.getByRole("textbox", { name: "Name" }), "rack-controller");
    await user.type(
      screen.getByRole("textbox", { name: "Endpoint" }),
      "https://controller.example",
    );
    await user.type(screen.getByRole("textbox", { name: "Username" }), "operator");
    await user.type(screen.getByLabelText("Password"), "fixture-secret");
    await user.type(screen.getByRole("textbox", { name: "CA certificate" }), "fixture-ca");
    await user.click(screen.getByRole("button", { name: "Add Target connection" }));
    await screen.findByRole("button", { name: "Enable connection" });
    expect(screen.getByRole("textbox", { name: "Endpoint" }).closest("fieldset")).toHaveProperty(
      "disabled",
      true,
    );
    await user.click(screen.getByRole("button", { name: "Enable connection" }));
    await screen.findByText("Connection saved");
    expect(created).toBe(1);
    expect(activated).toBe(enabled ? 1 : 2);
  },
);
