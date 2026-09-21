import {
  BellRing,
  Check,
  ChevronRight,
  CircleAlert,
  CircleDashed,
  FileText,
  ListTree,
  Network,
  Repeat2,
  type LucideIcon,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { InvestigationMap } from "@/cases/investigation-map";
import { buildLog, type LogEntry, type WorkflowLogInput } from "@/cases/workflow-log";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";

type Target = components["schemas"]["Target"];
type AccessMethod = components["schemas"]["AccessMethod"];
type Props = WorkflowLogInput & { targets: Target[]; methods: AccessMethod[] };
type PhaseState = "completed" | "current" | "attention" | "pending";
type PhaseKey = "alert" | "resolution" | "report" | "complete";
type Phase = { key: PhaseKey; icon: LucideIcon; state: PhaseState };

const phaseDefinitions: Array<Omit<Phase, "state">> = [
  { key: "alert", icon: BellRing },
  { key: "resolution", icon: Repeat2 },
  { key: "report", icon: FileText },
  { key: "complete", icon: Check },
];

export function CaseWorkflowView(props: Props) {
  const { t, i18n } = useTranslation();
  const phases = projectProgress(props);
  const log = buildLog(props, t);
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null);
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

  function selectLog(id: string) {
    followLatest.current = id === log.at(-1)?.id;
    setSelectedLogId(id);
  }

  return (
    <section className="space-y-3" aria-labelledby="case-workflow-title">
      <h2 id="case-workflow-title" className="text-xl font-semibold">
        {t("cases.workflow.title")}
      </h2>

      <Card className="gap-0 overflow-hidden py-0">
        <CardContent className="border-b px-4 py-4 lg:px-6">
          <ol
            className="mx-auto grid min-w-[36rem] max-w-4xl grid-cols-4"
            aria-label={t("cases.workflow.progress")}
          >
            {phases.map((phase, index) => (
              <ProgressPhase
                key={phase.key}
                phase={phase}
                first={index === 0}
                last={index === phases.length - 1}
              />
            ))}
          </ol>
        </CardContent>

        <div className="grid xl:grid-cols-[minmax(0,1.7fr)_minmax(24rem,0.8fr)]">
          <section className="min-w-0" aria-labelledby="investigation-map-title">
            <header className="flex h-12 items-center justify-between gap-3 border-b bg-muted/20 px-4">
              <h3
                id="investigation-map-title"
                className="flex items-center gap-2 text-sm font-semibold"
              >
                <Network className="size-4 text-primary" />
                {t("cases.workflow.map.title")}
              </h3>
              <span className="text-xs text-muted-foreground">
                {t("cases.workflow.map.turnCount", { count: props.turns.length })}
              </span>
            </header>
            <div className="h-[31rem] bg-muted/[0.08]">
              <InvestigationMap {...props} selectedLogId={selectedLogId} onSelectLog={selectLog} />
            </div>
          </section>

          <section
            className="min-w-0 border-t xl:border-l xl:border-t-0"
            aria-labelledby="execution-history-title"
          >
            <header className="flex h-12 items-center justify-between gap-3 border-b bg-muted/20 px-4">
              <h3
                id="execution-history-title"
                className="flex items-center gap-2 text-sm font-semibold"
              >
                <ListTree className="size-4 text-muted-foreground" />
                {t("cases.workflow.logTitle")}
              </h3>
              <span className="text-xs text-muted-foreground" aria-live="polite">
                {t("cases.workflow.logCount", { count: log.length })}
              </span>
            </header>
            <div
              ref={logContainer}
              className="h-[31rem] overflow-auto text-sm"
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
                    selected={entry.id === selectedLogId}
                    latest={index === log.length - 1}
                    onSelect={() => selectLog(entry.id)}
                  />
                ))
              )}
            </div>
          </section>
        </div>
      </Card>
    </section>
  );
}

function ProgressPhase({ phase, first, last }: { phase: Phase; first: boolean; last: boolean }) {
  const { t } = useTranslation();
  const Icon = phase.icon;
  const active = phase.state === "current" || phase.state === "attention";

  return (
    <li className="relative flex items-center justify-center gap-2">
      {!first && (
        <span
          className={cn(
            "absolute left-0 top-1/2 h-px w-1/2 bg-border",
            phase.state !== "pending" && "bg-primary/55",
          )}
          aria-hidden="true"
        />
      )}
      {!last && (
        <span
          className={cn(
            "absolute right-0 top-1/2 h-px w-1/2 bg-border",
            (phase.state === "completed" || active) && "bg-primary/55",
          )}
          aria-hidden="true"
        />
      )}
      <span
        className={cn(
          "relative z-10 flex size-8 items-center justify-center rounded-full border bg-card text-muted-foreground",
          phase.state === "completed" && "border-primary bg-primary text-primary-foreground",
          phase.state === "current" &&
            "border-primary text-primary shadow-[0_0_0_4px_color-mix(in_oklab,var(--primary)_12%,transparent)]",
          phase.state === "attention" &&
            "border-destructive text-destructive shadow-[0_0_0_4px_color-mix(in_oklab,var(--destructive)_12%,transparent)]",
        )}
      >
        {phase.state === "completed" ? (
          <Check className="size-3.5" />
        ) : phase.state === "attention" ? (
          <CircleAlert className="size-3.5" />
        ) : phase.state === "pending" ? (
          <CircleDashed className="size-3.5" />
        ) : (
          <Icon className="size-3.5 animate-pulse" />
        )}
      </span>
      <span
        className={cn(
          "relative z-10 bg-card pr-1 text-xs font-medium text-muted-foreground",
          active && "text-foreground",
        )}
      >
        {t(`cases.workflow.phases.${phase.key}`)}
      </span>
    </li>
  );
}

function ExecutionLogRow({
  entry,
  locale,
  selected,
  latest,
  onSelect,
}: {
  entry: LogEntry;
  locale: string;
  selected: boolean;
  latest: boolean;
  onSelect: () => void;
}) {
  const { t } = useTranslation();
  return (
    <article
      className={cn(
        "border-b last:border-b-0",
        latest && "shadow-[inset_2px_0_var(--primary)]",
        selected && "bg-primary/[0.04]",
      )}
    >
      <button
        type="button"
        className="w-full px-4 py-3 text-left focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
        onClick={onSelect}
        aria-pressed={selected}
      >
        <span className="flex min-w-0 items-center gap-2">
          <time className="shrink-0 font-mono text-[10px] text-muted-foreground">
            {formatLogTime(entry.at, locale)}
          </time>
          <Badge variant={entry.failed ? "destructive" : "secondary"} className="shrink-0">
            {t(`cases.workflow.stages.${entry.stage}.label`)}
          </Badge>
          <span className="truncate text-[11px] font-medium text-muted-foreground">
            {entry.source}
          </span>
        </span>
        <span
          className={cn(
            "mt-2 block break-words text-xs leading-5 text-foreground",
            !selected && "line-clamp-4",
            entry.failed && "text-destructive",
          )}
        >
          {entry.summary}
        </span>
      </button>

      {selected && (
        <div className="space-y-2 px-4 pb-3">
          {entry.facts && entry.facts.length > 0 && (
            <dl className="grid gap-2 rounded-md bg-muted/35 p-3">
              {entry.facts.map((fact) => (
                <div key={`${fact.label}-${fact.value}`} className="min-w-0">
                  <dt className="text-[10px] font-medium text-muted-foreground">{fact.label}</dt>
                  <dd className="mt-0.5 break-words text-xs">{fact.value}</dd>
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
              <pre className="mt-2 max-h-52 overflow-auto rounded-md bg-muted/45 p-3 font-mono text-[10px] leading-relaxed text-muted-foreground">
                {JSON.stringify(entry.technical, null, 2)}
              </pre>
            </details>
          )}
        </div>
      )}
    </article>
  );
}

function projectProgress(props: Props): Phase[] {
  const incident = props.snapshot.case;
  const report = props.reports.find((item) => item.case_revision === incident.revision);
  const attention = ["needs_attention", "cancelled"].includes(incident.status);
  const resolved = incident.status === "resolved";
  const states: Record<PhaseKey, PhaseState> = {
    alert: "completed",
    resolution: resolved ? "completed" : attention ? "attention" : "current",
    report: report ? "completed" : resolved ? "current" : "pending",
    complete: report && resolved ? "completed" : "pending",
  };
  return phaseDefinitions.map((phase) => ({ ...phase, state: states[phase.key] }));
}

function formatLogTime(value: string, locale: string) {
  return new Intl.DateTimeFormat(locale, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(new Date(value));
}
