import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { apiClient } from "@/api/client";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { TargetCreatePage } from "@/targets/create-page";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

test("lists published types, filters categories, and creates the selected type", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const requests: unknown[] = [];

  vi.spyOn(apiClient, "GET").mockImplementation(((path: string) =>
    Promise.resolve({
      data:
        path === "/api/v1/target-types"
          ? {
              data: {
                categories: [
                  { id: "os", label: "Operating system" },
                  { id: "network-device", label: "Network device" },
                  { id: "storage", label: "Storage" },
                ],
                types: [
                  {
                    id: "linux",
                    label: "Linux",
                    kind: "host",
                    category_id: "os",
                    access_method_types: ["linux-ssh"],
                  },
                  {
                    id: "custom-network-device",
                    label: "Custom network device",
                    kind: "network_device",
                    category_id: "network-device",
                    access_method_types: ["ssh"],
                  },
                ],
              },
            }
          : { data: [], page: { next: null } },
      response: new Response(),
    })) as typeof apiClient.GET);

  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    requests.push({ path, options });
    return Promise.resolve({ data: { data: { id: "target-1" } }, response: new Response() });
  }) as typeof apiClient.POST);

  render(
    <AuthenticationContext.Provider value={{ account: { role: "admin" } } as Authentication}>
      <MemoryRouter initialEntries={["/targets/new"]}>
        <Routes>
          <Route path="/targets/new" element={<TargetCreatePage />} />
          <Route path="/targets/new/:targetType" element={<TargetCreatePage />} />
          <Route path="/targets/:targetId" element={<p>Target saved</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );

  expect(await screen.findByText("Linux")).toBeTruthy();
  expect(screen.getByText("Custom network device")).toBeTruthy();
  expect(screen.getByRole("combobox", { name: "Filter by category" })).toBeTruthy();

  await user.click(screen.getByRole("combobox", { name: "Filter by category" }));
  await user.click(screen.getByRole("option", { name: "Network device" }));
  expect(screen.queryByText("Linux")).toBeNull();
  expect(screen.getByText("Custom network device")).toBeTruthy();

  await user.click(screen.getByText("Custom network device"));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "edge-1");
  await user.click(screen.getByRole("button", { name: "Add attribute" }));
  await user.type(screen.getByRole("textbox", { name: "Attribute name" }), "manufacturer");
  await user.type(screen.getByRole("textbox", { name: "Attribute value" }), "UnlistedVendor");
  await user.click(screen.getByRole("button", { name: "Add Target" }));

  await waitFor(() => expect(screen.getByText("Target saved")).toBeTruthy());
  expect(requests).toEqual([
    {
      path: "/api/v1/targets",
      options: {
        body: {
          target: {
            name: "edge-1",
            kind: "network_device",
            type_id: "custom-network-device",
            facts: { manufacturer: "UnlistedVendor" },
            management_boundary_id: null,
          },
        },
      },
    },
  ]);
});

test.each([false, true])(
  "boundary paging preserves selected identity and handles failure=%s",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: Array<string | null> = [];
    const saves: unknown[] = [];
    const signals: Array<AbortSignal | undefined> = [];
    let failNext = fails;
    let firstReads = 0;
    const first = { id: "boundary-first", name: "First boundary", active: true };
    const last = { id: "boundary-later", name: "Later boundary", active: true };
    const firstPage = [
      first,
      ...Array.from({ length: 49 }, (_, index) => ({
        id: `boundary-${index}`,
        name: `Boundary ${index}`,
        active: true,
      })),
    ];
    const firstResponse = {
      data: { data: firstPage, page: { next: "later-cursor" as string | null } },
      response: new Response(),
    };
    let delayed: ((value: typeof firstResponse) => void) | undefined;
    vi.spyOn(apiClient, "GET").mockImplementation(((
      path: string,
      options?: { params?: { query?: { after?: string; limit: number } }; signal?: AbortSignal },
    ) => {
      if (path === "/api/v1/target-types")
        return Promise.resolve({
          data: {
            data: {
              categories: [{ id: "os", label: "Operating system" }],
              types: [
                {
                  id: "linux",
                  label: "Linux",
                  kind: "host",
                  category_id: "os",
                  access_method_types: ["linux-ssh"],
                },
              ],
              methods: [],
            },
          },
          response: new Response(),
        });
      expect(options?.params?.query?.limit).toBe(50);
      const after = options?.params?.query?.after ?? null;
      requests.push(after);
      signals.push(options?.signal);
      if (after && failNext) {
        failNext = false;
        return Promise.reject(new Error("Boundary page failed"));
      }
      const result = {
        data: { data: after ? [last] : firstPage, page: { next: after ? null : "later-cursor" } },
        response: new Response(),
      };
      if (!after && ++firstReads === 2)
        return new Promise<typeof firstResponse>((resolve) => {
          delayed = resolve;
        });
      return Promise.resolve(result);
    }) as typeof apiClient.GET);
    vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
      saves.push({ path, options });
      return Promise.resolve({
        data: { data: { id: "target-created" } },
        response: new Response(),
      });
    }) as typeof apiClient.POST);
    const user = userEvent.setup();
    render(
      <AuthenticationContext.Provider value={{ account: { role: "admin" } } as Authentication}>
        <MemoryRouter initialEntries={["/targets/new/linux"]}>
          <Routes>
            <Route path="/targets/new/:targetType" element={<TargetCreatePage />} />
            <Route path="/targets/:targetId" element={<p>Target saved</p>} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    await screen.findByRole("button", { name: "Next" });
    expect(requests).toEqual([null]);
    await user.click(screen.getByRole("combobox", { name: "Management boundary" }));
    expect(screen.getAllByRole("option")).toHaveLength(50);
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: "Next" }));
    if (fails) {
      await screen.findByText(i18n.t("targets.requestFailed"));
      expect(screen.getByText("Page 1")).toBeTruthy();
      await user.click(screen.getByRole("button", { name: "Next" }));
    }
    await screen.findByText("Page 2");
    await user.click(screen.getByRole("combobox", { name: "Management boundary" }));
    expect(screen.getAllByRole("option")).toHaveLength(1);
    expect(screen.queryByRole("option", { name: "First boundary" })).toBeNull();
    await user.click(screen.getByRole("option", { name: "Later boundary" }));
    await user.click(screen.getByRole("button", { name: "Previous" }));
    await waitFor(() => expect(delayed).toBeDefined());
    expect(screen.getByRole("combobox", { name: "Management boundary" }).textContent).toContain(
      "Later boundary",
    );
    if (!fails) {
      await act(async () => delayed?.(firstResponse));
      await screen.findByText("Page 1");
      await user.click(screen.getByRole("combobox", { name: "Management boundary" }));
      expect(screen.getAllByRole("option")).toHaveLength(51);
      await user.keyboard("{Escape}");
    }
    expect(screen.getByRole("combobox", { name: "Management boundary" }).textContent).toContain(
      "Later boundary",
    );
    await user.type(screen.getByRole("textbox", { name: "Name" }), "paged-host");
    await user.click(screen.getByRole("button", { name: "Add Target" }));
    await screen.findByText("Target saved");
    if (fails) {
      expect(signals.at(-1)?.aborted).toBe(true);
      await act(async () => delayed?.(firstResponse));
      expect(screen.getByText("Target saved")).toBeTruthy();
      expect(screen.queryByRole("combobox", { name: "Management boundary" })).toBeNull();
    }
    expect(saves).toEqual([
      {
        path: "/api/v1/targets",
        options: {
          body: {
            target: {
              name: "paged-host",
              kind: "host",
              type_id: "linux",
              facts: {},
              management_boundary_id: "boundary-later",
            },
          },
        },
      },
    ]);
    expect(requests).toEqual(
      fails ? [null, "later-cursor", "later-cursor", null] : [null, "later-cursor", null],
    );
  },
);

test("a newly created boundary is selected without reloading global pages", async () => {
  await i18n.changeLanguage("en");
  let boundaryReads = 0;
  const writes: Array<{ path: string; options: unknown }> = [];
  vi.spyOn(apiClient, "GET").mockImplementation(((path: string) => {
    if (path === "/api/v1/target-types")
      return Promise.resolve({
        data: {
          data: {
            categories: [{ id: "os", label: "Operating system" }],
            types: [
              {
                id: "linux",
                label: "Linux",
                kind: "host",
                category_id: "os",
                access_method_types: ["linux-ssh"],
              },
            ],
            methods: [],
          },
        },
        response: new Response(),
      });
    boundaryReads++;
    return Promise.resolve({
      data: { data: [], page: { next: "unloaded-later-page" } },
      response: new Response(),
    });
  }) as typeof apiClient.GET);
  vi.spyOn(apiClient, "POST").mockImplementation(((path: string, options: unknown) => {
    writes.push({ path, options });
    return Promise.resolve({
      data: {
        data:
          path === "/api/v1/management-boundaries"
            ? {
                id: "created-boundary",
                name: "New datacenter",
                active: true,
                facts: { payload: "x".repeat(65522) },
              }
            : { id: "created-target" },
      },
      response: new Response(),
    });
  }) as typeof apiClient.POST);
  const user = userEvent.setup();
  render(
    <AuthenticationContext.Provider value={{ account: { role: "admin" } } as Authentication}>
      <MemoryRouter initialEntries={["/targets/new/linux"]}>
        <Routes>
          <Route path="/targets/new/:targetType" element={<TargetCreatePage />} />
          <Route path="/targets/:targetId" element={<p>Target saved</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await user.click(await screen.findByRole("button", { name: "Add management boundary" }));
  await user.type(screen.getByRole("textbox", { name: "Name" }), "New datacenter");
  await user.type(screen.getByRole("textbox", { name: "Kind" }), "datacenter");
  await user.click(screen.getByRole("button", { name: "Add management boundary" }));
  await screen.findByText(i18n.t("targets.boundaryCreated"));
  expect(screen.getByRole("combobox", { name: "Management boundary" }).textContent).toContain(
    "New datacenter",
  );
  expect(boundaryReads).toBe(1);
  await user.type(screen.getByRole("textbox", { name: "Name" }), "created-host");
  await user.click(screen.getByRole("button", { name: "Add Target" }));
  await screen.findByText("Target saved");
  expect(writes).toEqual([
    {
      path: "/api/v1/management-boundaries",
      options: {
        body: { management_boundary: { name: "New datacenter", kind: "datacenter", facts: {} } },
      },
    },
    {
      path: "/api/v1/targets",
      options: {
        body: {
          target: {
            name: "created-host",
            kind: "host",
            type_id: "linux",
            facts: {},
            management_boundary_id: "created-boundary",
          },
        },
      },
    },
  ]);
});
