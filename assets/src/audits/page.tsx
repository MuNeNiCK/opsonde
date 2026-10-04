import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Plus, RefreshCw, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useLocation } from "react-router-dom";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";
import { usePagedData } from "@/api/use-paged-data";
import { PageControls } from "@/components/page-controls";
import { useAuthentication } from "@/auth/context";
import { AuditCreateForm } from "@/audits/create-form";
import { AuditDeactivation } from "@/audits/deactivation";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";

type AuditRun = components["schemas"]["AuditRun"];
type AuditSchedule = components["schemas"]["AuditSchedule"];
type ScheduleSummary = components["schemas"]["AuditScheduleSummary"];
type RunSummary = components["schemas"]["AuditRunSummary"] & { targetName?: string };
type Selection = { kind: "schedule" | "run"; id: string };

function loadSchedules(after: string | undefined, signal: AbortSignal) {
  return apiClient
    .GET("/api/v1/audit-schedules/summaries", {
      params: { query: { limit: 50, after } },
      signal,
    })
    .then(apiData);
}

async function loadRuns(after: string | undefined, signal: AbortSignal) {
  const owner = new AbortController();
  signal = AbortSignal.any([signal, owner.signal]);
  try {
    const page = await apiClient
      .GET("/api/v1/audit-runs/summaries", {
        params: { query: { limit: 50, after } },
        signal,
      })
      .then(apiData);
    const ids = [...new Set(page.data.flatMap((item) => (item.target_id ? [item.target_id] : [])))];
    const targets = ids.length
      ? await apiClient
          .GET("/api/v1/targets/summaries", {
            params: { query: { limit: 50, ids } },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData)
      : { data: [] };
    signal.throwIfAborted();
    const names = new Map(targets.data.map((item) => [item.id, item.name]));
    return {
      ...page,
      data: page.data.map((item) => ({
        ...item,
        targetName: item.target_id ? names.get(item.target_id) : undefined,
      })),
    };
  } catch (error) {
    owner.abort();
    throw error;
  }
}

function hashSelection(hash: string): Selection | null {
  const match = /^#audit-(schedule|run)-([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$/i.exec(hash);
  return match ? { kind: match[1] as Selection["kind"], id: match[2] } : null;
}

export function AuditPage() {
  const { account } = useAuthentication();
  return <Audits key={`${account?.id}:${account?.role}`} />;
}

function Audits() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const schedules = usePagedData<ScheduleSummary>(loadSchedules);
  const runs = usePagedData<RunSummary>(loadRuns);
  const location = useLocation();
  const [chosen, setChosen] = useState<{ hash: string; value: Selection | null } | null>(null);
  const selection = chosen?.hash === location.hash ? chosen.value : hashSelection(location.hash);
  const select = (value: Selection | null) => setChosen({ hash: location.hash, value });
  const [detailRefresh, setDetailRefresh] = useState(0);
  const [showCreate, setShowCreate] = useState(false);
  const [selectedSchedule, setSelectedSchedule] = useState<Pick<
    AuditSchedule,
    "id" | "name" | "revision"
  > | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  const currentPages = useRef({ schedules: schedules.retry, runs: runs.retry });
  useLayoutEffect(() => {
    currentPages.current = { schedules: schedules.retry, runs: runs.retry };
  });
  const refresh = useCallback(async () => {
    setError("");
    await Promise.all([currentPages.current.schedules(), currentPages.current.runs()]);
    setDetailRefresh((value) => value + 1);
  }, []);

  return (
    <div className="space-y-10 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("audits.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("audits.description")}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button
            variant="outline"
            onClick={() => void refresh().catch(() => setError(t("audits.requestFailed")))}
          >
            <RefreshCw /> {t("audits.refresh")}
          </Button>
          {canManage && (
            <Button onClick={() => setShowCreate((value) => !value)}>
              {showCreate ? <X /> : <Plus />}
              {t(showCreate ? "common.cancel" : "audits.addSchedule")}
            </Button>
          )}
        </div>
      </div>

      {!!(error || schedules.error || runs.error) && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error || t("audits.requestFailed")}</AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("audits.readOnly")}</AlertDescription>
        </Alert>
      )}

      {canManage && (
        <AuditCreateForm
          open={showCreate}
          onCreated={async () => {
            await refresh();
            setShowCreate(false);
          }}
        />
      )}

      {canManage && (
        <AuditDeactivation
          schedule={selectedSchedule}
          onChanged={async () => {
            await refresh();
          }}
          onClose={() => setSelectedSchedule(null)}
        />
      )}

      {selection && (
        <SelectedAudit
          key={`${selection.kind}:${selection.id}`}
          selection={selection}
          refreshKey={detailRefresh}
          onClose={() => select(null)}
          onSelect={select}
        />
      )}

      <section aria-label={t("audits.schedules")} className="space-y-4">
        <h2 className="text-xl font-semibold">{t("audits.schedules")}</h2>
        <div className="grid gap-4 xl:grid-cols-2">
          {schedules.view?.data.map((schedule) => (
            <Card key={schedule.id} id={`audit-schedule-${schedule.id}`}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <CardTitle>{schedule.name}</CardTitle>
                  </div>
                  <Badge variant={schedule.active ? "default" : "outline"}>
                    {t(schedule.active ? "audits.active" : "audits.inactive")}
                  </Badge>
                </div>
              </CardHeader>
              <CardContent className="space-y-4 text-sm">
                <dl className="grid gap-3 sm:grid-cols-2">
                  <Metric
                    label={t("audits.schedule")}
                    value={`${schedule.cron_expression} · ${schedule.timezone}`}
                  />
                  <Metric
                    label={t("audits.nextRun")}
                    value={formatDate(schedule.next_run_at, i18n.resolvedLanguage)}
                  />
                  <Metric label={t("audits.reportLanguage")} value={schedule.report_language} />
                </dl>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => select({ kind: "schedule", id: schedule.id })}
                >
                  {t("reports.viewDetails")}
                </Button>
                {canManage && schedule.active && (
                  <Button size="sm" variant="outline" onClick={() => setSelectedSchedule(schedule)}>
                    {t("audits.deactivate")}
                  </Button>
                )}
              </CardContent>
            </Card>
          ))}
          {schedules.view?.data.length === 0 && <Empty text={t("audits.noSchedules")} />}
        </div>
        {!schedules.view && !schedules.error && <Loading />}
        <PageControls
          index={schedules.view?.index ?? 0}
          hasNext={!!schedules.view?.page.next}
          pending={schedules.pending}
          previous={schedules.previous}
          next={schedules.next}
        />
      </section>

      <section aria-label={t("audits.runs")} className="space-y-4">
        <h2 className="text-xl font-semibold">{t("audits.runs")}</h2>
        <div className="divide-y rounded-lg border bg-card">
          {runs.view?.data.map((run) => (
            <div
              key={run.id}
              id={`audit-run-${run.id}`}
              className="flex flex-wrap items-center justify-between gap-4 p-4 text-sm"
            >
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge variant={run.status === "failed" ? "destructive" : "secondary"}>
                    {t(`audits.runStatus.${run.status}`)}
                  </Badge>
                  {run.target_id ? (
                    <Link
                      className="font-medium underline-offset-4 hover:underline"
                      to={`/targets/${run.target_id}`}
                    >
                      {run.targetName ?? run.target_id}
                    </Link>
                  ) : (
                    <span className="font-medium">{run.target_key}</span>
                  )}
                </div>
                <p className="mt-1 text-muted-foreground">
                  {formatDate(run.scheduled_for, i18n.resolvedLanguage)}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => select({ kind: "run", id: run.id })}
                >
                  {t("reports.viewDetails")}
                </Button>
                {run.case_id ? (
                  <Button asChild size="sm" variant="outline">
                    <Link to={`/cases/${run.case_id}`}>{t("audits.openCase")}</Link>
                  </Button>
                ) : (
                  <span className="self-center text-xs text-muted-foreground">
                    {t("audits.noCaseOpened")}
                  </span>
                )}
                {(run.status === "failed" || run.status === "skipped") && (
                  <Button asChild size="sm" variant="outline">
                    <Link
                      to={`#audit-schedule-${run.audit_schedule_id}`}
                      onClick={() => select({ kind: "schedule", id: run.audit_schedule_id })}
                    >
                      {t("audits.reviewSchedule")}
                    </Link>
                  </Button>
                )}
              </div>
            </div>
          ))}
          {runs.view?.data.length === 0 && (
            <p className="p-6 text-center text-sm text-muted-foreground">{t("audits.noRuns")}</p>
          )}
        </div>
        {!runs.view && !runs.error && <Loading />}
        <PageControls
          index={runs.view?.index ?? 0}
          hasNext={!!runs.view?.page.next}
          pending={runs.pending}
          previous={runs.previous}
          next={runs.next}
        />
      </section>
    </div>
  );
}

function SelectedAudit({
  selection,
  refreshKey,
  onClose,
  onSelect,
}: {
  selection: Selection;
  refreshKey: number;
  onClose: () => void;
  onSelect: (selection: Selection) => void;
}) {
  const { t } = useTranslation();
  const [state, setState] = useState<{
    key: number;
    detail?: AuditSchedule | AuditRun;
    error?: unknown;
  } | null>(null);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    const request =
      selection.kind === "schedule"
        ? apiClient
            .GET("/api/v1/audit-schedules/{id}", {
              params: { path: { id: selection.id } },
              signal: controller.signal,
            })
            .then(apiData)
        : apiClient
            .GET("/api/v1/audit-runs/{id}", {
              params: { path: { id: selection.id } },
              signal: controller.signal,
            })
            .then(apiData);
    request
      .then(({ data }) => {
        if (data.id !== selection.id) throw new Error("Audit detail identity mismatch");
        if (!controller.signal.aborted) setState({ key: refreshKey, detail: data });
      })
      .catch((error) => {
        if (!controller.signal.aborted) setState({ key: refreshKey, error });
      });
    return () => controller.abort();
  }, [selection.id, selection.kind, refreshKey, retry]);
  const detail = state?.key === refreshKey ? state.detail : undefined;
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between">
        <CardTitle>{t("reports.viewDetails")}</CardTitle>
        <Button variant="ghost" onClick={onClose}>
          {t("common.close")}
        </Button>
      </CardHeader>
      <CardContent className="space-y-4">
        {state?.error ? (
          <Alert variant="destructive">
            <AlertDescription>{t("audits.requestFailed")}</AlertDescription>
            <Button variant="outline" onClick={() => setRetry((value) => value + 1)}>
              {t("common.refresh")}
            </Button>
          </Alert>
        ) : !detail ? (
          <Loading />
        ) : "target_ids" in detail ? (
          <>
            <h3 className="font-medium">{detail.name}</h3>
            <Metric label={t("audits.desiredOutcome")} value={detail.desired_outcome} />
            <ScheduleScope schedule={detail} />
          </>
        ) : (
          <>
            <Badge>{t(`audits.runStatus.${detail.status}`)}</Badge>
            {detail.reason && <p className="break-words">{detail.reason}</p>}
            <Button
              variant="outline"
              onClick={() => onSelect({ kind: "schedule", id: detail.audit_schedule_id })}
            >
              {t("audits.reviewSchedule")}
            </Button>
            {detail.case_id && (
              <Button asChild variant="outline">
                <Link to={`/cases/${detail.case_id}`}>{t("audits.openCase")}</Link>
              </Button>
            )}
          </>
        )}
      </CardContent>
    </Card>
  );
}

function ScheduleScope({ schedule }: { schedule: AuditSchedule }) {
  const { t } = useTranslation();
  const load = useCallback(
    async (after: string | undefined, signal: AbortSignal) => {
      if (schedule.management_boundary_id) {
        const response = await apiClient
          .GET("/api/v1/management-boundaries", {
            params: {
              query: { limit: 1, ids: [schedule.management_boundary_id] },
            },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData);
        return {
          data: [
            {
              id: schedule.management_boundary_id,
              name:
                response.data.find((item) => item.id === schedule.management_boundary_id)?.name ??
                schedule.management_boundary_id,
            },
          ],
          page: { next: null },
        };
      }
      const start = Number(after ?? 0);
      const ids = schedule.target_ids.slice(start, start + 50);
      const response = ids.length
        ? await apiClient
            .GET("/api/v1/targets/summaries", {
              params: { query: { limit: 50, ids } },
              querySerializer: commaSeparatedQuery,
              signal,
            })
            .then(apiData)
        : { data: [] };
      const names = new Map(response.data.map((item) => [item.id, item.name]));
      return {
        data: ids.map((id) => ({ id, name: names.get(id) ?? id })),
        page: { next: start + 50 < schedule.target_ids.length ? String(start + 50) : null },
      };
    },
    [schedule],
  );
  const scope = usePagedData(load);
  return (
    <div className="space-y-3">
      <h4 className="font-medium">{t("audits.scope")}</h4>
      {!!scope.error && (
        <Alert variant="destructive">
          <AlertDescription>{t("audits.requestFailed")}</AlertDescription>
          <Button variant="outline" onClick={() => void scope.retry().catch(() => {})}>
            {t("common.refresh")}
          </Button>
        </Alert>
      )}
      <p className="break-words">{scope.view?.data.map((item) => item.name).join(", ")}</p>
      <PageControls
        index={scope.view?.index ?? 0}
        hasNext={!!scope.view?.page.next}
        pending={scope.pending}
        previous={scope.previous}
        next={scope.next}
      />
    </div>
  );
}

function Loading() {
  const { t } = useTranslation();
  return (
    <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
      <Spinner />
      <span>{t("common.loading")}</span>
    </div>
  );
}
function Empty({ text }: { text: string }) {
  return (
    <Card className="xl:col-span-2">
      <CardContent className="py-8 text-center text-sm text-muted-foreground">{text}</CardContent>
    </Card>
  );
}
function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words">{value}</dd>
    </div>
  );
}
function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
