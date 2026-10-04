import { act, cleanup, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import type { components } from "@/api/schema";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import i18n from "@/i18n/config";
import { ReportPage } from "@/reports/page";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});
const timestamp = "2026-10-05T01:00:00Z";
const id = (index: number) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
function delivery(index: number): components["schemas"]["DeliverySummary"] {
  return {
    id: id(index),
    report_id: id(index + 100),
    report_revision: 1,
    provider_id: id(index + 200),
    provider_revision: 2,
    destination_id: id(index + 200),
    destination_revision: 2,
    status: "failed",
    reference: null,
    enqueued_at: timestamp,
    dispatch_started_at: timestamp,
    completed_at: timestamp,
    revision: 3,
  };
}
function historyPage(accountId = id(700)) {
  return (
    <AuthenticationContext.Provider
      value={{ account: { id: accountId, role: "operator" } } as Authentication}
    >
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>
  );
}
function references(url: URL) {
  const ids = (url.searchParams.get("ids") ?? "").split(",").filter(Boolean);
  if (url.pathname === "/api/v1/reports" && ids.length)
    return Response.json({
      data: ids.map((reportId) => ({
        id: reportId,
        case_id: reportId,
        case_revision: 7,
        language: "en",
        outcome: "resolved",
        revision: 1,
      })),
      page: { next: null },
    });
  if (url.pathname === "/api/v1/cases/summaries")
    return Response.json({
      data: ids.map((caseId) => ({
        id: caseId,
        title: `Completed Case ${Number(caseId.slice(-12))}`,
        revision: 7,
      })),
      page: { next: null },
    });
  if (url.pathname === "/api/v1/providers/summaries")
    return Response.json({
      data: ids.map((providerId) => ({
        id: providerId,
        name: `Destination ${Number(providerId.slice(-12))}`,
        kind: "notification",
        enabled: false,
        revision: 2,
      })),
      page: { next: null },
    });
  if (url.pathname === "/api/v1/report-setting")
    return Response.json({
      data: {
        id: id(600),
        automatic_case_reports_enabled: false,
        revision: 1,
        changed_by_id: null,
        updated_at: timestamp,
      },
    });
  return Response.json({ data: [], page: { next: null } });
}
afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("Delivery history pages 50 metadata rows, resolves off-page labels, and reads only opened result details", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  let bodyRead: Request | undefined;
  let finishBody: ((response: Response) => void) | undefined;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    reads.push(url);
    if (url.pathname === "/api/v1/deliveries/summaries") {
      expect(url.searchParams.get("limit")).toBe("50");
      return Response.json({
        data: url.searchParams.has("after")
          ? [delivery(51)]
          : Array.from({ length: 50 }, (_, index) => delivery(index + 1)),
        page: { next: url.searchParams.has("after") ? null : "delivery-tail" },
      });
    }
    if (url.pathname === `/api/v1/deliveries/${id(51)}`) {
      bodyRead = request;
      return new Promise<Response>((resolve) => {
        finishBody = resolve;
      });
    }
    return references(url);
  });
  render(historyPage());
  const user = userEvent.setup();
  const history = await screen.findByRole("region", { name: "Delivery history" });
  await within(history).findByText("Completed Case 101 · en · r7");
  expect(within(history).getAllByRole("button", { name: "Delivery details" })).toHaveLength(50);
  expect(bodyRead).toBeUndefined();
  await user.click(within(history).getByRole("button", { name: "Next" }));
  await within(history).findByText("Completed Case 151 · en · r7");
  expect(within(history).queryByText("Completed Case 101 · en · r7")).toBeNull();
  expect(within(history).getByText(/Destination 251/)).toBeDefined();
  expect(within(history).getByRole("link", { name: "Open report" }).getAttribute("href")).toBe(
    `/reports/${id(151)}/print`,
  );
  await user.click(within(history).getByRole("button", { name: "Delivery details" }));
  await waitFor(() => expect(bodyRead).toBeDefined());
  await user.click(within(history).getByRole("button", { name: "Previous" }));
  expect(bodyRead?.signal.aborted).toBe(true);
  await within(history).findByText("Completed Case 101 · en · r7");
  await act(async () => {
    finishBody?.(
      Response.json({ data: { ...delivery(51), details: { message: "Late selected receipt" } } }),
    );
  });
  expect(screen.queryByText(/Late selected receipt/)).toBeNull();
  const refs = reads.filter((url) => url.searchParams.has("ids"));
  expect(refs.length).toBeGreaterThan(0);
  expect(refs.every((url) => (url.searchParams.get("ids") ?? "").split(",").length <= 50)).toBe(
    true,
  );
});

test("failed history references retain the last complete window, abort sibling reads, and retry read-only", async () => {
  await i18n.changeLanguage("en");
  let fail = true;
  let sibling: Request | undefined;
  let finishSibling: ((response: Response) => void) | undefined;
  const methods: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    methods.push(request.method);
    if (url.pathname === "/api/v1/deliveries/summaries")
      return Response.json({
        data: [delivery(url.searchParams.has("after") ? 51 : 1)],
        page: { next: url.searchParams.has("after") ? null : "delivery-tail" },
      });
    if (fail && url.pathname === "/api/v1/reports" && url.searchParams.get("ids") === id(151)) {
      sibling = request;
      return new Promise<Response>((resolve) => {
        finishSibling = resolve;
      });
    }
    if (
      fail &&
      url.pathname === "/api/v1/providers/summaries" &&
      url.searchParams.get("ids") === id(251)
    )
      return Response.json(
        { error: { message: "Destination metadata unavailable" } },
        { status: 500 },
      );
    return references(url);
  });
  render(historyPage());
  const user = userEvent.setup();
  const history = await screen.findByRole("region", { name: "Delivery history" });
  await within(history).findByText("Completed Case 101 · en · r7");
  await user.click(within(history).getByRole("button", { name: "Next" }));
  await within(history).findByText("Destination metadata unavailable");
  expect(within(history).getByText("Completed Case 101 · en · r7")).toBeDefined();
  expect(within(history).queryByText("Completed Case 151 · en · r7")).toBeNull();
  expect(sibling?.signal.aborted).toBe(true);
  fail = false;
  await user.click(within(history).getByRole("button", { name: "Refresh" }));
  await within(history).findByText("Completed Case 151 · en · r7");
  await act(async () => {
    finishSibling?.(references(new URL(`http://localhost/api/v1/reports?ids=${id(151)}`)));
  });
  expect(within(history).queryByText("Destination metadata unavailable")).toBeNull();
  expect(methods.every((method) => method === "GET")).toBe(true);
});

test("pending history polling exposes a read failure, stops, and resumes only on operator refresh", async () => {
  await i18n.changeLanguage("en");
  let historyReads = 0;
  const methods: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    methods.push(request.method);
    if (url.pathname === "/api/v1/deliveries/summaries") {
      historyReads++;
      if (historyReads === 2)
        return Response.json(
          { error: { message: "Delivery status read unavailable" } },
          { status: 500 },
        );
      return Response.json({
        data: [
          {
            ...delivery(1),
            status: historyReads === 1 ? "queued" : "delivered",
            revision: historyReads === 1 ? 1 : 3,
          },
        ],
        page: { next: null },
      });
    }
    return references(url);
  });
  render(historyPage());
  const user = userEvent.setup();
  const history = await screen.findByRole("region", { name: "Delivery history" });
  await within(history).findByText("Queued");
  await within(history).findByText("Delivery status read unavailable", {}, { timeout: 5500 });
  expect(within(history).getByText("Queued")).toBeDefined();
  await new Promise((resolve) => setTimeout(resolve, 4200));
  expect(historyReads).toBe(2);
  await user.click(within(history).getByRole("button", { name: "Refresh" }));
  await within(history).findByText("Delivered");
  expect(historyReads).toBe(3);
  expect(methods.every((method) => method === "GET")).toBe(true);
}, 12000);

test("selected Delivery details show read errors and release their body when closed", async () => {
  await i18n.changeLanguage("en");
  let bodyReads = 0;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/deliveries/summaries")
      return Response.json({ data: [delivery(1)], page: { next: null } });
    if (url.pathname === `/api/v1/deliveries/${id(1)}`) {
      bodyReads++;
      return bodyReads === 1
        ? Response.json({ error: { message: "Delivery result unavailable" } }, { status: 500 })
        : Response.json({
            data: { ...delivery(1), details: { message: "Selected factual result" } },
          });
    }
    return references(url);
  });
  render(historyPage());
  const user = userEvent.setup();
  const history = await screen.findByRole("region", { name: "Delivery history" });
  await within(history).findByText("Completed Case 101 · en · r7");
  await user.click(within(history).getByRole("button", { name: "Delivery details" }));
  await within(history).findByText("Delivery result unavailable");
  expect(bodyReads).toBe(1);
  await user.click(
    within(within(history).getByRole("alert")).getByRole("button", { name: "Refresh" }),
  );
  await within(history).findByText(/Selected factual result/);
  await user.click(within(history).getByRole("button", { name: "Delivery details" }));
  expect(within(history).queryByText(/Selected factual result/)).toBeNull();
  expect(bodyReads).toBe(2);
});

test.each(["closing", "changing accounts"])(
  "%s aborts pending history references and ignores their late response",
  async (interruption) => {
    await i18n.changeLanguage("en");
    let checking: Request | undefined;
    let finishRead: ((response: Response) => void) | undefined;
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const url = new URL(request.url);
      if (url.pathname === "/api/v1/deliveries/summaries")
        return Response.json({
          data: [delivery(url.searchParams.has("after") ? 51 : 1)],
          page: { next: url.searchParams.has("after") ? null : "delivery-tail" },
        });
      if (url.pathname === "/api/v1/cases/summaries" && url.searchParams.get("ids") === id(151)) {
        checking = request;
        return new Promise<Response>((resolve) => {
          finishRead = resolve;
        });
      }
      return references(url);
    });
    const view = render(historyPage());
    const user = userEvent.setup();
    const history = await screen.findByRole("region", { name: "Delivery history" });
    await within(history).findByText("Completed Case 101 · en · r7");
    await user.click(within(history).getByRole("button", { name: "Next" }));
    await waitFor(() => expect(checking).toBeDefined());
    if (interruption === "closing") view.unmount();
    else view.rerender(historyPage(id(702)));
    expect(checking?.signal.aborted).toBe(true);
    await act(async () => {
      finishRead?.(references(new URL(`http://localhost/api/v1/cases/summaries?ids=${id(151)}`)));
    });
    expect(screen.queryByText("Completed Case 151 · en · r7")).toBeNull();
    if (interruption === "changing accounts")
      await screen.findByText("Completed Case 101 · en · r7");
  },
);
