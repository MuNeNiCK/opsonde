import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import type { components } from "@/api/schema";
import i18n from "@/i18n/config";
import { TargetImportPage } from "@/targets/import-page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
afterEach(() => {
  cleanup();
  wire.mockReset();
});
function imported(index: number): components["schemas"]["InventoryImport"] {
  return {
    id: `import-${index}`,
    source: `Import ${index}`,
    source_type: "manual",
    status: "previewed",
    snapshot_status: null,
    source_version: null,
    content_digest: "a".repeat(64),
    row_count: 101,
    error_count: 0,
    provider_id: null,
    created_by_id: "admin",
    revision: 3,
    applied_at: null,
    inserted_at: "2026-10-04T00:00:00Z",
    updated_at: "2026-10-04T00:00:00Z",
  };
}
function row(index: number) {
  return {
    id: `row-${index}`,
    position: index,
    identity_value: `Asset ${index}`,
    disposition: "create",
    errors: [],
  };
}
function page(data: unknown[], next: string | null = null) {
  return Response.json({ data, page: { next } });
}
function show(role = "viewer") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter initialEntries={["/targets/imports"]}>
        <TargetImportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}

test("Import history and selected preview rows page independently without global snapshots", async () => {
  await i18n.changeLanguage("en");
  const requests: URL[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    requests.push(url);
    if (url.pathname === "/api/v1/inventory-imports") {
      expect(url.searchParams.get("limit")).toBe("50");
      return Promise.resolve(
        url.searchParams.has("after")
          ? page([imported(51)])
          : page(
              Array.from({ length: 50 }, (_, index) => imported(index + 1)),
              "history-cursor",
            ),
      );
    }
    if (url.pathname.endsWith("/rows/summaries")) {
      expect(url.searchParams.get("limit")).toBe("50");
      const different = url.pathname.includes("import-51");
      return Promise.resolve(
        url.searchParams.has("after") || different
          ? page([row(different ? 999 : 51)])
          : page(
              Array.from({ length: 50 }, (_, index) => row(index + 1)),
              "rows-cursor",
            ),
      );
    }
    if (url.pathname === "/api/v1/inventory-imports/import-1")
      return Promise.resolve(Response.json({ data: imported(1) }));
    if (url.pathname === "/api/v1/inventory-imports/import-51")
      return Promise.resolve(Response.json({ data: imported(51) }));
    return Promise.resolve(Response.json({}, { status: 404 }));
  });
  show();
  const history = await screen.findByRole("region", { name: "Import history" });
  const preview = screen.getByRole("region", { name: "Import preview" });
  await within(preview).findByText("Asset 50");
  expect(screen.getByText("101 rows · 0 errors")).toBeTruthy();
  expect(requests).toHaveLength(3);
  const user = userEvent.setup();
  await user.click(within(preview).getByRole("button", { name: "Next" }));
  await within(preview).findByText("Asset 51");
  expect(within(preview).queryByText("Asset 1")).toBeNull();
  await user.click(within(history).getByRole("button", { name: "Next" }));
  await within(history).findByRole("button", { name: /Import 51/ });
  expect(within(preview).getByText("Asset 51")).toBeTruthy();
  await user.click(within(history).getByRole("button", { name: /Import 51/ }));
  await within(preview).findByText("Asset 999");
  expect(within(preview).queryByText("Asset 51")).toBeNull();
});

test("Inventory Provider choices past the first page send their exact current revision", async () => {
  await i18n.changeLanguage("en");
  const provider = (index: number) => ({
    id: `provider-${index}`,
    name: `Provider ${index}`,
    kind: "inventory",
    adapter_type: "netbox",
    revision: 7,
    enabled: true,
    check: {
      status: "passed",
      checked_revision: 7,
      category: null,
      message: null,
      checked_at: null,
    },
  });
  const posted: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/providers/summaries") {
      expect(url.searchParams.get("kinds")).toBe("inventory");
      expect(url.searchParams.get("eligible")).toBe("true");
      expect(url.searchParams.get("limit")).toBe("50");
      return url.searchParams.has("after")
        ? page([provider(51)])
        : page(
            Array.from({ length: 50 }, (_, i) => provider(i + 1)),
            "providers-cursor",
          );
    }
    if (request.method === "POST") {
      posted.push(await request.json());
      return Response.json({ data: imported(999) }, { status: 201 });
    }
    if (url.pathname.endsWith("/rows/summaries")) return page([row(999)]);
    if (url.pathname.endsWith("/import-999")) return Response.json({ data: imported(999) });
    expect(url.pathname).toBe("/api/v1/inventory-imports");
    return page([]);
  });
  show("admin");
  const user = userEvent.setup();
  const choices = await screen.findByRole("group", { name: "Connection" });
  await waitFor(() =>
    expect(within(choices).getByRole("button", { name: "Next" })).toHaveProperty("disabled", false),
  );
  await user.click(within(choices).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(choices).getByRole("combobox")).toHaveProperty("disabled", false),
  );
  await user.click(within(choices).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Provider 51" }));
  const form = choices.closest("form")!;
  await waitFor(() =>
    expect(within(choices).getByRole("combobox").textContent).toContain("Provider 51"),
  );
  expect(within(form).getByRole("button", { name: "Preview" })).toHaveProperty("disabled", false);
  expect(form.checkValidity()).toBe(true);
  await user.click(within(form).getByRole("button", { name: "Preview" }));
  await waitFor(() => expect(posted).toHaveLength(1));
  await screen.findByText("Asset 999");
  expect(posted).toEqual([
    {
      inventory_import: {
        source: "netbox",
        provider_id: "provider-51",
        provider_revision: 7,
        scope: { resource: "devices", filters: {}, page_size: 50 },
      },
    },
  ]);
});

test("Accepted preview identity survives failed history refresh and a lost apply acknowledgement is recovered by reads", async () => {
  await i18n.changeLanguage("en");
  let stored = imported(999);
  let failHistory = false;
  const posts: Array<{ path: string; body: unknown }> = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posts.push({ path: url.pathname, body: await request.json() });
      if (url.pathname.endsWith("/apply")) {
        stored = { ...stored, status: "applied", revision: 4 };
        throw new Error("lost apply acknowledgement");
      }
      failHistory = true;
      return Response.json({ data: stored }, { status: 201 });
    }
    if (url.pathname === "/api/v1/providers/summaries") return page([]);
    if (url.pathname === "/api/v1/inventory-imports")
      return failHistory
        ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
        : page([]);
    if (url.pathname.endsWith("/rows/summaries"))
      return url.searchParams.has("after") ? page([row(51)]) : page([row(1)], "rows-cursor");
    expect(url.pathname).toBe("/api/v1/inventory-imports/import-999");
    return Response.json({ data: stored });
  });
  show("admin");
  const user = userEvent.setup();
  const form = screen.getByRole("textbox", { name: "CSV" }).closest("form")!;
  await user.type(within(form).getByRole("textbox", { name: "Source" }), "manual-source");
  await user.type(within(form).getByRole("textbox", { name: "CSV" }), "fixture-csv");
  await user.click(within(form).getByRole("button", { name: "Preview" }));
  await screen.findByText(i18n.t("targets.requestFailed"));
  const preview = screen.getByRole("region", { name: "Import preview" });
  await within(preview).findByText("Asset 1");
  expect(screen.getByText("101 rows · 0 errors")).toBeTruthy();
  expect(posts).toEqual([
    {
      path: "/api/v1/inventory-imports/manual-preview",
      body: { inventory_import: { source: "manual-source", csv: "fixture-csv" } },
    },
  ]);
  await user.click(within(preview).getByRole("button", { name: "Next" }));
  await within(preview).findByText("Asset 51");
  await user.click(screen.getByRole("button", { name: "Apply import" }));
  await waitFor(() => expect(posts).toHaveLength(2));
  expect(posts[1]).toEqual({
    path: "/api/v1/inventory-imports/import-999/apply",
    body: { inventory_import: { expected_revision: 3, expected_digest: "a".repeat(64) } },
  });
  failHistory = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(screen.queryByRole("button", { name: "Apply import" })).toBeNull());
  expect(posts).toHaveLength(2);
  expect(within(preview).getByText("Asset 51")).toBeTruthy();
});

test("Changing imports aborts old reads and failed new rows never display old rows or false emptiness", async () => {
  await i18n.changeLanguage("en");
  let finishHeader!: (value: Response) => void;
  let finishRows!: (value: Response) => void;
  const old: Request[] = [];
  let failRows = true;
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/inventory-imports")
      return Promise.resolve(page([imported(1), imported(2)]));
    if (url.pathname.includes("import-1")) {
      old.push(request);
      return new Promise<Response>((resolve) => {
        if (url.pathname.endsWith("/summaries")) finishRows = resolve;
        else finishHeader = resolve;
      });
    }
    if (url.pathname.endsWith("/summaries"))
      return Promise.resolve(
        failRows
          ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
          : page([row(200)]),
      );
    return Promise.resolve(Response.json({ data: imported(2) }));
  });
  show();
  await waitFor(() => expect(old).toHaveLength(2));
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: /Import 2/ }));
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(old.every((request) => request.signal.aborted)).toBe(true);
  await act(async () => {
    finishHeader(Response.json({ data: imported(1) }));
    finishRows(page([row(1)]));
  });
  expect(screen.queryByText("Asset 1")).toBeNull();
  expect(screen.queryByText(i18n.t("targets.noImportRows"))).toBeNull();
  failRows = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Asset 200");
  expect(screen.queryByText("Asset 1")).toBeNull();
});

test("Initial history failure has a visible retry and leaving a pending preview sends no follow-up reads", async () => {
  await i18n.changeLanguage("en");
  let failHistory = true;
  let finish!: (value: Response) => void;
  const requests: Request[] = [];
  wire.mockImplementation((request: Request) => {
    requests.push(request);
    if (request.method === "POST")
      return new Promise<Response>((resolve) => {
        finish = resolve;
      });
    if (new URL(request.url).pathname === "/api/v1/providers/summaries")
      return Promise.resolve(page([]));
    return Promise.resolve(
      failHistory
        ? Response.json({ error: { code: "internal_error" } }, { status: 500 })
        : page([]),
    );
  });
  const view = show("admin");
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(screen.queryByText(i18n.t("targets.noImports"))).toBeNull();
  const user = userEvent.setup();
  failHistory = false;
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText(i18n.t("targets.noImports"));
  const form = screen.getByRole("textbox", { name: "CSV" }).closest("form")!;
  await user.type(within(form).getByRole("textbox", { name: "Source" }), "source");
  await user.type(within(form).getByRole("textbox", { name: "CSV" }), "fixture");
  await user.click(within(form).getByRole("button", { name: "Preview" }));
  await waitFor(() => expect(requests.at(-1)?.method).toBe("POST"));
  const before = requests.length;
  view.unmount();
  await act(async () => {
    finish(Response.json({ data: imported(999) }, { status: 201 }));
  });
  expect(requests).toHaveLength(before);
});

test("A missing selected import is an error and cannot be applied from history metadata", async () => {
  await i18n.changeLanguage("en");
  let missing = true;
  const posts: Request[] = [];
  wire.mockImplementation((request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") posts.push(request);
    if (url.pathname === "/api/v1/providers/summaries") return Promise.resolve(page([]));
    if (url.pathname === "/api/v1/inventory-imports") return Promise.resolve(page([imported(1)]));
    if (url.pathname.endsWith("/rows/summaries")) return Promise.resolve(page([row(1)]));
    expect(url.pathname).toBe("/api/v1/inventory-imports/import-1");
    return Promise.resolve(
      missing
        ? Response.json({ error: { code: "not_found" } }, { status: 404 })
        : Response.json({ data: imported(1) }),
    );
  });
  show("admin");
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(screen.queryByRole("button", { name: "Apply import" })).toBeNull();
  expect(screen.queryByText("Asset 1")).toBeNull();
  expect(screen.queryByText(i18n.t("targets.noImportRows"))).toBeNull();
  missing = false;
  await userEvent.setup().click(screen.getByRole("button", { name: "Refresh" }));
  await screen.findByText("Asset 1");
  expect(screen.getByRole("button", { name: "Apply import" })).toHaveProperty("disabled", false);
  expect(posts).toHaveLength(0);
});
