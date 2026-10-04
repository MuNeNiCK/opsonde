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
const identifier = (index: number) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
const currentReport: components["schemas"]["ReportSummary"] = {
  id: identifier(1),
  case_id: identifier(101),
  case_revision: 7,
  language: "en",
  outcome: "resolved",
  content_digest: "a".repeat(64),
  generated_at: timestamp,
  revision: 1,
  operation_count: 3,
  verification_count: 2,
};
const selectedReport = { ...currentReport, id: identifier(51), case_id: identifier(151) };
function destination(index: number): components["schemas"]["ProviderSummary"] {
  return {
    id: identifier(index + 200),
    name: `Destination ${index}`,
    kind: "notification",
    adapter_type: "http-webhook",
    enabled: true,
    revision: 2,
    check: {
      status: "passed",
      checked_revision: 2,
      checked_at: timestamp,
      category: null,
      message: null,
    },
  };
}
const failedDelivery: components["schemas"]["Delivery"] = {
  id: identifier(500),
  report_id: selectedReport.id,
  report_revision: 1,
  provider_id: destination(1).id,
  provider_revision: 2,
  destination_id: destination(1).id,
  destination_revision: 2,
  status: "failed",
  reference: null,
  details: {},
  enqueued_at: timestamp,
  dispatch_started_at: timestamp,
  completed_at: timestamp,
  revision: 3,
};
function deliveryPage(accountId = identifier(700)) {
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
function deliveryResponse(url: URL) {
  if (url.pathname === "/api/v1/reports")
    return Response.json({
      data: url.searchParams.has("ids") ? [selectedReport] : [currentReport],
      page: { next: null },
    });
  if (url.pathname === "/api/v1/cases/summaries")
    return Response.json({
      data: [{ id: selectedReport.case_id, title: "Completed Case 51" }],
      page: { next: null },
    });
  if (url.pathname === "/api/v1/providers/summaries")
    return Response.json({ data: [destination(51)], page: { next: null } });
  if (url.pathname === "/api/v1/deliveries")
    return Response.json({ data: [failedDelivery], page: { next: null } });
  if (url.pathname === "/api/v1/report-setting")
    return Response.json({
      data: {
        id: identifier(600),
        automatic_case_reports_enabled: false,
        revision: 1,
        changed_by_id: null,
        updated_at: timestamp,
      },
    });
  return Response.json({ data: [], page: { next: null } });
}
async function chooseDelivery() {
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: i18n.t("reports.retryDelivery") }));
  await waitFor(() =>
    expect(screen.getByRole("combobox", { name: "Report" }).textContent).toContain(
      "Completed Case 51",
    ),
  );
  const choice = await screen.findByRole("combobox", { name: "Destination" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Destination 51" }));
  return user;
}
afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("Delivery creation resolves a Report outside the table window and retains destination 51 while paging", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  const submissions: components["schemas"]["CreateDeliveryRequest"][] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/reports") {
      reads.push(url);
      return Response.json({
        data: url.searchParams.has("ids") ? [selectedReport] : [currentReport],
        page: { next: null },
      });
    }
    if (url.pathname === "/api/v1/cases/summaries") {
      const ids = (url.searchParams.get("ids") ?? "").split(",");
      return Response.json({
        data: ids.map((id) => ({
          id,
          title: id === selectedReport.case_id ? "Completed Case 51" : "Completed Case 1",
          status: "resolved",
          revision: 7,
          report_language: "en",
          initial_target_id: null,
          selected_target_id: null,
          inserted_at: timestamp,
          updated_at: timestamp,
        })),
        page: { next: null },
      });
    }
    if (url.pathname === "/api/v1/providers/summaries") {
      reads.push(url);
      expect(url.searchParams.get("kinds")).toBe("notification");
      expect(url.searchParams.get("eligible")).toBe("true");
      return Response.json({
        data:
          url.searchParams.has("ids") || url.searchParams.has("after")
            ? [destination(51)]
            : Array.from({ length: 50 }, (_, index) => destination(index + 1)),
        page: {
          next:
            url.searchParams.has("ids") || url.searchParams.has("after")
              ? null
              : "destinations-tail",
        },
      });
    }
    if (url.pathname === "/api/v1/deliveries") {
      if (request.method === "POST") {
        const input = await request.json();
        submissions.push(input);
        return Response.json(
          {
            data: {
              ...failedDelivery,
              ...input.delivery,
              destination_id: input.delivery.provider_id,
              destination_revision: input.delivery.provider_revision,
              id: identifier(501),
              status: "queued",
              revision: 1,
            },
          },
          { status: 202 },
        );
      }
      return Response.json({ data: [failedDelivery], page: { next: null } });
    }
    return deliveryResponse(url);
  });
  render(deliveryPage());
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: i18n.t("reports.retryDelivery") }));
  const report = await screen.findByRole("combobox", { name: "Report" });
  await waitFor(() => expect(report.textContent).toContain("Completed Case 51"));
  const group = await screen.findByRole("group", { name: "Destination" });
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Destination 51" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("Destination 51"),
  );
  await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
  await waitFor(() => expect(submissions).toHaveLength(1));
  expect(submissions[0].delivery).toMatchObject({
    report_id: selectedReport.id,
    report_revision: 1,
    provider_id: destination(51).id,
    provider_revision: 2,
  });
  expect(submissions[0].delivery.idempotency_key).toMatch(/^[0-9a-f-]{36}$/);
  expect(
    reads.some(
      (url) =>
        url.pathname === "/api/v1/reports" &&
        url.searchParams.get("ids") === selectedReport.id &&
        url.searchParams.get("limit") === "1",
    ),
  ).toBe(true);
  expect(
    reads.some(
      (url) =>
        url.pathname === "/api/v1/providers/summaries" &&
        url.searchParams.get("ids") === destination(51).id &&
        url.searchParams.get("limit") === "1",
    ),
  ).toBe(true);
});

test("lost Delivery acknowledgement retains its original key across reload and never posts a new attempt", async () => {
  await i18n.changeLanguage("en");
  const submissions: components["schemas"]["CreateDeliveryRequest"][] = [];
  const receiptKeys: string[] = [];
  let recovered = false;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/deliveries/receipt") {
      receiptKeys.push(url.searchParams.get("idempotency_key") ?? "");
      return recovered
        ? Response.json({
            data: {
              ...failedDelivery,
              id: identifier(501),
              provider_id: destination(51).id,
              provider_revision: 2,
              destination_id: destination(51).id,
              destination_revision: 2,
              status: "queued",
              revision: 1,
            },
          })
        : Response.json({ error: { message: "Receipt not yet available" } }, { status: 404 });
    }
    if (url.pathname === "/api/v1/deliveries") {
      if (request.method === "POST") {
        submissions.push(await request.json());
        return Response.json(
          { error: { message: "Response lost after enqueue" } },
          { status: 503 },
        );
      }
      return Response.json({ data: [failedDelivery], page: { next: null } });
    }
    return deliveryResponse(url);
  });
  const show = () => render(deliveryPage());
  show();
  const user = userEvent.setup();
  await user.click(await screen.findByRole("button", { name: i18n.t("reports.retryDelivery") }));
  const choice = await screen.findByRole("combobox", { name: "Destination" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Destination 51" }));
  await waitFor(() =>
    expect(
      (screen.getByRole("button", { name: "Create delivery attempt" }) as HTMLButtonElement)
        .disabled,
    ).toBe(false),
  );
  await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
  await screen.findByText("Could not confirm delivery acceptance. Check the result.");
  expect(submissions).toHaveLength(1);
  const originalKey = submissions[0].delivery.idempotency_key;
  expect(receiptKeys).toEqual([originalKey]);
  expect(
    (screen.getByRole("button", { name: "Create delivery attempt" }) as HTMLButtonElement).disabled,
  ).toBe(true);
  cleanup();
  recovered = true;
  show();
  await user.click(await screen.findByRole("button", { name: i18n.t("reports.retryDelivery") }));
  await user.click(await screen.findByRole("button", { name: "Check result" }));
  await waitFor(() => expect(screen.queryByRole("group", { name: "Destination" })).toBeNull());
  expect(receiptKeys).toEqual([originalKey, originalKey]);
  expect(submissions).toHaveLength(1);
});

test.each(["disabled", "changed", "failed"])(
  "a %s destination recheck prevents enqueue",
  async (condition) => {
    await i18n.changeLanguage("en");
    const submissions: unknown[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (url.pathname === "/api/v1/providers/summaries") {
        if (url.searchParams.has("ids")) {
          if (condition === "failed")
            return Response.json(
              { error: { message: "Destination read unavailable" } },
              { status: 500 },
            );
          return Response.json({
            data:
              condition === "disabled"
                ? []
                : [
                    {
                      ...destination(51),
                      revision: 3,
                      check: { ...destination(51).check, checked_revision: 3 },
                    },
                  ],
            page: { next: null },
          });
        }
        return Response.json({ data: [destination(51)], page: { next: null } });
      }
      if (url.pathname === "/api/v1/deliveries") {
        if (request.method === "POST") {
          submissions.push(await request.json());
          return Response.json({ data: failedDelivery }, { status: 202 });
        }
        return Response.json({ data: [failedDelivery], page: { next: null } });
      }
      return deliveryResponse(url);
    });
    render(deliveryPage());
    const user = await chooseDelivery();
    await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
    await screen.findByText(
      condition === "failed"
        ? "Destination read unavailable"
        : i18n.t(condition === "changed" ? "cases.stateChanged" : "reports.destinationUnavailable"),
    );
    expect(submissions).toEqual([]);
  },
);

test("a failed destination recheck stops the concurrent Report read and does not enqueue", async () => {
  await i18n.changeLanguage("en");
  let checking: Request | undefined;
  let finishRead: ((response: Response) => void) | undefined;
  let submitted = false;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      submitted = true;
      return Response.json({ data: failedDelivery }, { status: 202 });
    }
    if (url.pathname === "/api/v1/reports" && url.searchParams.has("ids")) {
      if (checking === undefined) {
        checking = request;
        return deliveryResponse(url);
      }
      checking = request;
      return new Promise<Response>((resolve) => {
        finishRead = resolve;
      });
    }
    if (url.pathname === "/api/v1/providers/summaries" && url.searchParams.has("ids"))
      return Response.json({ error: { message: "Destination read unavailable" } }, { status: 500 });
    return deliveryResponse(url);
  });
  render(deliveryPage());
  const user = await chooseDelivery();
  await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
  await screen.findByText("Destination read unavailable");
  expect(checking?.signal.aborted).toBe(true);
  await act(async () => {
    finishRead?.(Response.json({ data: [selectedReport], page: { next: null } }));
  });
  expect(submitted).toBe(false);
});

test("Delivery creation sends nothing when its original request cannot be saved", async () => {
  await i18n.changeLanguage("en");
  const submissions: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    if (request.method === "POST") submissions.push(request.url);
    return deliveryResponse(new URL(request.url));
  });
  render(deliveryPage());
  const user = await chooseDelivery();
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new DOMException("Storage unavailable", "QuotaExceededError");
  });
  try {
    await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
    await screen.findByText("Could not save the request. No delivery was submitted.");
    expect(submissions).toEqual([]);
    expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  } finally {
    saving.mockRestore();
  }
});

test.each(["closing", "changing accounts"])(
  "%s during a Delivery recheck aborts the read and cannot enqueue afterward",
  async (interruption) => {
    await i18n.changeLanguage("en");
    let checking: Request | undefined;
    let finishRead: ((response: Response) => void) | undefined;
    const submissions: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") submissions.push(request.url);
      if (url.pathname === "/api/v1/providers/summaries" && url.searchParams.has("ids")) {
        checking = request;
        return new Promise<Response>((resolve) => {
          finishRead = resolve;
        });
      }
      return deliveryResponse(url);
    });
    const view = render(deliveryPage());
    const user = await chooseDelivery();
    await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
    await waitFor(() => expect(checking).toBeDefined());
    if (interruption === "closing")
      await user.click(screen.getByRole("button", { name: "Generate report" }));
    else view.rerender(deliveryPage(identifier(701)));
    expect(checking?.signal.aborted).toBe(true);
    await act(async () => {
      finishRead?.(Response.json({ data: [destination(51)], page: { next: null } }));
    });
    expect(submissions).toEqual([]);
  },
);

test("accepted Delivery keeps its receipt when list refresh fails and checks without enqueueing again", async () => {
  await i18n.changeLanguage("en");
  const submissions: components["schemas"]["CreateDeliveryRequest"][] = [];
  const receiptKeys: string[] = [];
  const receipt = {
    ...failedDelivery,
    id: identifier(501),
    provider_id: destination(51).id,
    destination_id: destination(51).id,
    status: "queued",
    revision: 1,
  };
  let listReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      submissions.push(await request.json());
      return Response.json({ data: receipt }, { status: 202 });
    }
    if (url.pathname === "/api/v1/reports" && !url.searchParams.has("ids")) {
      listReads++;
      if (listReads === 3)
        return Response.json({ error: { message: "Accepted refresh failed" } }, { status: 500 });
    }
    if (url.pathname === "/api/v1/deliveries/receipt") {
      receiptKeys.push(url.searchParams.get("idempotency_key") ?? "");
      return Response.json({ data: receipt });
    }
    return deliveryResponse(url);
  });
  render(deliveryPage());
  const user = await chooseDelivery();
  await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
  await screen.findByText("Could not confirm delivery acceptance. Check the result.");
  expect(submissions).toHaveLength(1);
  expect(receiptKeys).toEqual([]);
  await user.click(screen.getByRole("button", { name: "Check result" }));
  await waitFor(() => expect(screen.queryByRole("group", { name: "Destination" })).toBeNull());
  expect(receiptKeys).toEqual([submissions[0].delivery.idempotency_key]);
  expect(submissions).toHaveLength(1);
});

test.each(["foreign", "failed"])(
  "a %s Delivery receipt stays unknown and cannot permit another enqueue",
  async (condition) => {
    await i18n.changeLanguage("en");
    const submissions: components["schemas"]["CreateDeliveryRequest"][] = [];
    const receiptKeys: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        submissions.push(await request.json());
        return Response.json({ error: { message: "Enqueue response lost" } }, { status: 503 });
      }
      if (url.pathname === "/api/v1/deliveries/receipt") {
        receiptKeys.push(url.searchParams.get("idempotency_key") ?? "");
        return condition === "foreign"
          ? Response.json({
              data: {
                ...failedDelivery,
                report_id: currentReport.id,
                provider_id: destination(51).id,
                destination_id: destination(51).id,
              },
            })
          : Response.json({ error: { message: "Receipt read unavailable" } }, { status: 500 });
      }
      return deliveryResponse(url);
    });
    render(deliveryPage());
    const user = await chooseDelivery();
    await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
    await screen.findByText("Could not confirm delivery acceptance. Check the result.");
    await user.click(screen.getByRole("button", { name: "Check result" }));
    await waitFor(() => expect(receiptKeys).toHaveLength(2));
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Check result" }) as HTMLButtonElement).disabled,
      ).toBe(false),
    );
    expect(
      (screen.getByRole("button", { name: "Create delivery attempt" }) as HTMLButtonElement)
        .disabled,
    ).toBe(true);
    expect(submissions).toHaveLength(1);
    expect(receiptKeys).toEqual(Array(2).fill(submissions[0].delivery.idempotency_key));
  },
);

test("a Delivery rejection arriving after the form closes releases its own saved request", async () => {
  await i18n.changeLanguage("en");
  let finishPost: ((response: Response) => void) | undefined;
  const requests: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    if (request.method === "POST")
      return new Promise<Response>((resolve) => {
        finishPost = resolve;
      });
    return deliveryResponse(url);
  });
  render(deliveryPage());
  const user = await chooseDelivery();
  await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
  await waitFor(() => expect(finishPost).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await act(async () => {
    finishPost?.(Response.json({ error: { message: "Enqueue rejected" } }, { status: 409 }));
  });
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  await user.click(screen.getByRole("button", { name: i18n.t("reports.retryDelivery") }));
  await screen.findByRole("group", { name: "Destination" });
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  expect(requests.filter((entry) => entry.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((entry) => entry.endsWith("/deliveries/receipt"))).toHaveLength(0);
});

test.each(["missing", "changed", "foreign"])(
  "a %s Report recheck prevents Delivery creation",
  async (condition) => {
    await i18n.changeLanguage("en");
    let reportReads = 0;
    const submissions: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") submissions.push(request.url);
      if (url.pathname === "/api/v1/reports" && url.searchParams.has("ids") && ++reportReads > 1)
        return Response.json({
          data:
            condition === "missing"
              ? []
              : [condition === "foreign" ? currentReport : { ...selectedReport, revision: 2 }],
          page: { next: null },
        });
      return deliveryResponse(url);
    });
    render(deliveryPage());
    const user = await chooseDelivery();
    await user.click(screen.getByRole("button", { name: "Create delivery attempt" }));
    await screen.findByText(
      i18n.t(condition === "changed" ? "cases.stateChanged" : "reports.reportUnavailable"),
    );
    expect(submissions).toEqual([]);
  },
);
