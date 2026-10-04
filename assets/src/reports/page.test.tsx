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

function reportCase(index: number): components["schemas"]["CaseSummary"] {
  return {
    id: `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
    title: `Completed Case ${index}`,
    status: "resolved",
    revision: 7,
    report_language: "en",
    initial_target_id: null,
    selected_target_id: null,
    inserted_at: timestamp,
    updated_at: timestamp,
  };
}

function reportEditor(accountId = "operator-1") {
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

function showReportEditor() {
  return render(reportEditor());
}

test("Report generation reaches Case 51, retains the off-page selection and rechecks its exact revision", async () => {
  await i18n.changeLanguage("en");
  const reads: URL[] = [];
  const submissions: unknown[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (url.pathname === "/api/v1/cases/summaries") {
      reads.push(url);
      return Response.json({
        data:
          url.searchParams.has("after") || url.searchParams.has("ids")
            ? [reportCase(51)]
            : Array.from({ length: 50 }, (_, index) => reportCase(index + 1)),
        page: {
          next: url.searchParams.has("after") || url.searchParams.has("ids") ? null : "cases-tail",
        },
      });
    }
    if (request.method === "POST") {
      expect(url.pathname).toBe(`/api/v1/cases/${reportCase(51).id}/reports`);
      submissions.push(await request.json());
      return Response.json(
        { data: { ...summary, case_id: reportCase(51).id, case_revision: 7 } },
        { status: 201 },
      );
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const group = await screen.findByRole("group", { name: "Completed Case" });
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("button", { name: "Next" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").hasAttribute("disabled")).toBe(false),
  );
  await user.click(within(group).getByRole("combobox"));
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  await user.click(within(group).getByRole("button", { name: "Previous" }));
  await waitFor(() =>
    expect(within(group).getByRole("combobox").textContent).toContain("Completed Case 51"),
  );
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await waitFor(() => expect(submissions).toEqual([{ report: { expected_case_revision: 7 } }]));
  expect(
    reads.map((url) => [
      url.searchParams.get("limit"),
      url.searchParams.get("after"),
      url.searchParams.get("ids"),
    ]),
  ).toEqual([
    ["50", null, null],
    ["50", "cases-tail", null],
    ["50", null, null],
    ["1", null, reportCase(51).id],
  ]);
});

test("a lost generation response survives page reload and recovers by Case revision without another POST", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  let recovered = false;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === `/api/v1/cases/${reportCase(51).id}/reports/7`)
      return recovered
        ? Response.json({ data: { ...summary, case_id: reportCase(51).id, case_revision: 7 } })
        : Response.json({ error: { message: "Receipt not yet available" } }, { status: 404 });
    if (request.method === "POST")
      return Response.json(
        { error: { message: "Response lost after generation" } },
        { status: 503 },
      );
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const choice = await screen.findByRole("combobox", { name: "Completed Case" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  expect(
    await screen.findByText("Could not confirm report generation. Check the result."),
  ).toBeDefined();
  expect(
    (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
  ).toBe(true);
  expect(requests.filter((item) => item.startsWith("POST"))).toEqual([
    `POST /api/v1/cases/${reportCase(51).id}/reports`,
  ]);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(1);
  cleanup();
  recovered = true;
  showReportEditor();
  await screen.findByText("Report history");
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await user.click(await screen.findByRole("button", { name: "Check result" }));
  await waitFor(() =>
    expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(2),
  );
  await waitFor(() => expect(screen.queryByRole("group", { name: "Completed Case" })).toBeNull());
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
});

async function chooseCompletedCase() {
  await screen.findByText("Report history");
  const user = userEvent.setup();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  const choice = await screen.findByRole("combobox", { name: "Completed Case" });
  await waitFor(() => expect(choice.hasAttribute("disabled")).toBe(false));
  await user.click(choice);
  await user.click(await screen.findByRole("option", { name: "Completed Case 51 · en · r7" }));
  return user;
}

test.each(["missing", "running", "changed", "failed", "foreign"])(
  "generation recheck blocks a %s Case without posting",
  async (condition) => {
    await i18n.changeLanguage("en");
    const posted: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        posted.push(url.pathname);
        return Response.json({ data: summary }, { status: 201 });
      }
      if (url.pathname === "/api/v1/cases/summaries") {
        if (url.searchParams.has("ids")) {
          if (condition === "failed")
            return Response.json({ error: { message: "Recheck unavailable" } }, { status: 500 });
          return Response.json({
            data:
              condition === "missing"
                ? []
                : [
                    {
                      ...reportCase(condition === "foreign" ? 52 : 51),
                      status: condition === "running" ? "running" : "resolved",
                      revision: condition === "changed" ? 8 : 7,
                    },
                  ],
            page: { next: null },
          });
        }
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      }
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText(
      condition === "failed"
        ? "Recheck unavailable"
        : i18n.t(condition === "changed" ? "cases.stateChanged" : "reports.caseUnavailable"),
    );
    expect(posted).toEqual([]);
  },
);

test("generation sends nothing when its request identity cannot be saved", async () => {
  await i18n.changeLanguage("en");
  const posted: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posted.push(url.pathname);
      return Response.json({ data: summary });
    }
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  const saving = vi.spyOn(sessionStorage, "setItem").mockImplementation(() => {
    throw new DOMException("Storage unavailable", "QuotaExceededError");
  });
  try {
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText("Could not save the request. No generation was submitted.");
    expect(posted).toEqual([]);
  } finally {
    saving.mockRestore();
  }
});

test.each(["closing", "changing accounts"])(
  "%s during a generation recheck aborts the read and cannot post afterward",
  async (interruption) => {
    await i18n.changeLanguage("en");
    let checking: Request | undefined;
    let finishCheck: ((response: Response) => void) | undefined;
    const posted: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      if (request.method === "POST") {
        posted.push(url.pathname);
        return Response.json({ data: summary });
      }
      if (url.pathname === "/api/v1/cases/summaries") {
        if (url.searchParams.has("ids")) {
          checking = request;
          return new Promise<Response>((resolve) => {
            finishCheck = resolve;
          });
        }
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      }
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    const view = showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await waitFor(() => expect(checking).toBeDefined());
    if (interruption === "closing")
      await user.click(screen.getByRole("button", { name: "Cancel" }));
    else view.rerender(reportEditor("operator-2"));
    expect(checking?.signal.aborted).toBe(true);
    await act(async () => {
      finishCheck?.(Response.json({ data: [reportCase(51)], page: { next: null } }));
    });
    expect(posted).toEqual([]);
  },
);

test("a rejected generation reports its error and does not retain a pending receipt or retry automatically", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    if (request.method === "POST")
      return Response.json({ error: { message: "Generation rejected" } }, { status: 409 });
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByText("Generation rejected");
  expect(
    (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
  ).toBe(false);
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(0);
});

test("a rejection arriving after the form closes releases only its own saved generation request", async () => {
  await i18n.changeLanguage("en");
  let finishPost: ((response: Response) => void) | undefined;
  const posted: string[] = [];
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    if (request.method === "POST") {
      posted.push(url.pathname);
      return new Promise<Response>((resolve) => {
        finishPost = resolve;
      });
    }
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await waitFor(() => expect(finishPost).toBeDefined());
  await user.click(screen.getByRole("button", { name: "Cancel" }));
  await act(async () => {
    finishPost?.(Response.json({ error: { message: "Generation rejected" } }, { status: 409 }));
  });
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByRole("group", { name: "Completed Case" });
  expect(screen.queryByRole("button", { name: "Check result" })).toBeNull();
  expect(posted).toHaveLength(1);
});

test("accepted generation keeps its receipt when the list refresh fails and checks it without reposting", async () => {
  await i18n.changeLanguage("en");
  const requests: string[] = [];
  let reportReads = 0;
  wire.mockImplementation(async (request: Request) => {
    const url = new URL(request.url);
    requests.push(`${request.method} ${url.pathname}`);
    const receipt = { ...summary, case_id: reportCase(51).id, case_revision: 7 };
    if (request.method === "POST") return Response.json({ data: receipt }, { status: 201 });
    if (url.pathname === "/api/v1/cases/summaries")
      return Response.json({ data: [reportCase(51)], page: { next: null } });
    if (url.pathname.endsWith("/reports/7")) return Response.json({ data: receipt });
    if (url.pathname === "/api/v1/reports") {
      reportReads++;
      if (reportReads === 2)
        return Response.json({ error: { message: "Accepted refresh failed" } }, { status: 500 });
    }
    if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
    return Response.json({ data: [], page: { next: null } });
  });
  showReportEditor();
  const user = await chooseCompletedCase();
  await user.click(screen.getByRole("button", { name: "Generate report" }));
  await screen.findByText("Could not confirm report generation. Check the result.");
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(0);
  await user.click(screen.getByRole("button", { name: "Check result" }));
  await waitFor(() => expect(screen.queryByRole("group", { name: "Completed Case" })).toBeNull());
  expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(1);
});

test.each(["foreign", "failed"])(
  "a %s generation receipt stays unknown and cannot enable another POST",
  async (condition) => {
    await i18n.changeLanguage("en");
    const requests: string[] = [];
    wire.mockImplementation(async (request: Request) => {
      const url = new URL(request.url);
      requests.push(`${request.method} ${url.pathname}`);
      if (request.method === "POST")
        return Response.json({ error: { message: "Lost generation response" } }, { status: 503 });
      if (url.pathname === "/api/v1/cases/summaries")
        return Response.json({ data: [reportCase(51)], page: { next: null } });
      if (url.pathname.endsWith("/reports/7"))
        return condition === "foreign"
          ? Response.json({ data: { ...summary, case_id: reportCase(52).id, case_revision: 7 } })
          : Response.json({ error: { message: "Receipt storage unavailable" } }, { status: 500 });
      if (url.pathname === "/api/v1/report-setting") return Response.json({ data: setting });
      return Response.json({ data: [], page: { next: null } });
    });
    showReportEditor();
    const user = await chooseCompletedCase();
    await user.click(screen.getByRole("button", { name: "Generate report" }));
    await screen.findByText("Could not confirm report generation. Check the result.");
    await user.click(screen.getByRole("button", { name: "Check result" }));
    await waitFor(() =>
      expect(requests.filter((item) => item.endsWith("/reports/7"))).toHaveLength(2),
    );
    await waitFor(() =>
      expect(
        (screen.getByRole("button", { name: "Check result" }) as HTMLButtonElement).disabled,
      ).toBe(false),
    );
    expect(
      (screen.getByRole("button", { name: "Generate report" }) as HTMLButtonElement).disabled,
    ).toBe(true);
    expect(requests.filter((item) => item.startsWith("POST"))).toHaveLength(1);
  },
);

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
