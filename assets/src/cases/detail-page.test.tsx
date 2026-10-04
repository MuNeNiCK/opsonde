import { cleanup, render, screen, waitFor } from "@testing-library/react";
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
  condition_history: [],
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
