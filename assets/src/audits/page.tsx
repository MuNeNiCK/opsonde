import { useCallback, useEffect, useState, type FormEvent } from "react";
import { Plus, RefreshCw, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { FormMultiSelect, FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type AuditRun = components["schemas"]["AuditRun"];
type AuditSchedule = components["schemas"]["AuditSchedule"];
type ManagementBoundary = components["schemas"]["ManagementBoundary"];
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
  const [scope, setScope] = useState<"targets" | "boundary">("targets");
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

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const targetIds = scope === "targets" ? form.getAll("target_ids").map(String) : [];
    const boundary = scope === "boundary" ? formValue(form, "management_boundary_id") : null;
    if ((scope === "targets" && targetIds.length === 0) || (scope === "boundary" && !boundary)) {
      setError(t("audits.scopeRequired"));
      return;
    }

    setPending("create");
    setError("");
    try {
      await apiClient.POST("/api/v1/audit-schedules", {
        body: {
          audit_schedule: {
            name: formValue(form, "name"),
            objective: formValue(form, "objective"),
            timezone: formValue(form, "timezone"),
            cron_expression: formValue(form, "cron_expression"),
            report_language: formValue(form, "report_language") === "ja" ? "ja" : "en",
            target_ids: targetIds,
            management_boundary_id: boundary || null,
          },
        },
      });
      formElement.reset();
      setScope("targets");
      setShowCreate(false);
      await refresh();
    } catch {
      setError(t("audits.requestFailed"));
    } finally {
      setPending(null);
    }
  }

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

      {canManage && showCreate && (
        <Card>
          <CardHeader>
            <CardTitle>{t("audits.addSchedule")}</CardTitle>
            <CardDescription>{t("audits.scheduleDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
              <Field id="audit-name" name="name" label={t("audits.name")} />
              <Field
                id="audit-timezone"
                name="timezone"
                label={t("audits.timezone")}
                defaultValue={Intl.DateTimeFormat().resolvedOptions().timeZone}
              />
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="audit-objective">{t("audits.objective")}</Label>
                <Textarea id="audit-objective" name="objective" required />
              </div>
              <Field
                id="audit-cron"
                name="cron_expression"
                label={t("audits.cron")}
                defaultValue="0 * * * *"
              />
              <div className="space-y-2">
                <Label htmlFor="audit-language">{t("audits.reportLanguage")}</Label>
                <FormSelect
                  id="audit-language"
                  name="report_language"
                  defaultValue={i18n.resolvedLanguage === "ja" ? "ja" : "en"}
                  options={[
                    { value: "en", label: "English" },
                    { value: "ja", label: "日本語" },
                  ]}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="audit-scope">{t("audits.scope")}</Label>
                <FormSelect
                  id="audit-scope"
                  value={scope}
                  onValueChange={(value) => value && setScope(value as "targets" | "boundary")}
                  options={[
                    { value: "targets", label: t("audits.selectedTargets") },
                    { value: "boundary", label: t("audits.managementBoundary") },
                  ]}
                />
              </div>
              {scope === "targets" ? (
                <div className="space-y-2">
                  <Label htmlFor="audit-targets">{t("audits.targets")}</Label>
                  <FormMultiSelect
                    id="audit-targets"
                    name="target_ids"
                    required
                    placeholder={t("audits.targets")}
                    options={snapshot.targets
                      .filter((target) => target.active)
                      .map((target) => ({ value: target.id, label: target.name }))}
                  />
                </div>
              ) : (
                <div className="space-y-2">
                  <Label htmlFor="audit-boundary">{t("audits.managementBoundary")}</Label>
                  <FormSelect
                    id="audit-boundary"
                    name="management_boundary_id"
                    required
                    placeholder={t("audits.chooseBoundary")}
                    options={snapshot.boundaries
                      .filter((item) => item.active)
                      .map((item) => ({ value: item.id, label: item.name }))}
                  />
                </div>
              )}
              <div className="md:col-span-2">
                <Button type="submit" disabled={pending !== null}>
                  {pending === "create" && <Spinner />}
                  {t("audits.create")}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
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
                    <CardDescription>{schedule.objective}</CardDescription>
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
function Field({
  id,
  name,
  label,
  defaultValue,
}: {
  id: string;
  name: string;
  label: string;
  defaultValue?: string;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} defaultValue={defaultValue} required />
    </div>
  );
}
function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}
function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
