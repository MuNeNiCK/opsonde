import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
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

test("failed report page and body reads preserve history, and closing aborts a pending body", async () => {
  await i18n.changeLanguage("en");
  let bodyRequest: Request | undefined;
  let finishBody: ((response: Response) => void) | undefined;
  let bodyReads = 0;
  let pageReads = 0;
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/api/v1/reports") {
      pageReads++;
      if (url.searchParams.has("after"))
        return new Response(
          JSON.stringify({ error: { message: "Report page storage unavailable" } }),
          { status: 500 },
        );
      return new Response(JSON.stringify({ data: [summary], page: { next: "older-reports" } }));
    }
    if (url.pathname === `/api/v1/reports/${reportId}`) {
      bodyReads++;
      if (bodyReads === 1) {
        bodyRequest = request;
        return new Promise<Response>((resolve) => {
          finishBody = resolve;
        });
      }
      return new Response(
        JSON.stringify({ error: { message: "Report body storage unavailable" } }),
        { status: 500 },
      );
    }
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("3 operations · 2 checks");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Next" }));
  expect(await screen.findByText("Report page storage unavailable")).toBeDefined();
  expect(screen.getByText("Page 1")).toBeDefined();
  expect(document.getElementById(`report-${reportId}`)).not.toBeNull();
  expect(pageReads).toBe(2);
  await user.click(screen.getByRole("button", { name: "Details" }));
  await waitFor(() => expect(bodyRequest).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Hide details" }));
  expect(bodyRequest?.signal.aborted).toBe(true);
  await user.click(screen.getByRole("button", { name: "Details" }));
  expect(await screen.findByText("Report body storage unavailable")).toBeDefined();
  await act(async () => {
    finishBody?.(new Response(JSON.stringify({ data: full })));
  });
  expect(screen.queryByText("The selected recovery was verified.")).toBeNull();
  expect(document.querySelector("pre")).toBeNull();
  expect(bodyReads).toBe(2);
  expect(pageReads).toBe(2);
});

const timestamp = "2026-10-04T01:00:00Z";
const caseId = "00000000-0000-4000-8000-000000000001";
const reportId = "00000000-0000-4000-8000-000000000002";
const olderId = "00000000-0000-4000-8000-000000000003";
const summary: components["schemas"]["ReportSummary"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: "a".repeat(64),
  generated_at: timestamp,
  revision: 1,
  operation_count: 3,
  verification_count: 2,
};
const full: components["schemas"]["Report"] = {
  id: summary.id,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: summary.content_digest,
  generated_at: timestamp,
  revision: 1,
  content: { padding: "x".repeat(10_000_000) },
  document: {
    title: "Physical host recovered",
    outcome: "Resolved",
    opened_at: timestamp,
    finished_at: timestamp,
    target_id: null,
    source: "fixture",
    source_ref: "report-capacity",
    severity: "warning",
    conditions: [],
    case_symptom: null,
    actions: [],
    verifications: [],
    cited_evidence: [],
    conclusion: "The selected recovery was verified.",
    conclusion_turn_id: null,
    recovery_reviews: [],
    stop_reason: null,
    required_human_input: null,
    case_id: caseId,
    case_revision: 2,
    digest: summary.content_digest,
    text: "Exact report document",
  },
};
const setting: components["schemas"]["ReportSetting"] = {
  id: caseId,
  automatic_case_reports_enabled: false,
  changed_by_id: null,
  revision: 1,
  updated_at: timestamp,
};

afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test("report history reads one metadata page and loads only the selected body", async () => {
  await i18n.changeLanguage("en");
  sessionStorage.setItem("opsonde.session", "fixture-token");
  const requests: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    expect(request.headers.get("Authorization")).toBe("Bearer fixture-token");
    const url = new URL(request.url, "http://localhost");
    requests.push(url.pathname + url.search);
    if (url.pathname === "/api/v1/reports") {
      const older = url.searchParams.has("after");
      return new Response(
        JSON.stringify({
          data: [older ? { ...summary, id: olderId, case_revision: 1 } : summary],
          page: { next: older ? null : "older-reports" },
        }),
      );
    }
    if (url.pathname === `/api/v1/reports/${reportId}`)
      return new Response(JSON.stringify({ data: full }));
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  expect(await screen.findByText("3 operations · 2 checks")).toBeDefined();
  expect(requests.filter((url) => url.startsWith("/api/v1/reports"))).toEqual([
    "/api/v1/reports?limit=50",
  ]);
  expect(document.querySelector("pre")).toBeNull();
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Details" }));
  expect(await screen.findByText("The selected recovery was verified.")).toBeDefined();
  expect(screen.getByText("Print or save as PDF").closest("a")?.getAttribute("href")).toBe(
    `/reports/${reportId}/print`,
  );
  expect(document.querySelector("pre")).toBeNull();
  await user.click(screen.getByText("Technical details"));
  await waitFor(() =>
    expect(document.querySelector("pre")?.textContent).toContain(full.content.padding),
  );
  await user.click(screen.getByRole("button", { name: "Hide details" }));
  expect(screen.queryByText("The selected recovery was verified.")).toBeNull();
  expect(document.querySelector("pre")).toBeNull();
  await user.click(screen.getByRole("button", { name: "Next" }));
  expect(await screen.findByText("Page 2")).toBeDefined();
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
  expect((screen.getByRole("button", { name: "Next" }) as HTMLButtonElement).disabled).toBe(true);
  await user.click(screen.getByRole("button", { name: "Previous" }));
  expect(await screen.findByText("Page 1")).toBeDefined();
  expect(document.getElementById(`report-${olderId}`)).toBeNull();
  expect(requests.filter((url) => url.startsWith("/api/v1/reports"))).toEqual([
    "/api/v1/reports?limit=50",
    `/api/v1/reports/${reportId}`,
    "/api/v1/reports?limit=50&after=older-reports",
    "/api/v1/reports?limit=50",
  ]);
});

test("a refresh started on the first report page cannot replace a newly selected page", async () => {
  await i18n.changeLanguage("en");
  let firstPageReads = 0;
  let finishRefresh: ((response: Response) => void) | undefined;
  const firstPage = { data: [summary], page: { next: "older-reports" } };
  wire.mockImplementation(async (request: Request) => {
    expect(request.method).toBe("GET");
    const url = new URL(request.url, "http://localhost");
    if (url.pathname === "/api/v1/reports") {
      if (url.searchParams.has("after"))
        return new Response(
          JSON.stringify({ data: [{ ...summary, id: olderId }], page: { next: null } }),
        );
      firstPageReads++;
      if (firstPageReads === 2)
        return new Promise<Response>((resolve) => {
          finishRefresh = resolve;
        });
      return new Response(JSON.stringify(firstPage));
    }
    if (url.pathname === "/api/v1/report-setting")
      return new Response(JSON.stringify({ data: setting }));
    return new Response(JSON.stringify({ data: [], page: { next: null } }));
  });
  render(
    <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
      <MemoryRouter>
        <ReportPage />
      </MemoryRouter>
    </AuthenticationContext.Provider>,
  );
  await screen.findByText("3 operations · 2 checks");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Refresh" }));
  await waitFor(() => expect(finishRefresh).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Next" }));
  expect(await screen.findByText("Page 2")).toBeDefined();
  await act(async () => {
    finishRefresh?.(new Response(JSON.stringify(firstPage)));
  });
  expect(screen.getByText("Page 2")).toBeDefined();
  expect(document.getElementById(`report-${olderId}`)).not.toBeNull();
  expect(document.getElementById(`report-${reportId}`)).toBeNull();
});
