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
import {
  buildLog,
  type LogEntry,
  type StageKey,
  type WorkflowLogInput,
} from "@/cases/workflow-log";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

type StageState = "completed" | "current" | "attention" | "pending" | "skipped";

type Props = WorkflowLogInput;

type Stage = {
  key: StageKey;
  icon: LucideIcon;
  state: StageState;
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
            <span className="flex items-center gap-2">
              <Badge variant="outline">
                {t("cases.workflow.aiLanguage", {
                  language: props.snapshot.case.report_language.toUpperCase(),
                })}
              </Badge>
              <span className="text-xs font-normal text-muted-foreground" aria-live="polite">
                {t("cases.workflow.logCount", { count: log.length })}
              </span>
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
            log.map((entry) => (
              <ExecutionLogRow
                key={entry.id}
                entry={entry}
                locale={i18n.resolvedLanguage ?? "en"}
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

function ExecutionLogRow({ entry, locale }: { entry: LogEntry; locale: string }) {
  const { t } = useTranslation();
  return (
    <article className="grid grid-cols-[auto_minmax(0,1fr)] gap-3 border-b px-4 py-4 last:border-b-0">
      <div>
        <time className="whitespace-nowrap font-mono text-xs text-muted-foreground">
          {formatLogTime(entry.at, locale)}
        </time>
      </div>
      <div className="min-w-0 space-y-2">
        <div className="flex flex-wrap items-center gap-2">
          <Badge variant={entry.failed ? "destructive" : "secondary"}>
            {t(`cases.workflow.stages.${entry.stage}.label`)}
          </Badge>
          <span className="text-xs font-medium text-muted-foreground">{entry.source}</span>
          {entry.modelLanguage && (
            <Badge variant="outline">AI · {entry.modelLanguage.toUpperCase()}</Badge>
          )}
        </div>
        <p className={entry.failed ? "text-sm text-destructive" : "text-sm text-foreground"}>
          {entry.summary}
        </p>
        {entry.facts && entry.facts.length > 0 && (
          <dl className="grid gap-2 rounded-md bg-muted/35 p-3 sm:grid-cols-2">
            {entry.facts.map((fact) => (
              <div key={`${fact.label}-${fact.value}`} className="min-w-0">
                <dt className="text-xs font-medium text-muted-foreground">{fact.label}</dt>
                <dd className="mt-0.5 break-words text-sm">{fact.value}</dd>
              </div>
            ))}
          </dl>
        )}
        {entry.technical !== undefined && (
          <details className="group">
            <summary className="flex w-fit cursor-pointer list-none items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground">
              <ChevronRight className="size-3.5 transition-transform group-open:rotate-90" />
              {t("cases.workflow.technicalDetails")}
            </summary>
            <pre className="mt-2 max-h-64 overflow-auto rounded-md bg-muted/45 p-3 font-mono text-xs leading-relaxed text-muted-foreground">
              {JSON.stringify(entry.technical, null, 2)}
            </pre>
          </details>
        )}
      </div>
    </article>
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
  const observationOperations = runOperations.filter((item) => item.request_kind === "observation");
  const effectOperations = runOperations.filter((item) => item.request_kind === "effect");
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
      ...observationOperations.map((item) => ({
        stage: "investigate" as const,
        at: item.updated_at,
      })),
      ...runProposals.map((item) => ({ stage: "review" as const, at: item.updated_at })),
      ...runReviews.map((item) => ({ stage: "review" as const, at: item.decided_at })),
      ...runApprovals.map((item) => ({ stage: "review" as const, at: item.decided_at })),
      ...effectOperations.map((item) => ({ stage: "remediate" as const, at: item.updated_at })),
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
    investigate: runTurns.length > 0 || runEvidence.length > 0 || observationOperations.length > 0,
    review: runProposals.length > 0 || runReviews.length > 0 || runApprovals.length > 0,
    remediate: effectOperations.length > 0,
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

function formatLogTime(value: string, locale: string) {
  return new Intl.DateTimeFormat(locale, {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}
