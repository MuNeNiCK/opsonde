import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import { CaseCreatePage } from "@/cases/create-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
const target = (index: number) => ({
  id: `target-${index}`,
  name: `Target ${index}`,
  active: true,
  kind: "host",
  type_id: "custom-os",
  revision: 1,
  management_boundary_id: null,
  method_count: 0,
  methods: [],
  relationship_count: 0,
  has_operating_instructions: false,
});
function showCase(query = "", role = "operator") {
  return render(
    <AuthenticationContext.Provider value={{ account: { role } } as Authentication}>
      <MemoryRouter initialEntries={[`/cases/new${query}`]}>
        <Routes>
          <Route path="/cases/new" element={<CaseCreatePage />} />
          <Route path="/cases/:id" element={<p>Case created</p>} />
        </Routes>
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
}
afterEach(() => {
  cleanup();
  wire.mockReset();
  vi.restoreAllMocks();
});

test("Manual Case Target choice reaches the next page and retains its selection when paging back", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  let submitted: Record<string, unknown> | undefined;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/targets/summaries") {
      reads.push(url);
      return Response.json({
        data: url.searchParams.has("ids")
          ? [target(51)]
          : url.searchParams.has("after")
            ? [target(51)]
            : Array.from({ length: 50 }, (_, i) => target(i + 1)),
        page: {
          next:
            url.searchParams.has("after") || url.searchParams.has("ids") ? null : "target-cursor",
        },
      });
    }
    if (url.pathname.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    if (url.pathname === "/api/v1/cases") {
      submitted = (await request.json()).case;
      return Response.json({ data: { id: "case-51" } });
    }
    throw Error("Unexpected request");
  });
  showCase();
  const user = userEvent.setup();
  const choice = await screen.findByRole("combobox", { name: i18n.t("cases.initialTarget") });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await screen.findByRole("option", { name: "Target 50" });
  expect(screen.queryByRole("option", { name: "Target 51" })).toBeNull();
  await user.keyboard("{Escape}");
  expect(reads).toHaveLength(1);
  expect(reads[0].pathname).toBe("/api/v1/targets/summaries");
  expect(reads[0].searchParams.get("limit")).toBe("50");
  expect(reads[0].searchParams.get("active")).toBe("true");
  const group = screen.getByRole("group", { name: i18n.t("cases.initialTarget") });
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Target 51" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("Target 51"),
  );
  await user.type(screen.getByLabelText("Title"), "Investigate chosen Target");
  await user.type(screen.getByLabelText("Desired outcome"), "Restore service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(submitted?.initial_target_id).toBe("target-51");
  expect(submitted?.initial_context).toEqual({ desired_outcome: "Restore service" });
});

test("Manual Case linked Target is resolved outside its current page and rechecked before submission", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  let submitted: Record<string, unknown> | undefined;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/targets/summaries") {
      reads.push(url);
      return Response.json({
        data: url.searchParams.has("ids")
          ? [target(999)]
          : Array.from({ length: 50 }, (_, i) => target(i + 1)),
        page: { next: url.searchParams.has("ids") ? null : "target-cursor" },
      });
    }
    if (url.pathname.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    if (url.pathname === "/api/v1/cases") {
      submitted = (await request.json()).case;
      return Response.json({ data: { id: "case-999" } });
    }
    throw Error("Unexpected request");
  });
  showCase("?target=target-999");
  await screen.findByText("Target 999");
  expect(reads.filter((url) => !url.searchParams.has("ids"))).toHaveLength(1);
  expect(reads.find((url) => url.searchParams.has("ids"))?.searchParams.get("ids")).toBe(
    "target-999",
  );
  expect(reads.find((url) => url.searchParams.has("ids"))?.searchParams.get("limit")).toBe("1");
  const user = userEvent.setup();
  await user.type(screen.getByLabelText("Title"), "Investigate linked Target");
  await user.type(screen.getByLabelText("Desired outcome"), "Restore service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(reads.filter((url) => url.searchParams.get("ids") === "target-999")).toHaveLength(2);
  expect(submitted?.initial_target_id).toBe("target-999");
});

test("Manual Case distinguishes a failed Target read from a missing or inactive Target and permits clearing it", async () => {
  await i18n.changeLanguage("en");
  let outcome = "failed";
  const writes: Record<string, unknown>[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/targets/summaries") {
      if (!url.searchParams.has("ids")) return Response.json({ data: [], page: { next: null } });
      if (outcome === "failed")
        return Response.json({ error: { code: "failed" } }, { status: 503 });
      return Response.json({
        data: outcome === "missing" ? [] : [{ ...target(999), active: outcome !== "inactive" }],
        page: { next: null },
      });
    }
    if (url.pathname.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    if (url.pathname === "/api/v1/cases") {
      writes.push((await request.json()).case);
      return Response.json({ data: { id: "case-without-target" } });
    }
    throw Error("Unexpected request");
  });
  showCase("?target=target-999");
  await screen.findByText(i18n.t("targets.requestFailed"));
  expect(screen.queryByText(i18n.t("targets.targetNotFound"))).toBeNull();
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  const user = userEvent.setup();
  for (const next of ["missing", "inactive"]) {
    outcome = next;
    const refresh = screen.getAllByRole("button", { name: "Refresh" })[0];
    await user.click(refresh);
    await screen.findByText(i18n.t("targets.targetNotFound"));
    expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  }
  outcome = "ready";
  await user.click(screen.getAllByRole("button", { name: "Refresh" })[0]);
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
  expect(writes).toEqual([]);
  await user.click(screen.getByRole("button", { name: "No target selected" }));
  expect(screen.queryByRole("group", { name: i18n.t("files.select") })).toBeNull();
  await user.type(screen.getByLabelText("Title"), "Investigate unspecified Target");
  await user.type(screen.getByLabelText("Desired outcome"), "Find the failing service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findByText("Case created");
  expect(writes).toHaveLength(1);
  expect(writes[0].initial_target_id).toBeNull();
});

test("An older selected Target read cannot overwrite the inactive Target found by the submission recheck", async () => {
  await i18n.changeLanguage("en");
  let knownReads = 0;
  let held: Request | undefined;
  let finish: (value: Response) => void = () => {};
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method !== "GET") writes.push(request.method);
    if (url.pathname === "/api/v1/targets/summaries") {
      if (!url.searchParams.has("ids"))
        return Response.json({ data: [target(1)], page: { next: null } });
      knownReads += 1;
      if (knownReads === 1) {
        held = request;
        return new Promise<Response>((resolve) => {
          finish = resolve;
        });
      }
      return Response.json({ data: [{ ...target(1), active: false }], page: { next: null } });
    }
    if (url.pathname.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    throw Error("Unexpected request");
  });
  showCase();
  const user = userEvent.setup();
  const choice = screen.getByRole("combobox", { name: i18n.t("cases.initialTarget") });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Target 1" }));
  await waitFor(() => expect(held).toBeDefined());
  await user.type(screen.getByLabelText("Title"), "Investigate selected Target");
  await user.type(screen.getByLabelText("Desired outcome"), "Restore service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await screen.findAllByText(i18n.t("targets.targetNotFound"));
  await act(async () => {
    finish(Response.json({ data: [target(1)], page: { next: null } }));
  });
  expect(screen.getByRole("button", { name: "Create Case" }).hasAttribute("disabled")).toBe(true);
  expect(held!.signal.aborted).toBe(true);
  expect(writes).toEqual([]);
});

test("Leaving manual Case creation releases the Target recheck and prevents a later submission", async () => {
  await i18n.changeLanguage("en");
  let knownReads = 0;
  let held: Request | undefined;
  let finish: (value: Response) => void = () => {};
  const writes: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method !== "GET") writes.push(request.method);
    if (url.pathname === "/api/v1/targets/summaries") {
      if (url.searchParams.has("ids")) {
        knownReads += 1;
        if (knownReads > 1) {
          held = request;
          return new Promise<Response>((resolve) => {
            finish = resolve;
          });
        }
        return Response.json({ data: [target(999)], page: { next: null } });
      }
      return Response.json({ data: [], page: { next: null } });
    }
    if (url.pathname.endsWith("/files")) return Response.json({ data: [], page: { next: null } });
    throw Error("Unexpected request");
  });
  const view = showCase("?target=target-999");
  await screen.findByText("Target 999");
  const user = userEvent.setup();
  await user.type(screen.getByLabelText("Title"), "Investigate linked Target");
  await user.type(screen.getByLabelText("Desired outcome"), "Restore service");
  await user.click(screen.getByRole("button", { name: "Create Case" }));
  await waitFor(() => expect(held).toBeDefined());
  view.unmount();
  expect(held!.signal.aborted).toBe(true);
  await act(async () => {
    finish(Response.json({ data: [target(999)], page: { next: null } }));
  });
  expect(writes).toEqual([]);
});
