import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Printer } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useSearchParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { PeriodReportDocument } from "@/reports/period-document";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

type Summary = components["schemas"]["PeriodSummary"];
type Target = components["schemas"]["Target"];

const today = new Date();
const defaultTo = today.toISOString().slice(0, 10);
const defaultFrom = new Date(today.getTime() - 29 * 86_400_000).toISOString().slice(0, 10);

function nextUtcDate(day: string) {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString();
}

function validPeriod(from: string, to: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to)) return false;
  const start = new Date(`${from}T00:00:00Z`);
  const end = new Date(`${to}T00:00:00Z`);
  if (
    Number.isNaN(start.getTime()) ||
    Number.isNaN(end.getTime()) ||
    start.toISOString().slice(0, 10) !== from ||
    end.toISOString().slice(0, 10) !== to
  )
    return false;
  const days = (end.getTime() - start.getTime()) / 86_400_000 + 1;
  return days > 0 && days <= 366;
}

export function PeriodReportPage({ print = false }: { print?: boolean }) {
  const { t, i18n } = useTranslation();
  const [params, setParams] = useSearchParams();
  const from = params.get("from") ?? defaultFrom;
  const to = params.get("to") ?? defaultTo;
  const target = params.get("target") ?? "all";
  const key = `${from}|${to}|${target}`;
  const periodValid = validPeriod(from, to);
  const [loaded, setLoaded] = useState<{ key: string; summary: Summary } | null>(null);
  const [targets, setTargets] = useState<Target[]>([]);
  const [requestError, setRequestError] = useState<{ key: string; message: string } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const [draft, setDraft] = useState({ key, from, to, target });
  const fromInput = draft.key === key ? draft.from : from;
  const toInput = draft.key === key ? draft.to : to;
  const targetInput = draft.key === key ? draft.target : target;
  const setDraftField = (field: "from" | "to" | "target", value: string) =>
    setDraft({ key, from: fromInput, to: toInput, target: targetInput, [field]: value });
  const summary = loaded?.key === key ? loaded.summary : null;
  const error = !periodValid
    ? t("reports.periodInvalid")
    : requestError?.key === key
      ? requestError.message
      : "";
  const pending = periodValid && !summary && !error;

  useEffect(() => {
    collectPages((after) =>
      apiClient
        .GET("/api/v1/targets", {
          params: { query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    )
      .then(setTargets)
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    if (!periodValid) return;

    let active = true;
    apiClient
      .GET("/api/v1/reports/operations-summary", {
        params: {
          query: {
            from: `${from}T00:00:00Z`,
            to: nextUtcDate(to),
            target_id: target === "all" ? undefined : target,
          },
        },
      })
      .then((response) => apiData(response).data)
      .then((result) => active && setLoaded({ key, summary: result }))
      .catch(() => active && setRequestError({ key, message: t("reports.requestFailed") }));
    return () => {
      active = false;
    };
  }, [from, to, target, key, periodValid, attempt, t]);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!validPeriod(fromInput, toInput)) {
      setRequestError({ key, message: t("reports.periodInvalid") });
      return;
    }
    setRequestError(null);
    setLoaded(null);
    const next = new URLSearchParams({ from: fromInput, to: toInput });
    if (targetInput !== "all") next.set("target", targetInput);
    setDraft({
      key: `${fromInput}|${toInput}|${targetInput}`,
      from: fromInput,
      to: toInput,
      target: targetInput,
    });
    setParams(next);
    setAttempt((current) => current + 1);
  }

  const targetName =
    target === "all"
      ? t("reports.allTargets")
      : (targets.find((item) => item.id === target)?.name ?? target);
  const printUrl = `/reports/operations/print?${new URLSearchParams({
    from,
    to,
    ...(target === "all" ? {} : { target }),
  })}`;
  const Container = print ? "main" : "div";

  return (
    <Container className="mx-auto max-w-[96rem] space-y-8 p-6 lg:p-8 print:max-w-none print:p-0">
      <div className="flex flex-wrap items-start justify-between gap-4 print:hidden">
        <div>
          <Button asChild variant="ghost" className="mb-3 -ml-3">
            <Link to="/reports">
              <ArrowLeft /> {t("reports.backToReports")}
            </Link>
          </Button>
          <h1 className="text-2xl font-semibold">{t("reports.periodTitle")}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.periodDescription")}</p>
        </div>
        {summary &&
          (print ? (
            <Button variant="outline" onClick={() => window.print()}>
              <Printer /> {t("reports.print")}
            </Button>
          ) : (
            <Button asChild variant="outline">
              <Link to={printUrl}>
                <Printer /> {t("reports.print")}
              </Link>
            </Button>
          ))}
      </div>

      {!print && (
        <form onSubmit={submit} className="grid gap-4 rounded-lg border bg-card p-5 sm:grid-cols-4">
          <div className="space-y-2">
            <Label htmlFor="period-from">{t("reports.periodFrom")}</Label>
            <Input
              id="period-from"
              type="date"
              required
              value={fromInput}
              onChange={(event) => setDraftField("from", event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="period-to">{t("reports.periodTo")}</Label>
            <Input
              id="period-to"
              type="date"
              required
              value={toInput}
              onChange={(event) => setDraftField("to", event.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="period-target">{t("reports.periodTarget")}</Label>
            <FormSelect
              id="period-target"
              value={targetInput}
              onValueChange={(value) => setDraftField("target", value ?? "all")}
              options={[
                { value: "all", label: t("reports.allTargets") },
                ...targets.map((item) => ({ value: item.id, label: item.name })),
              ]}
            />
          </div>
          <div className="flex items-end">
            <Button type="submit" disabled={pending} className="w-full">
              {t("reports.showPeriod")}
            </Button>
          </div>
        </form>
      )}

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {error && periodValid && (
        <Button
          variant="outline"
          onClick={() => {
            setRequestError(null);
            setAttempt((current) => current + 1);
          }}
        >
          {t("reports.refresh")}
        </Button>
      )}
      {pending && !summary && <p>{t("common.loading")}</p>}

      {summary && (
        <PeriodReportDocument summary={summary} from={from} to={to} targetName={targetName} />
      )}
      {summary && !print && (
        <details className="rounded-lg border bg-card p-5">
          <summary className="cursor-pointer font-semibold">
            {t("reports.periodDetailedRecords")}
          </summary>
          <article className="mt-6 space-y-7" aria-label={t("reports.periodTitle")}>
            <div>
              <h1 className="text-xl font-semibold">{t("reports.periodTitle")}</h1>
              <p className="mt-1 text-sm text-muted-foreground">
                {from} – {to} UTC · {targetName} · {t("reports.periodAsOf")}{" "}
                {new Date(summary.as_of).toLocaleString(i18n.resolvedLanguage)}
              </p>
              <p className="mt-2 text-sm text-muted-foreground">{t("reports.periodSemantics")}</p>
            </div>

            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <Metric title={t("reports.periodCases")} value={summary.case_count} />
              <Metric title={t("reports.periodResolved")} value={summary.case_status.resolved} />
              <Metric
                title={t("reports.periodAttention")}
                value={summary.case_status.needs_attention}
              />
              <Metric title={t("reports.periodAudits")} value={summary.audit_count} />
            </div>

            <div className="grid gap-4 lg:grid-cols-2">
              <Card>
                <CardHeader>
                  <CardTitle>{t("reports.periodCaseBreakdown")}</CardTitle>
                </CardHeader>
                <CardContent className="space-y-2 text-sm">
                  {Object.entries(summary.case_status).map(([status, count]) => (
                    <CountRow key={status} label={t(`cases.status.${status}`)} count={count} />
                  ))}
                  <p className="border-t pt-3 text-muted-foreground">
                    {t("reports.periodTriggerBreakdown", {
                      signal: summary.case_trigger.signal,
                      audit: summary.case_trigger.audit,
                      manual: summary.case_trigger.manual,
                    })}
                  </p>
                </CardContent>
              </Card>
              <Card>
                <CardHeader>
                  <CardTitle>{t("reports.periodAuditBreakdown")}</CardTitle>
                </CardHeader>
                <CardContent className="space-y-2 text-sm">
                  {Object.entries(summary.audit_status).map(([status, count]) => (
                    <CountRow key={status} label={t(`audits.runStatus.${status}`)} count={count} />
                  ))}
                </CardContent>
              </Card>
            </div>

            <Card>
              <CardHeader>
                <CardTitle>{t("reports.periodRecovery")}</CardTitle>
              </CardHeader>
              <CardContent className="text-sm">
                <p>
                  {summary.recovery.average_seconds === null
                    ? t("reports.periodNoRecoveryMeasurement")
                    : t("reports.periodAverageRecovery", {
                        seconds: summary.recovery.average_seconds,
                        count: summary.recovery.measured_cases,
                      })}
                </p>
                <p className="mt-2 text-muted-foreground">
                  {t("reports.periodUnmeasured", {
                    count: summary.recovery.unmeasured_resolved_cases,
                  })}
                </p>
                <p className="mt-2 text-xs text-muted-foreground">
                  {t("reports.periodRecoveryDefinition")}
                </p>
              </CardContent>
            </Card>

            <section>
              <h2 className="mb-3 text-lg font-semibold">{t("reports.periodDaily")}</h2>
              <div className="overflow-x-auto rounded-lg border bg-card">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>{t("reports.periodDay")}</TableHead>
                      <TableHead>{t("reports.periodCases")}</TableHead>
                      <TableHead>{t("reports.periodAudits")}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {summary.daily.map((day) => (
                      <TableRow key={day.date}>
                        <TableCell>{day.date}</TableCell>
                        <TableCell>{day.cases}</TableCell>
                        <TableCell>{day.audits}</TableCell>
                      </TableRow>
                    ))}
                    {summary.daily.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={3}>{t("reports.periodNoRecords")}</TableCell>
                      </TableRow>
                    )}
                  </TableBody>
                </Table>
              </div>
            </section>

            <section>
              <h2 className="mb-3 text-lg font-semibold">{t("reports.periodSourceCases")}</h2>
              {summary.case_sources_truncated && (
                <p className="mb-3 text-sm text-muted-foreground">
                  {t("reports.periodSourceLimit")}
                </p>
              )}
              <div className="divide-y rounded-lg border bg-card">
                {summary.cases.map((item) => (
                  <div
                    key={item.id}
                    className="flex flex-wrap items-center justify-between gap-2 p-3 text-sm"
                  >
                    <Link
                      className="font-medium underline-offset-4 hover:underline"
                      to={`/cases/${item.id}`}
                    >
                      {item.title}
                    </Link>
                    <span className="flex items-center gap-2 text-muted-foreground">
                      <Badge variant="secondary">{t(`cases.status.${item.status}`)}</Badge>
                      {new Date(item.opened_at).toLocaleString(i18n.resolvedLanguage)}
                    </span>
                  </div>
                ))}
                {summary.cases.length === 0 && (
                  <p className="p-3 text-sm">{t("reports.periodNoRecords")}</p>
                )}
              </div>
            </section>

            <section>
              <h2 className="mb-3 text-lg font-semibold">{t("reports.periodSourceAudits")}</h2>
              {summary.audit_sources_truncated && (
                <p className="mb-3 text-sm text-muted-foreground">
                  {t("reports.periodSourceLimit")}
                </p>
              )}
              <div className="divide-y rounded-lg border bg-card">
                {summary.audits.map((item) => (
                  <div
                    key={item.id}
                    className="flex flex-wrap items-center justify-between gap-2 p-3 text-sm"
                  >
                    <div className="min-w-0">
                      <Link
                        className="break-all font-mono text-xs underline-offset-4 hover:underline"
                        to={`/audits#audit-run-${item.id}`}
                      >
                        {item.id}
                      </Link>
                      {item.reason && (
                        <p className="mt-1 break-words text-muted-foreground">{item.reason}</p>
                      )}
                      {item.case_id && (
                        <Link
                          className="mt-1 block text-xs text-primary underline-offset-4 hover:underline"
                          to={`/cases/${item.case_id}`}
                        >
                          {t("reports.periodAuditCase")}
                        </Link>
                      )}
                    </div>
                    <span className="flex items-center gap-2 text-muted-foreground">
                      <Badge variant="secondary">{t(`audits.runStatus.${item.status}`)}</Badge>
                      {new Date(item.scheduled_for).toLocaleString(i18n.resolvedLanguage)}
                    </span>
                  </div>
                ))}
                {summary.audits.length === 0 && (
                  <p className="p-3 text-sm">{t("reports.periodNoRecords")}</p>
                )}
              </div>
            </section>
          </article>
        </details>
      )}
    </Container>
  );
}

function Metric({ title, value }: { title: string; value: number }) {
  return (
    <Card>
      <CardContent className="p-5">
        <p className="text-sm text-muted-foreground">{title}</p>
        <p className="mt-2 text-3xl font-semibold">{value}</p>
      </CardContent>
    </Card>
  );
}

function CountRow({ label, count }: { label: string; count: number }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <span>{label}</span>
      <span className="font-semibold tabular-nums">{count}</span>
    </div>
  );
}
