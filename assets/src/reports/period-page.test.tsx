import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Link, MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import type { components } from "@/api/schema";
import { PeriodReportPage } from "@/reports/period-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
const firstId = "00000000-0000-4000-8000-000000000001";
const tailId = "00000000-0000-4000-8000-000000000002";
const linkedId = "00000000-0000-4000-8000-000000000003";
const summary: components["schemas"]["PeriodSummary"] = {
  from: "2026-10-01T00:00:00Z",
  to: "2026-10-05T00:00:00Z",
  as_of: "2026-10-05T00:00:00Z",
  target_id: linkedId,
  case_count: 0,
  audit_count: 0,
  case_status: { resolved: 0, running: 0, needs_attention: 0, cancelled: 0 },
  case_trigger: { manual: 0, signal: 0, audit: 0 },
  audit_status: { cancelled: 0, case_opened: 0, failed: 0, queued: 0, running: 0, skipped: 0 },
  recovery: { average_seconds: null, measured_cases: 0, unmeasured_resolved_cases: 0 },
  cases: [],
  audits: [],
  daily: [],
  case_sources_truncated: false,
  audit_sources_truncated: false,
};
const target = (id: string, name: string) => ({
  id,
  name,
  type_id: "custom-os",
  kind: "host",
  active: false,
  revision: 1,
  management_boundary_id: null,
  method_count: 0,
  methods: [],
  relationship_count: 0,
  has_operating_instructions: false,
});
function renderPeriod(print = false) {
  return render(
    <MemoryRouter
      initialEntries={[`/reports/operations?from=2026-10-01&to=2026-10-04&target=${linkedId}`]}
    >
      <Link to={`/reports/operations?from=2026-10-01&to=2026-10-04&target=${tailId}`}>
        Other period
      </Link>
      <PeriodReportPage print={print} />
    </MemoryRouter>,
  );
}

test("period Target choices retain a linked identity outside the current fifty-item page", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const queries: URL[] = [];
  const first = Array.from({ length: 50 }, (_, index) =>
    target(
      index === 0 ? firstId : `10000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      `Member ${index}`,
    ),
  );
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    expect(request.method).toBe("GET");
    queries.push(url);
    if (url.pathname === "/api/v1/reports/operations-summary")
      return new Response(
        JSON.stringify({ data: { ...summary, target_id: url.searchParams.get("target_id") } }),
      );
    expect(url.pathname).toBe("/api/v1/targets/summaries");
    expect(url.searchParams.has("active")).toBe(false);
    const ids = url.searchParams.get("ids");
    if (ids)
      return new Response(
        JSON.stringify({
          data: ids
            .split(",")
            .map((id) => target(id, id === linkedId ? "Linked host" : "Tail host")),
          page: { next: null },
        }),
      );
    expect(url.searchParams.get("limit")).toBe("50");
    return new Response(
      JSON.stringify(
        url.searchParams.has("after")
          ? { data: [target(tailId, "Tail host")], page: { next: null } }
          : { data: first, page: { next: "target-next" } },
      ),
    );
  });
  renderPeriod();
  const combo = screen.getByRole("combobox");
  await waitFor(() => expect(combo.textContent).toContain("Linked host"));
  const group = screen.getByRole("group", { name: "Target" });
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await within(group).findByText("Page 2");
  await user.click(combo);
  await user.click(await screen.findByRole("option", { name: "Tail host" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await within(group).findByText("Page 1");
  expect(screen.getByRole("combobox").textContent).toContain("Tail host");
  expect(screen.getAllByRole("article", { name: "Period report" })[0]!.textContent).toContain(
    "Linked host",
  );
  await user.click(screen.getByRole("button", { name: "Show summary" }));
  await waitFor(() =>
    expect(screen.getAllByRole("article", { name: "Period report" })[0]!.textContent).toContain(
      "Tail host",
    ),
  );
  await user.click(screen.getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "All targets" }));
  await user.click(screen.getByRole("button", { name: "Show summary" }));
  await waitFor(() =>
    expect(
      queries
        .filter((url) => url.pathname.endsWith("operations-summary"))
        .at(-1)
        ?.searchParams.has("target_id"),
    ).toBe(false),
  );
  expect(queries.some((url) => url.searchParams.get("ids") === linkedId)).toBe(true);
  expect(
    queries
      .filter((url) => url.searchParams.has("ids"))
      .every((url) => url.searchParams.get("ids")!.split(",").length <= 2),
  ).toBe(true);
  expect(
    queries.filter((url) => url.pathname.endsWith("summaries") && !url.searchParams.has("ids")),
  ).toHaveLength(3);
  const summariesBeforeRefresh = queries.filter((url) =>
    url.pathname.endsWith("operations-summary"),
  ).length;
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Show summary" }).hasAttribute("disabled")).toBe(
      false,
    ),
  );
  await user.click(screen.getByRole("button", { name: "Show summary" }));
  await waitFor(() =>
    expect(queries.filter((url) => url.pathname.endsWith("operations-summary"))).toHaveLength(
      summariesBeforeRefresh + 1,
    ),
  );
});

test("printing a period report loads only its selected Target identity", async () => {
  await i18n.changeLanguage("en");
  const queries: URL[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    queries.push(url);
    return new Response(
      JSON.stringify(
        url.pathname.endsWith("operations-summary")
          ? { data: summary }
          : { data: [target(linkedId, "Printed host")], page: { next: null } },
      ),
    );
  });
  renderPeriod(true);
  await waitFor(() =>
    expect(screen.getByRole("article", { name: "Period report" }).textContent).toContain(
      "Printed host",
    ),
  );
  expect(queries.filter((url) => url.pathname.endsWith("summaries"))).toHaveLength(1);
  expect(queries.find((url) => url.pathname.endsWith("summaries"))?.searchParams.get("ids")).toBe(
    linkedId,
  );
  expect(screen.queryByRole("combobox")).toBeNull();
});

test.each(["page", "identity", "summary"])(
  "period %s read failures are visible and retry without effects",
  async (fault) => {
    await i18n.changeLanguage("en");
    const user = userEvent.setup();
    let failed = true;
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const url = new URL(request.url);
      const kind = url.pathname.endsWith("operations-summary")
        ? "summary"
        : url.searchParams.has("ids")
          ? "identity"
          : "page";
      if (failed && kind === fault)
        return new Response(JSON.stringify({ error: { message: "Storage unavailable" } }), {
          status: 503,
        });
      return new Response(
        JSON.stringify(
          kind === "summary"
            ? { data: summary }
            : { data: [target(linkedId, "Linked host")], page: { next: null } },
        ),
      );
    });
    renderPeriod();
    await screen.findByRole("alert");
    expect(screen.getByRole("alert").textContent).toContain(i18n.t("reports.requestFailed"));
    failed = false;
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull());
    await waitFor(() =>
      expect(screen.getAllByRole("article", { name: "Period report" })[0]!.textContent).toContain(
        "Linked host",
      ),
    );
  },
);

test("changing the applied period aborts old summary and Target reads and rejects their late replies", async () => {
  await i18n.changeLanguage("en");
  const user = userEvent.setup();
  const held: Array<{ request: Request; finish: (response: Response) => void }> = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    const id = url.searchParams.get("target_id") ?? url.searchParams.get("ids");
    if (id === linkedId)
      return new Promise<Response>((finish) => {
        held.push({ request, finish });
      });
    return new Response(
      JSON.stringify(
        url.pathname.endsWith("operations-summary")
          ? { data: { ...summary, target_id: tailId } }
          : { data: [target(tailId, "Tail host")], page: { next: null } },
      ),
    );
  });
  const view = renderPeriod();
  await waitFor(() => expect(held).toHaveLength(2));
  await user.click(screen.getByRole("link", { name: "Other period" }));
  await waitFor(() =>
    expect(screen.getAllByRole("article", { name: "Period report" })[0]!.textContent).toContain(
      "Tail host",
    ),
  );
  expect(held.every(({ request }) => request.signal.aborted)).toBe(true);
  await act(async () => {
    for (const { request, finish } of held)
      finish(
        new Response(
          JSON.stringify(
            new URL(request.url).pathname.endsWith("operations-summary")
              ? { data: summary }
              : { data: [target(linkedId, "Stale host")], page: { next: null } },
          ),
        ),
      );
  });
  expect(screen.getByRole("combobox").textContent).toContain("Tail host");
  expect(screen.queryByText("Stale host")).toBeNull();
  view.unmount();
  expect(wire.mock.calls.every(([request]) => (request as Request).signal.aborted)).toBe(true);
});

afterEach(() => {
  cleanup();
  wire.mockReset();
});
