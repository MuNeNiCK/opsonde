import { useCallback, useEffect, useState } from "react";
import { Plus, RefreshCw, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { AuditCreateForm } from "@/audits/create-form";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";

type AuditRun = components["schemas"]["AuditRun"];
type AuditSchedule = components["schemas"]["AuditSchedule"];
type ManagementBoundary = components["schemas"]["ManagementBoundarySummary"];
type Target = components["schemas"]["Target"];

type Snapshot = {
  schedules: AuditSchedule[];
  runs: AuditRun[];
  targets: Target[];
  boundaries: ManagementBoundary[];
};

async function loadSnapshot(): Promise<Snapshot> {
  const [schedules, runs, targets, boundaries] = await Promise.all([
    collectPages((after) =>
      apiClient
        .GET("/api/v1/audit-schedules", {
          params: { query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/audit-runs", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/management-boundaries", {
          params: { query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
  ]);
  return { schedules, runs, targets, boundaries };
}

export function AuditPage() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [pending, setPending] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [confirmDeactivate, setConfirmDeactivate] = useState<string | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  const refresh = useCallback(async () => setSnapshot(await loadSnapshot()), []);

  useEffect(() => {
    let active = true;
    loadSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch(() => {
        if (active) setError(t("audits.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  async function deactivate(schedule: AuditSchedule) {
    setPending(schedule.id);
    setError("");
    try {
      await apiClient.POST("/api/v1/audit-schedules/{id}/deactivate", {
        params: { path: { id: schedule.id } },
        body: { audit_schedule: { expected_revision: schedule.revision } },
      });
      setConfirmDeactivate(null);
      await refresh();
    } catch {
      setError(t("audits.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  if (!snapshot) return <Loading />;
  const targetName = (id: string) => snapshot.targets.find((item) => item.id === id)?.name ?? id;
  const boundaryName = (id: string) =>
    snapshot.boundaries.find((item) => item.id === id)?.name ?? id;

  return (
    <div className="space-y-10 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("audits.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("audits.description")}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" onClick={() => void refresh()}>
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

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
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

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">{t("audits.schedules")}</h2>
        <div className="grid gap-4 xl:grid-cols-2">
          {snapshot.schedules.map((schedule) => (
            <Card key={schedule.id} id={`audit-schedule-${schedule.id}`}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <CardTitle>{schedule.name}</CardTitle>
                    <CardDescription>
                      {t("audits.desiredOutcome")}: {schedule.desired_outcome}
                    </CardDescription>
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
                  <Metric
                    label={t("audits.scope")}
                    value={
                      schedule.management_boundary_id
                        ? boundaryName(schedule.management_boundary_id)
                        : schedule.target_ids.map(targetName).join(", ")
                    }
                  />
                </dl>
                {canManage && schedule.active && confirmDeactivate !== schedule.id && (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={pending !== null}
                    onClick={() => setConfirmDeactivate(schedule.id)}
                  >
                    {t("audits.deactivate")}
                  </Button>
                )}
                {confirmDeactivate === schedule.id && (
                  <Alert variant="destructive">
                    <AlertDescription>
                      <p>{t("audits.deactivateConfirmation")}</p>
                      <div className="mt-2 flex flex-wrap gap-2">
                        <Button
                          size="sm"
                          variant="destructive"
                          disabled={pending !== null}
                          onClick={() => void deactivate(schedule)}
                        >
                          {pending === schedule.id && <Spinner />}
                          {t("audits.confirmDeactivate")}
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setConfirmDeactivate(null)}
                        >
                          {t("common.cancel")}
                        </Button>
                      </div>
                    </AlertDescription>
                  </Alert>
                )}
              </CardContent>
            </Card>
          ))}
          {snapshot.schedules.length === 0 && <Empty text={t("audits.noSchedules")} />}
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">{t("audits.runs")}</h2>
        <div className="divide-y rounded-lg border bg-card">
          {snapshot.runs.map((run) => (
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
                      {targetName(run.target_id)}
                    </Link>
                  ) : (
                    <span className="font-medium">{run.target_key}</span>
                  )}
                </div>
                <p className="mt-1 text-muted-foreground">
                  {formatDate(run.scheduled_for, i18n.resolvedLanguage)}
                  {run.reason ? ` · ${t("audits.runFailedGuidance")}` : ""}
                </p>
                {run.reason && (
                  <details className="mt-2 text-xs text-muted-foreground">
                    <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                    <p className="mt-1">{run.reason}</p>
                  </details>
                )}
              </div>
              <div className="flex flex-wrap gap-2">
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
                    <a href={`#audit-schedule-${run.audit_schedule_id}`}>
                      {t("audits.reviewSchedule")}
                    </a>
                  </Button>
                )}
              </div>
            </div>
          ))}
          {snapshot.runs.length === 0 && (
            <p className="p-6 text-center text-sm text-muted-foreground">{t("audits.noRuns")}</p>
          )}
        </div>
      </section>
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
