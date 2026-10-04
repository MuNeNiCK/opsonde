import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";

type Approval = components["schemas"]["Approval"];
type CaseEvent = components["schemas"]["CaseEvent"];
type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type Evidence = components["schemas"]["EvidenceSummary"];
type ReviewDecision = components["schemas"]["ReviewDecision"];
type Turn = components["schemas"]["ResolverTurnSummary"];
type Proposal = components["schemas"]["Proposal"];
type ProposalSummary = components["schemas"]["ProposalSummary"];
type Provider = Pick<components["schemas"]["ProviderSummary"], "id" | "name">;
type AccessMethod = Pick<
  components["schemas"]["AccessMethod"],
  "id" | "name" | "method" | "target_id"
>;
type Target = Pick<components["schemas"]["TargetSummary"], "id" | "name" | "kind" | "type_id">;
export type HistoryCursor = Record<
  | "timeline"
  | "turns"
  | "proposals"
  | "conditionHistory"
  | "evidence"
  | "approvals"
  | "reviews"
  | "aiInvocations"
  | "operations"
  | "verifications",
  string | null
>;

export type CaseWindow = {
  snapshot: CaseSnapshot;
  timeline: CaseEvent[];
  turns: Turn[];
  proposals: ProposalSummary[];
  conditionHistory: components["schemas"]["CaseConditionMembership"][];
  awaitingProposal: Proposal | null;
  proposalError: Error | null;
  evidence: Evidence[];
  approvals: Approval[];
  reviews: ReviewDecision[];
  aiInvocations: components["schemas"]["AIInvocation"][];
  operations: components["schemas"]["OperationSummary"][];
  verifications: components["schemas"]["VerificationAttemptSummary"][];
  targets: Target[];
  methods: AccessMethod[];
  providers: Provider[];
  report: components["schemas"]["Report"] | null;
  reportError: Error | null;
  historyNext: HistoryCursor;
};

type CaseState = Pick<
  CaseWindow,
  | "snapshot"
  | "timeline"
  | "turns"
  | "proposals"
  | "conditionHistory"
  | "awaitingProposal"
  | "proposalError"
  | "evidence"
  | "approvals"
  | "reviews"
  | "aiInvocations"
  | "operations"
  | "verifications"
  | "report"
  | "reportError"
  | "historyNext"
>;
type References = Pick<CaseWindow, "targets" | "methods" | "providers">;

function loadHistoryPage<T>(
  cursor: string | null | undefined,
  load: (after: string | undefined) => Promise<{ data: T[]; page: { next: string | null } }>,
) {
  return cursor === null ? Promise.resolve({ data: [], page: { next: null } }) : load(cursor);
}

async function loadCaseState(
  caseId: string,
  cursor: HistoryCursor | undefined,
  signal: AbortSignal,
): Promise<CaseState> {
  const [
    snapshotResponse,
    timeline,
    turns,
    proposals,
    conditionHistory,
    evidence,
    approvals,
    reviews,
    aiInvocations,
    operations,
    verifications,
  ] = await Promise.all([
    apiClient.GET("/api/v1/cases/{id}", { signal, params: { path: { id: caseId } } }).then(apiData),
    loadHistoryPage(cursor?.timeline, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/timeline", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.turns, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/turns", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.proposals, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/proposals", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.conditionHistory, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/condition-history", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.evidence, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/evidence", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.approvals, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/approvals", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.reviews, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/review-decisions", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.aiInvocations, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/ai-invocations", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.operations, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/operations", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    loadHistoryPage(cursor?.verifications, (after) =>
      apiClient
        .GET("/api/v1/cases/{id}/verification-attempts", {
          signal,
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
  ]);
  const snapshot = snapshotResponse.data;
  const currentReport =
    snapshot.case.status === "resolved"
      ? snapshot.reports.find((report) => report.case_revision === snapshot.case.revision)
      : undefined;
  let reportError: Error | null = null;
  let proposalError: Error | null = null;
  const pendingProposalId = snapshot.case.pending_proposal_id;
  const [report, awaitingProposal] = await Promise.all([
    currentReport
      ? apiClient
          .GET("/api/v1/reports/{id}", { signal, params: { path: { id: currentReport.id } } })
          .then(apiData)
          .then((response) => response.data)
          .catch((error: unknown) => {
            reportError = error instanceof Error ? error : new Error();
            return null;
          })
      : null,
    pendingProposalId
      ? apiClient
          .GET("/api/v1/proposals/{id}", { signal, params: { path: { id: pendingProposalId } } })
          .then(apiData)
          .then((response) => response.data)
          .catch((error: unknown) => {
            proposalError = error instanceof Error ? error : new Error();
            return null;
          })
      : null,
  ]);

  return {
    snapshot: snapshotResponse.data,
    timeline: timeline.data,
    turns: turns.data,
    proposals: proposals.data,
    conditionHistory: conditionHistory.data,
    awaitingProposal,
    proposalError,
    evidence: evidence.data,
    approvals: approvals.data,
    reviews: reviews.data,
    aiInvocations: aiInvocations.data,
    operations: operations.data,
    verifications: verifications.data,
    report,
    reportError,
    historyNext: {
      timeline: timeline.page.next,
      turns: turns.page.next,
      proposals: proposals.page.next,
      conditionHistory: conditionHistory.page.next,
      evidence: evidence.page.next,
      approvals: approvals.page.next,
      reviews: reviews.page.next,
      aiInvocations: aiInvocations.page.next,
      operations: operations.page.next,
      verifications: verifications.page.next,
    },
  };
}

function idBatches(values: Array<string | null | undefined>) {
  const ids = [...new Set(values.filter((id): id is string => Boolean(id)))];
  return Array.from({ length: Math.ceil(ids.length / 100) }, (_, index) =>
    ids.slice(index * 100, (index + 1) * 100),
  );
}

async function loadReferences(state: CaseState, signal: AbortSignal): Promise<References> {
  const proposals = state.awaitingProposal
    ? [...state.proposals, state.awaitingProposal]
    : state.proposals;
  const targetIds = idBatches([
    state.snapshot.case.initial_target_id,
    state.snapshot.case.selected_target_id,
    ...proposals.map((item) => item.target_id),
    ...state.operations.map((item) => item.target_id),
    ...state.verifications.map((item) => item.target_id),
    ...state.turns.flatMap((turn) => [
      turn.summary.target_id,
      turn.summary.relationship?.source_target_id,
      turn.summary.relationship?.destination_target_id,
    ]),
  ]);
  const methodIds = idBatches(proposals.map((item) => item.access_method_id));
  const providerIds = idBatches([state.awaitingProposal?.provider_id]);
  const [targets, methods, providers] = await Promise.all([
    Promise.all(
      targetIds.map((ids) =>
        apiClient
          .GET("/api/v1/targets/summaries", {
            params: { query: { ids, limit: 100 } },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData)
          .then((page) => page.data),
      ),
    ).then((pages) => pages.flat()),
    Promise.all(
      methodIds.map((ids) =>
        apiClient
          .GET("/api/v1/access-methods", {
            params: { query: { ids, limit: 100 } },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData)
          .then((page) => page.data),
      ),
    ).then((pages) => pages.flat()),
    Promise.all(
      providerIds.map((ids) =>
        apiClient
          .GET("/api/v1/providers/summaries", {
            params: { query: { ids, limit: 100 } },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData)
          .then((page) => page.data),
      ),
    ).then((pages) => pages.flat()),
  ]);
  return { targets, methods, providers };
}

export async function loadCaseWindow(
  caseId: string,
  cursor: HistoryCursor | undefined,
  signal: AbortSignal,
): Promise<CaseWindow> {
  const state = await loadCaseState(caseId, cursor, signal);
  signal.throwIfAborted();
  const references = await loadReferences(state, signal);
  signal.throwIfAborted();
  return { ...state, ...references };
}
