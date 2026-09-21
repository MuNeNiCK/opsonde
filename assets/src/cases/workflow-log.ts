import type { TFunction } from "i18next";
import type { components } from "@/api/schema";
import { translatedToken } from "@/cases/detail-utils";

type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type CaseEvent = components["schemas"]["CaseEvent"];
type Turn = components["schemas"]["ResolverTurn"];
type Evidence = components["schemas"]["Evidence"];
type Approval = components["schemas"]["Approval"];
type Review = components["schemas"]["ReviewDecision"];
type Report = components["schemas"]["Report"];

export type StageKey =
  | "alert"
  | "investigate"
  | "review"
  | "remediate"
  | "verify"
  | "report"
  | "complete";

export type WorkflowLogInput = {
  snapshot: CaseSnapshot;
  timeline: CaseEvent[];
  turns: Turn[];
  evidence: Evidence[];
  approvals: Approval[];
  reviews: Review[];
  reports: Report[];
};

export type LogEntry = {
  id: string;
  at: string;
  stage: StageKey;
  source: string;
  summary: string;
  facts?: Array<{ label: string; value: string }>;
  technical?: unknown;
  failed?: boolean;
};

const hiddenRoutineEvents = new Set([
  "budget_charged",
  "effect_budget_charged",
  "evidence_added",
  "resolver_assigned",
  "reviewer_assigned",
  "resolver_decision_routed",
  "turn_started",
  "turn_completed",
  "verification_budget_charged",
]);

export function buildLog(props: WorkflowLogInput, t: TFunction): LogEntry[] {
  const entries: LogEntry[] = [];
  const reviewedProposalIds = new Set(props.reviews.map((review) => review.proposal_id));

  for (const event of props.timeline) {
    if (hiddenRoutineEvents.has(event.type)) continue;
    entries.push({
      id: `event-${event.id}`,
      at: event.inserted_at,
      stage: stageForEvent(event.type),
      source: t("cases.workflow.sources.system"),
      summary: translatedToken(t, "event", event.type),
      failed: event.type === "report_generation_failed",
    });
  }

  for (const turn of props.turns) {
    const decision = recordValue(turn.decision);
    const reason = textField(decision, "reason");
    const intentType = textField(decision, "type");
    const tool = recordValue(decision?.tool);
    const selectedAction = [textField(tool, "capability"), textField(tool, "operation")]
      .filter(Boolean)
      .join(" / ");
    const selectors = compactRecord(decision?.selectors);
    const failure = turn.failure_message ?? "";
    entries.push({
      id: `turn-${turn.id}`,
      at: turn.completed_at ?? turn.updated_at,
      stage: "investigate",
      source: t("cases.workflow.sources.resolver"),
      summary:
        failure ||
        reason ||
        `${t("cases.turnTitle", { ordinal: turn.ordinal })} · ${translatedToken(t, "progress", turn.progress_kind ?? turn.status)}`,
      facts: compactFacts([
        intentType && {
          label: t("cases.workflow.fields.decision"),
          value: translatedToken(t, "intentType", intentType),
        },
        selectedAction && {
          label: t("cases.workflow.fields.selectedAction"),
          value: selectedAction,
        },
        selectors && { label: t("cases.workflow.fields.target"), value: selectors },
        turn.failure_category && {
          label: t("cases.workflow.fields.failure"),
          value: translatedToken(t, "failure", turn.failure_category),
        },
      ]),
      technical: {
        intent: turn.intent,
        decision: turn.decision,
        outcome: turn.outcome,
        failure_category: turn.failure_category,
        failure_message: turn.failure_message,
      },
      failed: Boolean(failure),
    });
  }

  for (const item of props.evidence) {
    const presentation = presentEvidence(item, t);
    entries.push({
      id: `evidence-${item.id}`,
      at: item.observed_at,
      stage: stageForEvidence(item.kind),
      source: item.source,
      summary: presentation.summary,
      facts: presentation.facts,
      technical: item.content,
      failed: item.kind.endsWith("_error"),
    });
  }

  for (const item of props.reviews) {
    entries.push({
      id: `review-${item.id}`,
      at: item.decided_at,
      stage: "review",
      source: t("cases.workflow.sources.reviewer"),
      summary: `${translatedToken(t, "decision", item.verdict)} · ${item.reason}`,
      facts: compactFacts([
        {
          label: t("cases.workflow.fields.decision"),
          value: translatedToken(t, "decision", item.verdict),
        },
        item.category && { label: t("cases.workflow.fields.category"), value: item.category },
      ]),
      technical: {
        verdict: item.verdict,
        selection_source: item.selection_source,
        category: item.category,
        usage: { input_tokens: item.input_tokens, output_tokens: item.output_tokens },
      },
      failed: item.outcome === "delivery_failed",
    });
  }

  for (const item of props.approvals) {
    if (item.source === "reviewer" && reviewedProposalIds.has(item.proposal_id)) continue;

    entries.push({
      id: `approval-${item.id}`,
      at: item.decided_at,
      stage: "review",
      source: translatedToken(t, "decisionSource", item.source),
      summary: `${translatedToken(t, "decision", item.decision)} · ${item.reason}`,
    });
  }

  for (const item of props.snapshot.operations) {
    const selectors = compactRecord(item.selectors);
    entries.push({
      id: `operation-${item.id}`,
      at: item.completed_at ?? item.updated_at,
      stage: "remediate",
      source: t("cases.workflow.sources.executor"),
      summary: `${item.capability} / ${item.operation} · ${translatedToken(t, "operationStatus", item.status)}`,
      facts: compactFacts([
        selectors && { label: t("cases.workflow.fields.target"), value: selectors },
        item.outcome_category && {
          label: t("cases.workflow.fields.result"),
          value: item.outcome_category,
        },
      ]),
      technical: {
        selectors: item.selectors,
        parameters: item.parameters,
        outcome_category: item.outcome_category,
        reference: item.reference,
        result: item.result_details,
      },
      failed: ["failed", "partial", "unknown"].includes(item.status),
    });
  }

  for (const item of props.snapshot.verification_attempts) {
    const expected = compactRecord(item.expected);
    const observed = compactRecord(item.facts);
    entries.push({
      id: `verification-${item.id}`,
      at: item.completed_at ?? item.accepted_at,
      stage: "verify",
      source: t("cases.workflow.sources.verifier"),
      summary: `${item.capability} / ${item.operation} · ${translatedToken(t, "verificationStatus", item.status)}`,
      facts: compactFacts([
        expected && { label: t("cases.workflow.fields.expected"), value: expected },
        observed && { label: t("cases.workflow.fields.observed"), value: observed },
      ]),
      technical: {
        expected: item.expected,
        facts: item.facts,
        evidence: item.provider_evidence,
        outcome_category: item.outcome_category,
      },
      failed: ["not_verified", "unknown"].includes(item.status),
    });
  }

  for (const item of props.reports) {
    entries.push({
      id: `report-${item.id}`,
      at: item.generated_at,
      stage: "report",
      source: t("cases.workflow.sources.reporter"),
      summary: t("cases.workflow.reportGenerated"),
      technical: {
        revision: item.case_revision,
        outcome: item.outcome,
        digest: item.content_digest,
      },
    });
  }

  return entries.sort((a, b) => a.at.localeCompare(b.at) || a.id.localeCompare(b.id));
}

function presentEvidence(item: Evidence, t: TFunction): Pick<LogEntry, "summary" | "facts"> {
  const content = recordValue(item.content) ?? {};
  const attributes = recordValue(content.attributes);
  const annotations = recordValue(attributes?.annotations);
  const targetRef = recordValue(content.target_ref);
  const status = textField(content, "status") || textField(content, "state");
  const category = textField(content, "category");
  const message =
    textField(content, "message") ||
    textField(annotations, "description") ||
    textField(annotations, "summary") ||
    textField(attributes, "title");
  const observed = compactRecord(content.facts);
  const target = textField(targetRef, "value") || textField(content, "target_id");

  return {
    summary: message || translatedToken(t, "evidenceKind", item.kind),
    facts: compactFacts([
      status && {
        label: t("cases.workflow.fields.result"),
        value:
          item.kind === "signal_event"
            ? translatedToken(t, "alert", status)
            : translatedToken(t, "operationStatus", status),
      },
      category && {
        label: t("cases.workflow.fields.category"),
        value: translatedToken(t, "failure", category),
      },
      target && { label: t("cases.workflow.fields.target"), value: target },
      observed && { label: t("cases.workflow.fields.observed"), value: observed },
    ]),
  };
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function textField(record: Record<string, unknown> | null | undefined, key: string) {
  const value = record?.[key];
  return typeof value === "string" && value.length > 0 ? value : "";
}

function compactRecord(value: unknown) {
  const record = recordValue(value);
  if (!record) return "";
  return Object.entries(record)
    .filter((entry): entry is [string, string | number | boolean] =>
      ["string", "number", "boolean"].includes(typeof entry[1]),
    )
    .slice(0, 8)
    .map(([key, item]) => `${key.replaceAll("_", " ")}: ${String(item)}`)
    .join(" · ");
}

function compactFacts(
  values: Array<{ label: string; value: string } | "" | null | undefined | false>,
) {
  return values.filter((value): value is { label: string; value: string } => Boolean(value));
}

function stageForEvent(type: string): StageKey {
  if (type.includes("report")) return "report";
  if (type.includes("verification") || type === "source_recovered") return "verify";
  if (type.includes("effect") || type.includes("operation")) return "remediate";
  if (type.includes("review") || type.includes("proposal")) return "review";
  if (type === "case_resolved") return "verify";
  if (type === "case_opened" || type.startsWith("signal_")) return "alert";
  return "investigate";
}

function stageForEvidence(kind: string): StageKey {
  if (["target_verification", "verification_result", "source_recovery"].includes(kind)) {
    return "verify";
  }
  if (kind === "operation_result") return "remediate";
  if (kind === "signal_event") return "alert";
  return "investigate";
}
