import {
  BellRing,
  Check,
  ChevronRight,
  CircleAlert,
  CircleDashed,
  FileText,
  ListTree,
  Search,
  ShieldCheck,
  Stethoscope,
  Wrench,
  type LucideIcon,
} from "lucide-react";
import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { summarizeValue, translatedToken } from "@/cases/detail-utils";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type CaseEvent = components["schemas"]["CaseEvent"];
type Turn = components["schemas"]["ResolverTurn"];
type Evidence = components["schemas"]["Evidence"];
type Approval = components["schemas"]["Approval"];
type Review = components["schemas"]["ReviewDecision"];
type Report = components["schemas"]["Report"];

type StageKey = "alert" | "investigate" | "review" | "remediate" | "verify" | "report" | "complete";
type StageState = "completed" | "current" | "attention" | "pending" | "skipped";

type Props = {
  snapshot: CaseSnapshot;
  timeline: CaseEvent[];
  turns: Turn[];
  evidence: Evidence[];
  approvals: Approval[];
  reviews: Review[];
  reports: Report[];
};

type Stage = {
  key: StageKey;
  icon: LucideIcon;
  state: StageState;
};

type LogEntry = {
  id: string;
  at: string;
  stage: StageKey;
  source: string;
  summary: string;
  details?: unknown;
  failed?: boolean;
};

const stageDefinitions: Array<{ key: StageKey; icon: LucideIcon }> = [
  { key: "alert", icon: BellRing },
  { key: "investigate", icon: Search },
  { key: "review", icon: ShieldCheck },
  { key: "remediate", icon: Wrench },
  { key: "verify", icon: Stethoscope },
  { key: "report", icon: FileText },
  { key: "complete", icon: Check },
];

export function CaseWorkflowView(props: Props) {
  const { t, i18n } = useTranslation();
  const projection = projectWorkflow(props);
  const log = buildLog(props, t);
  const logContainer = useRef<HTMLDivElement>(null);
  const followLatest = useRef(true);

  useEffect(() => {
    const node = logContainer.current;
    if (!node || !followLatest.current) return;
    window.requestAnimationFrame(() =>
      node.scrollTo({ top: node.scrollHeight, behavior: "smooth" }),
    );
  }, [log.length]);

  function trackLogPosition() {
    const node = logContainer.current;
    if (!node) return;
    followLatest.current = node.scrollHeight - node.scrollTop - node.clientHeight < 48;
  }

  return (
    <section className="space-y-4" aria-labelledby="case-workflow-title">
      <div>
        <h2 id="case-workflow-title" className="text-xl font-semibold">
          {t("cases.workflow.title")}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("cases.workflow.description")}</p>
      </div>

      <Card>
        <CardContent className="overflow-x-auto px-4 py-5 lg:px-6">
          <ol className="grid min-w-[56rem] grid-cols-7" aria-label={t("cases.workflow.progress")}>
            {projection.stages.map((stage, index) => (
              <WorkflowStage
                key={stage.key}
                stage={stage}
                first={index === 0}
                last={index === projection.stages.length - 1}
              />
            ))}
          </ol>
          <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t pt-4">
            <div>
              <p className="text-sm font-medium">
                {t(`cases.workflow.stages.${projection.current}.label`)}
              </p>
              <p className="mt-1 text-sm text-muted-foreground">
                {t(`cases.workflow.stages.${projection.current}.description`)}
              </p>
            </div>
            <div className="flex items-center gap-4 text-xs text-muted-foreground">
              <Legend state="current" label={t("cases.workflow.current")} />
              <Legend state="completed" label={t("cases.workflow.completed")} />
              <Legend state="skipped" label={t("cases.workflow.skipped")} />
            </div>
          </div>
        </CardContent>
      </Card>

      <Card className="gap-0 overflow-hidden py-0">
        <CardHeader className="border-b bg-muted/30 px-4 py-3">
          <CardTitle className="flex items-center justify-between gap-3 text-sm">
            <span className="flex items-center gap-2">
              <ListTree className="size-4 text-muted-foreground" />
              {t("cases.workflow.logTitle")}
            </span>
            <span className="text-xs font-normal text-muted-foreground" aria-live="polite">
              {t("cases.workflow.logCount", { count: log.length })}
            </span>
          </CardTitle>
        </CardHeader>
        <CardContent
          ref={logContainer}
          className="max-h-[32rem] overflow-auto px-0 text-sm"
          onScroll={trackLogPosition}
        >
          {log.length === 0 ? (
            <p className="px-4 py-8 text-center text-muted-foreground">
              {t("cases.workflow.noLogs")}
            </p>
          ) : (
            log.map((entry, index) => (
              <ExecutionLogRow
                key={entry.id}
                entry={entry}
                locale={i18n.resolvedLanguage ?? "en"}
                latest={index === log.length - 1}
              />
            ))
          )}
        </CardContent>
      </Card>
    </section>
  );
}

function WorkflowStage({ stage, first, last }: { stage: Stage; first: boolean; last: boolean }) {
  const { t } = useTranslation();
  const Icon = stage.icon;
  const active = stage.state === "current" || stage.state === "attention";

  return (
    <li className="relative flex flex-col items-center text-center">
      {!first && (
        <span
          className={cn(
            "absolute left-0 top-5 h-0.5 w-1/2",
            stage.state === "pending" ? "bg-border" : "bg-primary/55",
          )}
          aria-hidden="true"
        />
      )}
      {!last && (
        <span
          className={cn(
            "absolute right-0 top-5 h-0.5 w-1/2",
            stage.state === "completed" || active ? "bg-primary/55" : "bg-border",
          )}
          aria-hidden="true"
        />
      )}
      <span
        className={cn(
          "relative z-10 flex size-10 items-center justify-center rounded-full border-2 bg-background transition",
          stage.state === "completed" && "border-primary bg-primary text-primary-foreground",
          stage.state === "current" &&
            "border-primary text-primary shadow-[0_0_0_5px_color-mix(in_oklab,var(--primary)_18%,transparent),0_0_24px_color-mix(in_oklab,var(--primary)_45%,transparent)]",
          stage.state === "attention" &&
            "border-destructive text-destructive shadow-[0_0_0_5px_color-mix(in_oklab,var(--destructive)_18%,transparent),0_0_24px_color-mix(in_oklab,var(--destructive)_40%,transparent)]",
          stage.state === "pending" && "border-border text-muted-foreground",
          stage.state === "skipped" &&
            "border-dashed border-muted-foreground/50 text-muted-foreground",
        )}
      >
        {stage.state === "completed" ? (
          <Check className="size-4" />
        ) : stage.state === "attention" ? (
          <CircleAlert className="size-4" />
        ) : stage.state === "pending" || stage.state === "skipped" ? (
          <CircleDashed className="size-4" />
        ) : (
          <Icon className="size-4 animate-pulse" />
        )}
      </span>
      <span
        className={cn(
          "mt-2 max-w-28 text-xs font-medium",
          active ? "text-foreground" : "text-muted-foreground",
        )}
      >
        {t(`cases.workflow.stages.${stage.key}.label`)}
      </span>
    </li>
  );
}

function Legend({ state, label }: { state: "current" | "completed" | "skipped"; label: string }) {
  return (
    <span className="flex items-center gap-1.5">
      <span
        className={cn(
          "size-2.5 rounded-full border",
          state === "current" && "border-primary bg-primary/25 shadow-[0_0_8px_var(--primary)]",
          state === "completed" && "border-primary bg-primary",
          state === "skipped" && "border-dashed border-muted-foreground",
        )}
      />
      {label}
    </span>
  );
}

function ExecutionLogRow({
  entry,
  locale,
  latest,
}: {
  entry: LogEntry;
  locale: string;
  latest: boolean;
}) {
  const { t } = useTranslation();
  return (
    <details className="group border-b last:border-b-0" open={latest}>
      <summary className="grid cursor-pointer list-none grid-cols-[auto_auto_minmax(0,1fr)] items-start gap-3 px-4 py-3 hover:bg-muted/40">
        <ChevronRight className="mt-0.5 size-3.5 text-muted-foreground transition-transform group-open:rotate-90" />
        <time className="whitespace-nowrap font-mono text-xs text-muted-foreground">
          {formatLogTime(entry.at, locale)}
        </time>
        <span className="min-w-0">
          <span className={entry.failed ? "text-destructive" : "font-medium text-primary"}>
            [{t(`cases.workflow.stages.${entry.stage}.label`)}]
          </span>{" "}
          <span className="text-muted-foreground">{entry.source}</span>{" "}
          <span className={entry.failed ? "text-destructive" : "text-foreground"}>
            {entry.summary}
          </span>
        </span>
      </summary>
      {entry.details !== undefined && (
        <pre className="overflow-x-auto border-t bg-muted/25 px-10 py-3 font-mono text-xs leading-relaxed text-muted-foreground">
          {JSON.stringify(entry.details, null, 2)}
        </pre>
      )}
    </details>
  );
}

function projectWorkflow(props: Props): { current: StageKey; stages: Stage[] } {
  const { snapshot, timeline, turns, evidence, approvals, reviews, reports } = props;
  const incident = snapshot.case;
  const latestRun = [...snapshot.resolution_runs].sort((a, b) => b.generation - a.generation)[0];
  const runId = latestRun?.id;
  const inRun = <T extends { resolution_run_id: string }>(items: T[]) =>
    runId ? items.filter((item) => item.resolution_run_id === runId) : items;
  const runTurns = inRun(turns);
  const runProposals = inRun(snapshot.proposals);
  const runOperations = inRun(snapshot.operations);
  const runVerifications = inRun(snapshot.verification_attempts);
  const runEvidence = inRun(evidence);
  const runApprovals = inRun(approvals);
  const runReviews = inRun(reviews);
  const exactReport = reports.find((report) => report.case_revision === incident.revision);
  const reportFailed = timeline.some((event) => event.type === "report_generation_failed");

  let current: StageKey;
  let attention = incident.status === "needs_attention" || incident.status === "cancelled";

  if (incident.status === "resolved") {
    current = exactReport ? "complete" : "report";
    attention = reportFailed && !exactReport;
  } else {
    const activity: Array<{ stage: StageKey; at: string }> = [
      ...runTurns.map((item) => ({ stage: "investigate" as const, at: item.updated_at })),
      ...runProposals.map((item) => ({ stage: "review" as const, at: item.updated_at })),
      ...runReviews.map((item) => ({ stage: "review" as const, at: item.decided_at })),
      ...runApprovals.map((item) => ({ stage: "review" as const, at: item.decided_at })),
      ...runOperations.map((item) => ({ stage: "remediate" as const, at: item.updated_at })),
      ...runVerifications.map((item) => ({
        stage: "verify" as const,
        at: item.completed_at ?? item.accepted_at,
      })),
    ];
    current = activity.sort((a, b) => a.at.localeCompare(b.at)).at(-1)?.stage ?? "investigate";
    if (incident.alert_state === "recovered" && current === "investigate") current = "verify";
  }

  const occurred: Record<StageKey, boolean> = {
    alert: true,
    investigate: runTurns.length > 0 || runEvidence.length > 0,
    review: runProposals.length > 0 || runReviews.length > 0 || runApprovals.length > 0,
    remediate: runOperations.length > 0,
    verify:
      runVerifications.length > 0 ||
      runEvidence.some((item) =>
        ["target_verification", "verification_result"].includes(item.kind),
      ),
    report: Boolean(exactReport),
    complete: Boolean(exactReport && incident.status === "resolved"),
  };
  const currentIndex = stageDefinitions.findIndex((stage) => stage.key === current);

  return {
    current,
    stages: stageDefinitions.map((stage, index) => ({
      ...stage,
      state:
        index === currentIndex
          ? attention
            ? "attention"
            : "current"
          : index > currentIndex
            ? "pending"
            : occurred[stage.key]
              ? "completed"
              : "skipped",
    })),
  };
}

function buildLog(props: Props, t: ReturnType<typeof useTranslation>["t"]): LogEntry[] {
  const entries: LogEntry[] = [];

  for (const event of props.timeline) {
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
    const decision = turn.decision ?? turn.outcome ?? turn.progress_kind ?? turn.status;
    entries.push({
      id: `turn-${turn.id}`,
      at: turn.completed_at ?? turn.updated_at,
      stage: "investigate",
      source: t("cases.workflow.sources.resolver"),
      summary: `${t("cases.turnTitle", { ordinal: turn.ordinal })} · ${summarizeValue(decision, turn.status)}`,
      details: {
        intent: turn.intent,
        decision: turn.decision,
        outcome: turn.outcome,
        failure_category: turn.failure_category,
        failure_message: turn.failure_message,
      },
      failed: Boolean(turn.failure_message),
    });
  }

  for (const item of props.evidence) {
    entries.push({
      id: `evidence-${item.id}`,
      at: item.observed_at,
      stage: stageForEvidence(item.kind),
      source: item.source,
      summary: summarizeValue(item.content, translatedToken(t, "evidenceKind", item.kind)),
      details: item.content,
    });
  }

  for (const item of props.reviews) {
    entries.push({
      id: `review-${item.id}`,
      at: item.decided_at,
      stage: "review",
      source: t("cases.workflow.sources.reviewer"),
      summary: `${translatedToken(t, "decision", item.verdict)} · ${item.reason}`,
      details: {
        verdict: item.verdict,
        selection_source: item.selection_source,
        category: item.category,
        usage: { input_tokens: item.input_tokens, output_tokens: item.output_tokens },
      },
      failed: item.outcome === "delivery_failed",
    });
  }

  for (const item of props.approvals) {
    entries.push({
      id: `approval-${item.id}`,
      at: item.decided_at,
      stage: "review",
      source: translatedToken(t, "decisionSource", item.source),
      summary: `${translatedToken(t, "decision", item.decision)} · ${item.reason}`,
    });
  }

  for (const item of props.snapshot.operations) {
    entries.push({
      id: `operation-${item.id}`,
      at: item.completed_at ?? item.updated_at,
      stage: "remediate",
      source: t("cases.workflow.sources.executor"),
      summary: `${item.capability} / ${item.operation} · ${translatedToken(t, "operationStatus", item.status)}`,
      details: {
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
    entries.push({
      id: `verification-${item.id}`,
      at: item.completed_at ?? item.accepted_at,
      stage: "verify",
      source: t("cases.workflow.sources.verifier"),
      summary: `${item.capability} / ${item.operation} · ${item.status}`,
      details: {
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
      summary: t("cases.workflow.reportGenerated", { language: item.language.toUpperCase() }),
      details: { revision: item.case_revision, outcome: item.outcome, digest: item.content_digest },
    });
  }

  return entries.sort((a, b) => a.at.localeCompare(b.at) || a.id.localeCompare(b.id));
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

function formatLogTime(value: string, locale: string) {
  return new Intl.DateTimeFormat(locale, {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}
