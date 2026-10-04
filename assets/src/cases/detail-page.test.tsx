import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, expect, test, vi } from "vite-plus/test";
import type { components } from "@/api/schema";
import { AuthenticationContext, type Authentication } from "@/auth/context";
import { CaseDetailPage } from "@/cases/detail-page";
import i18n from "@/i18n/config";

const wire = vi.hoisted(() => {
  const fetch = vi.fn();
  vi.stubGlobal("fetch", fetch);
  return fetch;
});

const timestamp = "2026-10-04T01:00:00Z";
const caseId = "00000000-0000-4000-8000-000000000001";
const reportId = "00000000-0000-4000-8000-000000000002";
const oldReportId = "00000000-0000-4000-8000-000000000003";
const report: components["schemas"]["Report"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content: {},
  content_digest: "a".repeat(64),
  generated_at: timestamp,
  revision: 1,
  document: {
    title: "Physical host recovered",
    outcome: "Resolved",
    opened_at: timestamp,
    finished_at: timestamp,
    target_id: null,
    source: "fixture",
    source_ref: "case-report",
    severity: "warning",
    conditions: [],
    case_symptom: null,
    actions: [],
    verifications: [],
    cited_evidence: [],
    conclusion: "The current recovery was verified.",
    conclusion_turn_id: null,
    recovery_reviews: [],
    stop_reason: null,
    required_human_input: null,
    case_id: caseId,
    case_revision: 2,
    digest: "a".repeat(64),
    text: "Exact report document",
  },
};

const reportSummary: components["schemas"]["ReportSummary"] = {
  id: reportId,
  case_id: caseId,
  case_revision: 2,
  language: "en",
  outcome: "resolved",
  content_digest: report.content_digest,
  generated_at: timestamp,
  revision: 1,
  operation_count: 0,
  verification_count: 0,
};
const snapshot: components["schemas"]["CaseSnapshot"] = {
  case: {
    id: caseId,
    trigger_kind: "manual",
    source: "fixture",
    source_ref: "case-report",
    split_parent_id: null,
    title: "Physical host recovered",
    severity: "warning",
    condition_count: 0,
    firing_condition_count: 0,
    report_language: "en",
    status: "resolved",
    operator_action: "none",
    pending_proposal_id: null,
    initial_context: {},
    case_symptom: null,
    authority_setting_id: caseId,
    authority_setting_revision: 1,
    authority_mode: "auto",
    limits: {
      max_elapsed_seconds: 600,
      max_resolver_turns: 10,
      max_target_requests: 20,
      max_effects: 10,
      max_related_targets: 10,
      max_ai_usage_units: 100_000,
      max_no_progress_turns: 3,
    },
    cancel_requested: false,
    stop_reason: null,
    required_human_input: null,
    resolved_at: timestamp,
    initial_target_id: null,
    selected_target_id: null,
    selected_target_revision: null,
    current_owner_id: null,
    revision: 2,
    inserted_at: timestamp,
    updated_at: timestamp,
  },
  ai_usage: {
    reported_input_tokens: 0,
    reported_output_tokens: 0,
    reported_total_tokens: 0,
    reported_invocations: 0,
    unknown_invocations: 0,
    pending_invocations: 0,
    not_dispatched_invocations: 0,
    budget_charged_units: 0,
    unknown_reserved_units: 0,
    pending_reserved_units: 0,
    complete: true,
  },
  conditions: [],
  condition_context: { groups: null, assessments: null },
  resolution_runs: [],
  proposals: [],
  operations: [],
  verification_attempts: [],
  reports: [{ ...reportSummary, id: oldReportId, case_revision: 1 }, reportSummary],
};

afterEach(() => {
  cleanup();
  wire.mockReset();
  sessionStorage.clear();
});

test.each([false, true])(
  "pending Proposal read failure=%s keeps the case visible without inferring approval from history",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    const proposal: components["schemas"]["Proposal"] = {
      id: reportId,
      case_id: caseId,
      resolution_run_id: caseId,
      source_turn_id: caseId,
      proposed_for_id: caseId,
      target_id: caseId,
      access_method_id: caseId,
      provider_id: caseId,
      status: "awaiting_human",
      authority_mode: "ask",
      case_generation: 1,
      target_revision: 1,
      access_method_revision: 1,
      provider_revision: 1,
      request_kind: "effect",
      purpose: "remediation",
      tool_id: "fixture",
      capability: "fixture",
      operation: "repair",
      selectors: {},
      parameters: { command: "repair service", padding: "x".repeat(64_000) },
      reason: "Current exact request requires approval",
      evidence_ids: [],
      delay_seconds: 0,
      affected_conditions: [],
      expected_result: {},
      verification_intent: {},
      verification_tool: {},
      preflight_status: "cleared",
      preflight_reason: null,
      proposal_digest: "a".repeat(64),
      expires_at: timestamp,
      revision: 1,
      inserted_at: timestamp,
      updated_at: timestamp,
    };
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const path = new URL(request.url, "http://localhost").pathname;
      requests.push(path);
      if (path === `/api/v1/cases/${caseId}`)
        return new Response(
          JSON.stringify({
            data: {
              ...snapshot,
              case: {
                ...snapshot.case,
                status: "running",
                authority_mode: "ask",
                operator_action: "decision_required",
                pending_proposal_id: reportId,
              },
              proposals: [],
              reports: [],
            },
          }),
        );
      if (path === `/api/v1/proposals/${reportId}`)
        return fails
          ? new Response(JSON.stringify({ error: { message: "Proposal storage unavailable" } }), {
              status: 500,
            })
          : new Response(JSON.stringify({ data: proposal }));
      if (path.startsWith("/api/v1/proposals/"))
        throw new Error("Unselected Proposal must stay unloaded");
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "operator" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByRole("heading", { name: "Physical host recovered" })).toBeDefined();
    expect(screen.getByText("Activity history")).toBeDefined();
    if (fails) {
      expect(await screen.findByText("Proposal storage unavailable")).toBeDefined();
      expect(screen.queryByRole("button", { name: "Approve" })).toBeNull();
      expect(screen.queryByRole("button", { name: "Reject" })).toBeNull();
    } else {
      expect(await screen.findByText("Current exact request requires approval")).toBeDefined();
      expect(screen.getByRole("button", { name: "Approve" })).toBeDefined();
    }
    expect(requests.filter((path) => path.startsWith("/api/v1/proposals/"))).toEqual([
      `/api/v1/proposals/${reportId}`,
    ]);
  },
);

test.each([false, true])(
  "history window read failure=%s preserves data and ignores an old refresh after navigation",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    const receiptRequests: Record<string, string[]> = {
      turns: [],
      proposals: [],
      "condition-history": [],
      operations: [],
      "verification-attempts": [],
    };
    let delayedRefresh: ((response: Response) => void) | undefined;
    let delayedResponse: Response | undefined;
    let failNext = fails;
    const conditions: components["schemas"]["CaseCondition"][] = [reportId, oldReportId].map(
      (id) => ({
        id,
        signal_correlation_id: id,
        target_id: null,
        predicate: "Service unavailable",
        subject_ref: {},
        state: "firing",
        recovery_status: "needs_observation",
        recovery_evidence_ids: [],
        first_fired_at: timestamp,
        current_occurred_at: timestamp,
        revision: 1,
        membership_id: id,
        attached_at: timestamp,
      }),
    );
    const currentContext: components["schemas"]["TurnConditionContext"] = {
      id: caseId,
      ordinal: 9,
      revision: 1,
      completed_at: timestamp,
      condition_revisions: conditions.map(({ id, revision }) => ({ id, revision })),
      condition_groups: [
        {
          condition_ids: conditions.map(({ id }) => id),
          assessment: "independent",
          reason: "Current independent causes remain visible",
          evidence_ids: [],
        },
      ],
      condition_assessments: [
        {
          condition_id: reportId,
          revision: 1,
          status: "unknown",
          reason: "Current recovery still requires observation",
          evidence_ids: [],
        },
      ],
    };
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const url = new URL(request.url, "http://localhost");
      if (url.pathname === `/api/v1/cases/${caseId}`) {
        return new Response(
          JSON.stringify({
            data: {
              ...snapshot,
              case: {
                ...snapshot.case,
                trigger_kind: "signal",
                status: "running",
                condition_count: 2,
                firing_condition_count: 2,
              },
              conditions,
              condition_context: { groups: currentContext, assessments: currentContext },
              reports: [],
            },
          }),
        );
      }
      const collection = url.pathname.split("/").at(-1)!;
      if (collection in receiptRequests) {
        const after = url.searchParams.get("after");
        receiptRequests[collection].push(after ?? "first");
        if (after) expect(after).toBe(`older-${collection}`);
        const item =
          collection === "condition-history"
            ? {
                id: `membership-${after ? "old" : "latest"}`,
                case_id: caseId,
                condition_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                attached_at: timestamp,
                detached_at: after ? timestamp : null,
                reason: "Historical split",
              }
            : collection === "turns"
              ? {
                  id: `turns-${after ? "old" : "latest"}`,
                  case_id: caseId,
                  resolution_run_id: caseId,
                  ordinal: after ? 1 : 2,
                  status: "completed",
                  progress_kind: "hypothesis",
                  revision: 1,
                  inserted_at: timestamp,
                  updated_at: timestamp,
                  started_at: timestamp,
                  completed_at: timestamp,
                  summary: {
                    outcome: "decision",
                    type: "handoff",
                    reason: `${after ? "Older" : "Latest"} turns receipt`,
                    target_id: null,
                    capability: null,
                    operation: null,
                    failure_category: null,
                    failure_message: null,
                    relationship: null,
                  },
                }
              : {
                  id: `${collection}-${after ? "old" : "latest"}`,
                  revision: 1,
                  capability: "fixture",
                  operation: `${after ? "Older" : "Latest"} ${collection} receipt`,
                  status:
                    collection === "proposals"
                      ? "authorized"
                      : collection === "operations"
                        ? "applied"
                        : "verified",
                  target_id: collection === "proposals" ? caseId : null,
                  proposal_id: null,
                  outcome_category: null,
                  completed_at: timestamp,
                  updated_at: timestamp,
                  accepted_at: timestamp,
                  inserted_at: timestamp,
                  source_turn_id: caseId,
                  access_method_id: caseId,
                  proposal_digest: "a".repeat(64),
                };
        return new Response(
          JSON.stringify({
            data: [item],
            page: { next: after ? null : `older-${collection}` },
          }),
        );
      }
      if (url.pathname.endsWith("/evidence")) {
        const after = url.searchParams.get("after");
        requests.push(after ?? "first");
        if (after && failNext) {
          failNext = false;
          return new Response(
            JSON.stringify({ error: { message: "History storage unavailable" } }),
            { status: 500 },
          );
        }
        const evidence: components["schemas"]["EvidenceSummary"] = {
          id: after ? oldReportId : reportId,
          case_id: caseId,
          resolution_run_id: caseId,
          turn_id: null,
          kind: "observation",
          source: "fixture",
          source_ref: "history-window",
          summary: {
            status: "applied",
            category: null,
            target_id: null,
            condition_id: null,
            title: after ? "Older window receipt" : "Latest window receipt",
            target_label: null,
          },
          observed_at: timestamp,
          inserted_at: timestamp,
          updated_at: timestamp,
        };
        const response = new Response(
          JSON.stringify({ data: [evidence], page: { next: after ? null : "older-cursor" } }),
        );
        if (requests.length === 2 && after === null) {
          delayedResponse = response;
          return new Promise<Response>((resolve) => {
            delayedRefresh = resolve;
          });
        }
        return response;
      }
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByText("Latest window receipt")).toBeDefined();
    expect(screen.getByText("Latest turns receipt")).toBeDefined();
    expect(screen.getByText("Current independent causes remain visible")).toBeDefined();
    expect(screen.getByText("Current recovery still requires observation")).toBeDefined();
    expect(screen.getByText(/Latest operations receipt/)).toBeDefined();
    expect(screen.getByText(/Latest proposals receipt/)).toBeDefined();
    expect(screen.getByText(/Latest verification-attempts receipt/)).toBeDefined();
    expect(requests).toEqual(["first"]);
    expect(screen.queryByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeNull();
    expect(screen.queryByText("Older window receipt")).toBeNull();
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(delayedRefresh).toBeDefined());
    await user.click(screen.getByRole("button", { name: "Next" }));
    if (fails) {
      expect(await screen.findByText("History storage unavailable")).toBeDefined();
      expect(screen.getByText("Latest window receipt")).toBeDefined();
      expect(screen.getByText("Page 1")).toBeDefined();
      expect(requests).toEqual(["first", "first", "older-cursor"]);
      await user.click(screen.getByRole("button", { name: "Next" }));
    }
    expect(await screen.findByText("Older window receipt")).toBeDefined();
    expect(screen.getByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeDefined();
    expect(screen.getByText("Older turns receipt")).toBeDefined();
    expect(screen.queryByText("Latest turns receipt")).toBeNull();
    expect(screen.getByText("Current independent causes remain visible")).toBeDefined();
    expect(screen.getByText("Current recovery still requires observation")).toBeDefined();
    expect(screen.getByText(/Older operations receipt/)).toBeDefined();
    expect(screen.getByText(/Older proposals receipt/)).toBeDefined();
    expect(screen.getByText(/Older verification-attempts receipt/)).toBeDefined();
    expect(screen.queryByText(/Latest operations receipt/)).toBeNull();
    expect(screen.queryByText(/Latest proposals receipt/)).toBeNull();
    expect(screen.queryByText(/Latest verification-attempts receipt/)).toBeNull();
    expect(screen.queryByText("Latest window receipt")).toBeNull();
    const expected = fails
      ? ["first", "first", "older-cursor", "older-cursor"]
      : ["first", "first", "older-cursor"];
    expect(requests).toEqual(expected);
    await act(async () => {
      delayedRefresh?.(delayedResponse!);
    });
    expect(screen.queryByText("Latest window receipt")).toBeNull();
    expect(screen.getByText("Older window receipt")).toBeDefined();
    expect(screen.getByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeDefined();
    expect(screen.queryByText(/Latest operations receipt/)).toBeNull();
    await user.click(screen.getByRole("button", { name: "Previous" }));
    expect(await screen.findByText("Latest window receipt")).toBeDefined();
    expect(screen.queryByText("cccccccc-cccc-4ccc-8ccc-cccccccccccc")).toBeNull();
    expect(screen.queryByText("Older window receipt")).toBeNull();
    expect(requests).toEqual([...expected, "first"]);
    for (const [collection, calls] of Object.entries(receiptRequests)) {
      expect(calls).toEqual(
        expected
          .map((cursor) => (cursor === "first" ? cursor : `older-${collection}`))
          .concat("first"),
      );
    }
  },
);

test.each([false, true])(
  "case report read failure=%s keeps the case available and reads only its current report",
  async (fails) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      expect(request.method).toBe("GET");
      const path = new URL(request.url, "http://localhost").pathname;
      requests.push(path);
      if (path === `/api/v1/cases/${caseId}`)
        return new Response(JSON.stringify({ data: snapshot }));
      if (path === `/api/v1/reports/${reportId}`) {
        return fails
          ? new Response(JSON.stringify({ error: { message: "Report storage unavailable" } }), {
              status: 500,
            })
          : new Response(JSON.stringify({ data: report }));
      }
      if (path.startsWith("/api/v1/reports/"))
        throw new Error("Historical report must stay unloaded");
      return new Response(JSON.stringify({ data: [], page: { next: null } }));
    });
    render(
      <AuthenticationContext.Provider value={{ account: { role: "viewer" } } as Authentication}>
        <MemoryRouter initialEntries={[`/cases/${caseId}`]}>
          <Routes>
            <Route path="/cases/:caseId" element={<CaseDetailPage />} />
          </Routes>
        </MemoryRouter>
      </AuthenticationContext.Provider>,
    );
    expect(await screen.findByRole("heading", { name: "Physical host recovered" })).toBeDefined();
    if (fails) {
      expect(await screen.findByText("Report storage unavailable")).toBeDefined();
      expect(await screen.findByText("Activity history")).toBeDefined();
    } else {
      expect(await screen.findByText("The current recovery was verified.")).toBeDefined();
    }
    await waitFor(() =>
      expect(requests.filter((path) => path.startsWith("/api/v1/reports/"))).toEqual([
        `/api/v1/reports/${reportId}`,
      ]),
    );
  },
);
