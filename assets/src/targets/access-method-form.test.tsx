import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import i18n from "@/i18n/config";
import { AccessMethodForm } from "@/targets/access-method-form";
import type { Provider, ProviderReference, Target, TargetTypeCatalog } from "@/targets/data";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

function fixture() {
  const time = "2026-09-30T00:00:00Z";
  const target: Target = {
    id: "target-1",
    name: "edge",
    kind: "network_device",
    type_id: "custom-network-device",
    active: true,
    facts: {},
    operating_instructions: "",
    management_boundary_id: null,
    revision: 1,
    inserted_at: time,
    updated_at: time,
  };
  const provider: Provider = {
    id: "provider-1",
    name: "Shared HTTP credentials",
    kind: "target",
    adapter_type: "http-api",
    access_method_profile: { method: "http" },
    configuration: {},
    enabled: true,
    revision: 3,
    check: {
      status: null,
      checked_revision: null,
      checked_at: time,
      category: null,
      message: null,
    },
    inserted_at: time,
    updated_at: time,
  };
  const catalog: TargetTypeCatalog = {
    categories: [{ id: "network-device", label: "Network device" }],
    types: [
      {
        id: "custom-network-device",
        label: "Custom network device",
        category_id: "network-device",
        kind: "network_device",
        access_method_types: ["http-api"],
      },
    ],
    methods: [{ adapter_type: "http-api", label: "HTTP API", protocol: "http" }],
  };
  vi.spyOn(apiClient, "GET").mockImplementation(((path: string) => {
    if (path !== "/api/v1/providers/references")
      return Promise.reject(new Error("Unexpected read"));
    return Promise.resolve({
      data: {
        data: [
          {
            id: "provider-1",
            name: "Shared HTTP credentials",
            kind: "target",
            adapter_type: "http-api",
            enabled: true,
            revision: 3,
            access_method_profile: { method: "http" },
          },
        ],
        page: { next: null },
      },
      response: new Response(),
    });
  }) as typeof apiClient.GET);
  return { target, provider, catalog };
}

test("connection check grants nothing until the operator selects allowed capabilities", async () => {
  await i18n.changeLanguage("en");
  const { target, catalog } = fixture();
  const calls: { path: string; options: unknown }[] = [];
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    calls.push({ path, options });
    return Promise.resolve({
      data: {
        data: {
          id: "method-1",
          capabilities: [],
          revision: path.endsWith("/check") ? 3 : 1,
          check: {
            current: path.endsWith("/check"),
            observed_capabilities: ["request.http.observe", "request.http.effect"],
          },
        },
      },
      response: new Response(),
    });
  }) as typeof apiClient.POST);
  vi.spyOn(apiClient, "PATCH").mockImplementation(((path: string, options: unknown) => {
    calls.push({ path, options });
    return Promise.resolve({
      data: {
        data: {
          id: "method-1",
          revision: 4,
          capabilities: ["request.http.observe"],
          check: {
            current: true,
            observed_capabilities: ["request.http.observe", "request.http.effect"],
          },
        },
      },
      response: new Response(),
    });
  }) as typeof apiClient.PATCH);
  const saved = vi.fn(async () => {});
  const error = vi.fn();
  const user = userEvent.setup();
  render(<AccessMethodForm target={target} catalog={catalog} onSaved={saved} onError={error} />);

  await user.click(screen.getByRole("combobox", { name: "Connection" }));
  await user.click(screen.getByRole("option", { name: "Shared HTTP credentials · http-api" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "second device");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://second.example");
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await screen.findByRole("checkbox", { name: "request.http.effect" });
  expect(saved).not.toHaveBeenCalled();
  expect(calls.filter((call) => call.path === "/api/v1/access-methods/{id}")).toEqual([]);
  expect(screen.getByRole("checkbox", { name: "request.http.effect" })).toHaveProperty(
    "checked",
    false,
  );
  await user.click(screen.getByRole("checkbox", { name: "request.http.observe" }));
  await user.click(screen.getByRole("button", { name: "Save access method" }));
  await waitFor(() => expect(saved).toHaveBeenCalledOnce());
  expect(calls).toEqual([
    {
      path: "/api/v1/access-methods",
      options: {
        body: {
          access_method: {
            target_id: "target-1",
            provider_id: "provider-1",
            provider_revision: 3,
            method: "http",
            name: "second device",
            endpoint: "https://second.example",
            priority: 100,
            capabilities: [],
          },
        },
      },
    },
    {
      path: "/api/v1/access-methods/{id}/check",
      options: {
        params: { path: { id: "method-1" } },
        body: { access_method: { expected_revision: 1 } },
      },
    },
    {
      path: "/api/v1/access-methods/{id}",
      options: {
        params: { path: { id: "method-1" } },
        body: { access_method: { expected_revision: 3, capabilities: ["request.http.observe"] } },
      },
    },
  ]);
  expect(error).toHaveBeenLastCalledWith("");
});

test("a first operator adds credentials and an exact Method without leaving the Target", async () => {
  await i18n.changeLanguage("en");
  const { target, provider, catalog } = fixture();
  const registered: unknown[] = [];
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    if (path === "/api/v1/access-methods") registered.push(options);
    const data = path.startsWith("/api/v1/providers")
      ? { ...provider, name: "Edge credentials", enabled: path.endsWith("/enable") }
      : {
          id: "method-1",
          revision: 1,
          capabilities: [],
          check: { current: true, observed_capabilities: [] },
        };
    return Promise.resolve({ data: { data }, response: new Response() });
  }) as typeof apiClient.POST);
  vi.spyOn(apiClient, "PATCH").mockResolvedValue({
    data: {
      data: {
        id: "method-1",
        revision: 2,
        capabilities: [],
        check: { current: true, observed_capabilities: [] },
      },
    },
    response: new Response(),
  } as never);
  const saved = vi.fn(async () => {});
  const user = userEvent.setup();
  render(<AccessMethodForm target={target} catalog={catalog} onSaved={saved} onError={vi.fn()} />);
  await user.click(await screen.findByRole("button", { name: "New connection" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "Edge credentials");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://edge.example");
  await user.type(screen.getByLabelText("Token"), "fixture-private-token");
  await user.click(screen.getByRole("button", { name: "Add Target connection" }));
  await screen.findByRole("button", { name: "Add access method" });
  expect(screen.getByRole("textbox", { name: "Endpoint" })).toHaveProperty(
    "value",
    "https://edge.example",
  );
  expect(screen.queryByLabelText("Token")).toBeNull();
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await waitFor(() => expect(registered).toHaveLength(1));
  await user.click(await screen.findByRole("button", { name: "Save access method" }));
  await waitFor(() => expect(saved).toHaveBeenCalledOnce());
  expect(registered[0]).toEqual({
    body: {
      access_method: {
        target_id: "target-1",
        provider_id: "provider-1",
        provider_revision: 3,
        method: "http",
        name: "Edge credentials",
        endpoint: "https://edge.example",
        priority: 100,
        capabilities: [],
      },
    },
  });
});

test.each([
  { current: false, readFailure: false },
  { current: true, readFailure: false },
  { current: false, readFailure: true },
])("a lost check response retains one Method; state=%o", async ({ current, readFailure }) => {
  await i18n.changeLanguage("en");
  const { target, provider, catalog } = fixture();
  let registrations = 0;
  let checks = 0;
  const record = {
    id: "method-1",
    name: "edge",
    endpoint: "https://edge.example",
    revision: 1,
    capabilities: [],
    check: { current: false, observed_capabilities: [] },
  };
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string) => {
    if (path === "/api/v1/access-methods") {
      registrations++;
      return Promise.resolve({ data: { data: record }, response: new Response() });
    }
    if (++checks === 1) return Promise.reject(new Error("Lost check response"));
    return Promise.resolve({
      data: {
        data: {
          ...record,
          endpoint: "https://current.edge.example",
          revision: 3,
          check: { current: true, observed_capabilities: ["request.http.observe"] },
        },
      },
      response: new Response(),
    });
  }) as typeof apiClient.POST);
  const read = vi.spyOn(apiClient, "GET").mockImplementation(((path: string, options: unknown) => {
    if (path === "/api/v1/providers/references")
      return Promise.resolve({
        data: {
          data: [
            {
              id: provider.id,
              name: provider.name,
              kind: provider.kind,
              adapter_type: provider.adapter_type,
              enabled: true,
              revision: 3,
              access_method_profile: provider.access_method_profile,
            },
          ],
          page: { next: null },
        },
        response: new Response(),
      });
    expect(path).toBe("/api/v1/access-methods/{id}");
    expect(options).toEqual({ params: { path: { id: "method-1" } } });
    if (readFailure) return Promise.reject(new Error("Method storage unavailable"));
    return Promise.resolve({
      data: {
        data: {
          ...record,
          endpoint: "https://current.edge.example",
          revision: 3,
          check: { current, observed_capabilities: ["request.http.observe"] },
        },
      },
      response: new Response(),
    });
  }) as typeof apiClient.GET);
  const saved = vi.fn().mockRejectedValue(new Error("Parent refresh failed"));
  const error = vi.fn();
  const user = userEvent.setup();
  render(<AccessMethodForm target={target} catalog={catalog} onSaved={saved} onError={error} />);
  await user.click(screen.getByRole("combobox", { name: "Connection" }));
  await user.click(screen.getByRole("option", { name: "Shared HTTP credentials · http-api" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "edge");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://edge.example");
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await user.click(await screen.findByRole("button", { name: "Check" }));
  if (readFailure) {
    await waitFor(() => expect(error).toHaveBeenLastCalledWith(i18n.t("targets.requestFailed")));
    expect(screen.queryByRole("checkbox", { name: "request.http.observe" })).toBeNull();
  } else {
    await screen.findByRole("checkbox", { name: "request.http.observe" });
    expect(screen.getByText("edge · https://current.edge.example")).toBeTruthy();
  }
  expect(read).toHaveBeenCalledTimes(2);
  expect(registrations).toBe(1);
  expect(checks).toBe(current || readFailure ? 1 : 2);
  expect(saved).not.toHaveBeenCalled();
});

test("grant response and parent refresh loss do not repeat Method registration or the grant request", async () => {
  await i18n.changeLanguage("en");
  const { target, catalog } = fixture();
  const record = {
    id: "method-1",
    name: "edge",
    endpoint: "https://edge.example",
    revision: 3,
    capabilities: [],
    check: { current: true, observed_capabilities: ["request.http.observe"] },
  };
  let registrations = 0;
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string) => {
    if (path === "/api/v1/access-methods") registrations++;
    return Promise.resolve({ data: { data: record }, response: new Response() });
  }) as typeof apiClient.POST);
  const grant = vi.spyOn(apiClient, "PATCH").mockRejectedValue(new Error("Lost grant response"));
  const saved = vi.fn().mockRejectedValue(new Error("Parent refresh failed"));
  const error = vi.fn();
  const user = userEvent.setup();
  render(<AccessMethodForm target={target} catalog={catalog} onSaved={saved} onError={error} />);
  await user.click(screen.getByRole("combobox", { name: "Connection" }));
  await user.click(screen.getByRole("option", { name: "Shared HTTP credentials · http-api" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "edge");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://edge.example");
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await user.click(await screen.findByRole("checkbox", { name: "request.http.observe" }));
  await user.click(screen.getByRole("button", { name: "Save access method" }));
  await waitFor(() => expect(error).toHaveBeenLastCalledWith(i18n.t("targets.requestFailed")));
  expect(registrations).toBe(1);
  expect(grant).toHaveBeenCalledOnce();
  expect(saved).toHaveBeenCalledOnce();
  expect(screen.queryByRole("button", { name: "Add access method" })).toBeNull();
});

test("later compatible credentials keep their identity and revision while another page is pending", async () => {
  await i18n.changeLanguage("en");
  const { target, catalog } = fixture();
  const reference = (index: number): ProviderReference => ({
    id: `credential-${index}`,
    name: `Credential ${index}`,
    kind: "target",
    adapter_type: "http-api",
    enabled: true,
    revision: 9,
    access_method_profile: { method: "http" },
  });
  const first = {
    data: {
      data: Array.from({ length: 50 }, (_, index) => reference(index + 1)),
      page: { next: "later" as string | null },
    },
    response: new Response(),
  };
  const queries: unknown[] = [];
  const signals: AbortSignal[] = [];
  let firstReads = 0;
  let settle!: (result: typeof first) => void;
  const get = vi.spyOn(apiClient, "GET").mockImplementation(((
    path: string,
    options: {
      params: { query: { after?: string } };
      signal: AbortSignal;
    },
  ) => {
    expect(path).toBe("/api/v1/providers/references");
    queries.push(options.params.query);
    signals.push(options.signal);
    if (options.params.query.after)
      return Promise.resolve({
        data: { data: [reference(51)], page: { next: null } },
        response: new Response(),
      });
    if (++firstReads === 2)
      return new Promise<typeof first>((resolve) => {
        settle = resolve;
      });
    return Promise.resolve(first);
  }) as typeof apiClient.GET);
  const post = vi.spyOn(apiClient, "POST").mockImplementation(((path: string) =>
    Promise.resolve({
      data: {
        data: {
          id: "registered",
          name: "Chosen method",
          endpoint: "https://device.example",
          revision: path.endsWith("check") ? 2 : 1,
          capabilities: [],
          check: {
            current: path.endsWith("check"),
            observed_capabilities: ["request.http.observe"],
          },
        },
      },
      response: new Response(),
    })) as typeof apiClient.POST);
  render(
    <AccessMethodForm target={target} catalog={catalog} onSaved={vi.fn()} onError={vi.fn()} />,
  );
  const user = userEvent.setup();
  const group = screen.getByRole("group", { name: "Connection" });
  await waitFor(() =>
    expect(within(group).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(group).getByRole("combobox"));
  expect(screen.getAllByRole("option")).toHaveLength(50);
  expect(screen.queryByRole("option", { name: "Credential 51 · http-api" })).toBeNull();
  await user.keyboard("{Escape}");
  get.mockRejectedValueOnce(new Error("Choices unavailable"));
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await within(group).findByRole("alert");
  await user.click(within(group).getByRole("button", { name: "Refresh" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(group).getByRole("combobox"));
  expect(screen.getAllByRole("option")).toHaveLength(1);
  await user.click(screen.getByRole("option", { name: "Credential 51 · http-api" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "Chosen method");
  await user.type(screen.getByRole("textbox", { name: "Endpoint" }), "https://device.example");
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  expect(within(group).getByRole("combobox")).toHaveProperty("disabled", true);
  await user.click(screen.getByRole("button", { name: "Add access method" }));
  await screen.findByRole("checkbox", { name: "request.http.observe" });
  expect(post).toHaveBeenCalledWith("/api/v1/access-methods", {
    body: {
      access_method: {
        target_id: "target-1",
        provider_id: "credential-51",
        provider_revision: 9,
        name: "Chosen method",
        endpoint: "https://device.example",
        priority: 100,
        capabilities: [],
        method: "http",
      },
    },
  });
  expect(post).toHaveBeenCalledTimes(2);
  expect(queries).toEqual([
    { kind: "target", enabled: true, adapter_types: ["http-api"], limit: 50, after: undefined },
    { kind: "target", enabled: true, adapter_types: ["http-api"], limit: 50, after: "later" },
    { kind: "target", enabled: true, adapter_types: ["http-api"], limit: 50, after: undefined },
  ]);
  expect(signals.at(-1)?.aborted).toBe(true);
  await act(async () => settle(first));
  expect(screen.queryByRole("combobox")).toBeNull();
  expect(post).toHaveBeenCalledTimes(2);
});
