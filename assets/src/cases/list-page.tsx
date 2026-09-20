import { useEffect, useRef, useState } from "react";
import { Activity, CircleAlert, Clock3, RefreshCw, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

type CaseRecord = components["schemas"]["Case"];
type CasePage = components["schemas"]["CasePage"];
type QueueStatus = "all" | CaseRecord["status"];
type AlertState = "all" | CaseRecord["alert_state"];
type QueueSort = "updated_desc" | "updated_asc" | "severity_desc";

const pollIntervalMs = 5_000;
const pageSize = 50;
export function CaseListPage() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [page, setPage] = useState<CasePage | null>(null);
  const [cursors, setCursors] = useState<Array<string | null>>([null]);
  const [pageIndex, setPageIndex] = useState(0);
  const [targetNames, setTargetNames] = useState<Record<string, string>>({});
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<QueueStatus>("all");
  const [alertState, setAlertState] = useState<AlertState>("all");
  const [sort, setSort] = useState<QueueSort>("updated_desc");
  const [lastSyncedAt, setLastSyncedAt] = useState<Date | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");
  const [retryKey, setRetryKey] = useState(0);
  const targetCache = useRef(new Map<string, string>());
  const cursor = cursors[pageIndex] ?? null;

  useEffect(() => {
    let active = true;
    let inFlight = false;

    async function resolveTargetNames(cases: CaseRecord[]) {
      const missing = Array.from(
        new Set(
          cases
            .map((incident) => incident.selected_target_id)
            .filter((id): id is string => id !== null)
            .filter((id) => !targetCache.current.has(id)),
        ),
      );

      await Promise.all(
        missing.map(async (id) => {
          try {
            const response = await apiClient.GET("/api/v1/targets/{id}", {
              params: { path: { id } },
            });
            const target = apiData(response).data;
            targetCache.current.set(id, target.name);
          } catch {
            targetCache.current.set(id, id);
          }
        }),
      );

      if (active && missing.length > 0) {
        setTargetNames(Object.fromEntries(targetCache.current));
      }
    }

    async function load() {
      if (inFlight) return;
      inFlight = true;
      setRefreshing(true);

      try {
        const response = await apiClient.GET("/api/v1/cases", {
          params: {
            query: {
              limit: pageSize,
              after: cursor ?? undefined,
              query: query.trim() || undefined,
              status: status === "all" ? undefined : status,
              alert_state: alertState === "all" ? undefined : alertState,
              sort,
            },
          },
        });
        const next = apiData(response);
        if (!active) return;
        setPage(next);
        setLastSyncedAt(new Date());
        setError("");
        await resolveTargetNames(next.data);
      } catch {
        if (active) {
          setError(t("cases.requestFailed"));
        }
      } finally {
        inFlight = false;
        if (active) setRefreshing(false);
      }
    }

    void load();
    const timer = window.setInterval(() => void load(), pollIntervalMs);

    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [alertState, cursor, query, retryKey, sort, status, t]);

  if (!page && !error) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  const records = page?.data ?? [];
  const summary = {
    inProgress: records.filter(
      (incident) => incident.status === "running" && incident.alert_state !== "recovered",
    ).length,
    attention: records.filter((incident) => incident.status === "needs_attention").length,
    recovering: records.filter(
      (incident) => incident.alert_state === "recovered" && incident.status === "running",
    ).length,
    terminal: records.filter((incident) => ["resolved", "cancelled"].includes(incident.status))
      .length,
  };

  function nextPage() {
    if (!page?.page.next) return;
    const nextIndex = pageIndex + 1;
    setPage(null);
    setCursors((current) => [...current.slice(0, nextIndex), page.page.next]);
    setPageIndex(nextIndex);
  }

  function previousPage() {
    if (pageIndex > 0) {
      setPage(null);
      setPageIndex((current) => current - 1);
    }
  }

  function resetToFirstPage() {
    setCursors([null]);
    setPageIndex(0);
  }

  const targetName = (id: string | null) =>
    id ? (targetNames[id] ?? t("cases.targetLoading")) : t("cases.unresolved");

  const ownerName = (id: string | null) => {
    if (!id) return t("cases.unclaimed");
    return id === account?.id ? t("cases.ownerYou") : t("cases.ownerAssigned");
  };

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("cases.title")}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{t("cases.description")}</p>
        </div>
        <div className="flex items-center gap-3 text-sm text-muted-foreground" aria-live="polite">
          {refreshing ? (
            <Spinner />
          ) : error ? (
            <CircleAlert className="size-4 text-destructive" />
          ) : (
            <Activity className="size-4 text-success" />
          )}
          <span>
            {error
              ? t("cases.syncRetrying")
              : lastSyncedAt
                ? t("cases.lastSynced", {
                    time: new Intl.DateTimeFormat(i18n.resolvedLanguage, {
                      hour: "2-digit",
                      minute: "2-digit",
                      second: "2-digit",
                    }).format(lastSyncedAt),
                  })
                : t("cases.syncing")}
          </span>
          <Button
            size="sm"
            variant="outline"
            disabled={refreshing}
            onClick={() => setRetryKey((value) => value + 1)}
          >
            {refreshing ? <Spinner /> : <RefreshCw />}
            {t("cases.refresh")}
          </Button>
          <Button asChild size="sm" variant="outline">
            <Link to="/cases/signals">{t("cases.signalDiagnostics")}</Link>
          </Button>
        </div>
      </div>

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <CircleAlert />
          <AlertDescription className="flex flex-wrap items-center justify-between gap-3">
            <span>{error}</span>
            <Button size="sm" variant="outline" onClick={() => setRetryKey((value) => value + 1)}>
              {t("cases.retryNow")}
            </Button>
          </AlertDescription>
        </Alert>
      )}

      <section className="grid grid-cols-2 gap-2 lg:grid-cols-4" aria-label={t("cases.summary")}>
        <SummaryCard label={t("cases.summaryInProgress")} value={summary.inProgress} />
        <SummaryCard label={t("cases.summaryAttention")} value={summary.attention} urgent />
        <SummaryCard label={t("cases.summaryRecovering")} value={summary.recovering} />
        <SummaryCard label={t("cases.summaryTerminal")} value={summary.terminal} />
      </section>

      <section className="space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-xl font-semibold">{t("cases.activeCases")}</h2>
            <p className="text-sm text-muted-foreground">
              {t("cases.pageDescription", { page: pageIndex + 1, count: records.length })}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <form
              className="flex min-w-72 flex-1 gap-2"
              onSubmit={(event) => {
                event.preventDefault();
                resetToFirstPage();
                setQuery(queryDraft.trim());
              }}
            >
              <div className="relative min-w-56 flex-1">
                <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
                <Input
                  className="h-9 pl-9"
                  value={queryDraft}
                  onChange={(event) => setQueryDraft(event.target.value)}
                  placeholder={t("cases.searchPlaceholder")}
                  aria-label={t("cases.search")}
                />
              </div>
              <Button type="submit" size="sm" variant="outline">
                {t("cases.searchAction")}
              </Button>
            </form>
            <FormSelect
              id="case-status-filter"
              className="w-auto min-w-44"
              value={status}
              onValueChange={(value) => {
                if (!value) return;
                resetToFirstPage();
                setStatus(value as QueueStatus);
              }}
              ariaLabel={t("cases.filterStatus")}
              options={[
                { value: "all", label: t("cases.allStatuses") },
                { value: "running", label: t("cases.status.running") },
                { value: "needs_attention", label: t("cases.status.needs_attention") },
                { value: "resolved", label: t("cases.status.resolved") },
                { value: "cancelled", label: t("cases.status.cancelled") },
              ]}
            />
            <FormSelect
              id="case-alert-filter"
              className="w-auto min-w-44"
              value={alertState}
              onValueChange={(value) => {
                if (!value) return;
                resetToFirstPage();
                setAlertState(value as AlertState);
              }}
              ariaLabel={t("cases.filterAlert")}
              options={[
                { value: "all", label: t("cases.allAlerts") },
                { value: "firing", label: t("cases.alert.firing") },
                { value: "recovered", label: t("cases.alert.recovered") },
                { value: "not_applicable", label: t("cases.alert.not_applicable") },
              ]}
            />
            <FormSelect
              id="case-sort"
              className="w-auto min-w-44"
              value={sort}
              onValueChange={(value) => {
                if (!value) return;
                resetToFirstPage();
                setSort(value as QueueSort);
              }}
              ariaLabel={t("cases.sort")}
              options={[
                { value: "updated_desc", label: t("cases.sortNewest") },
                { value: "updated_asc", label: t("cases.sortOldest") },
                { value: "severity_desc", label: t("cases.sortSeverity") },
              ]}
            />
          </div>
        </div>

        <div className="rounded-lg border bg-card">
          <Table className="min-w-[70rem]">
            <TableHeader className="bg-muted/40 uppercase tracking-wide text-muted-foreground">
              <TableRow>
                <TableHead>{t("cases.case")}</TableHead>
                <TableHead>{t("cases.severityLabel")}</TableHead>
                <TableHead>{t("cases.target")}</TableHead>
                <TableHead>{t("cases.alertState")}</TableHead>
                <TableHead>{t("cases.resolutionState")}</TableHead>
                <TableHead>{t("cases.owner")}</TableHead>
                <TableHead>{t("cases.requiredAction")}</TableHead>
                <TableHead>{t("cases.updated")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {records.map((incident) => (
                <TableRow key={incident.id} className="align-top">
                  <TableCell className="max-w-80 whitespace-normal">
                    <Link
                      className="font-medium text-foreground hover:text-primary hover:underline"
                      to={`/cases/${incident.id}`}
                    >
                      {incident.title}
                    </Link>
                    <p className="mt-1 truncate text-xs text-muted-foreground">
                      {incident.source} · {incident.source_ref}
                    </p>
                  </TableCell>
                  <TableCell>
                    <SeverityBadge severity={incident.severity} />
                  </TableCell>
                  <TableCell className="max-w-52 whitespace-normal font-medium">
                    {targetName(incident.selected_target_id)}
                  </TableCell>
                  <TableCell>
                    <Badge variant={incident.alert_state === "firing" ? "destructive" : "outline"}>
                      {t(`cases.alert.${incident.alert_state}`)}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <Badge
                      variant={incident.status === "needs_attention" ? "destructive" : "secondary"}
                    >
                      {t(`cases.status.${incident.status}`)}
                    </Badge>
                  </TableCell>
                  <TableCell>{ownerName(incident.current_owner_id)}</TableCell>
                  <TableCell className="max-w-72 whitespace-normal">
                    <RequiredAction incident={incident} />
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {formatDate(incident.updated_at, i18n.resolvedLanguage)}
                  </TableCell>
                </TableRow>
              ))}
              {records.length === 0 && (
                <TableRow>
                  <TableCell colSpan={8} className="py-10 text-center text-muted-foreground">
                    {query || status !== "all" || alertState !== "all"
                      ? t("cases.noMatchingCases")
                      : t("cases.noCases")}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>

        <div className="flex items-center justify-between">
          <Button variant="outline" disabled={pageIndex === 0} onClick={previousPage}>
            {t("cases.previousPage")}
          </Button>
          <span className="text-sm text-muted-foreground">
            {t("cases.pageNumber", { page: pageIndex + 1 })}
          </span>
          <Button variant="outline" disabled={!page?.page.next} onClick={nextPage}>
            {t("cases.nextPage")}
          </Button>
        </div>
      </section>
    </div>
  );
}

function SummaryCard({
  label,
  value,
  urgent = false,
}: {
  label: string;
  value: number;
  urgent?: boolean;
}) {
  return (
    <Card size="sm" className={urgent && value > 0 ? "border-destructive/60 py-3" : "py-3"}>
      <CardContent className="flex items-center justify-between px-3">
        <span className="text-xs font-medium text-muted-foreground">{label}</span>
        <span
          className={
            urgent && value > 0 ? "text-xl font-semibold text-destructive" : "text-xl font-semibold"
          }
        >
          {value}
        </span>
      </CardContent>
    </Card>
  );
}

function SeverityBadge({ severity }: { severity: CaseRecord["severity"] }) {
  const { t } = useTranslation();
  return (
    <Badge variant={severity === "critical" || severity === "error" ? "destructive" : "outline"}>
      {t(`cases.severity.${severity}`)}
    </Badge>
  );
}

function RequiredAction({ incident }: { incident: CaseRecord }) {
  const { t } = useTranslation();
  const label = incident.required_human_input
    ? t("cases.actionInputRequired")
    : incident.status === "needs_attention"
      ? t("cases.actionReview")
      : incident.status === "resolved"
        ? t("cases.actionNone")
        : incident.status === "cancelled"
          ? t("cases.actionReviewCancellation")
          : incident.alert_state === "recovered"
            ? t("cases.actionVerifying")
            : t("cases.actionResolving");

  return (
    <span className="flex items-start gap-2">
      {incident.status === "needs_attention" ? (
        <CircleAlert className="mt-0.5 size-4 shrink-0 text-destructive" />
      ) : (
        <Clock3 className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
      )}
      <span>{label}</span>
    </span>
  );
}

function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
