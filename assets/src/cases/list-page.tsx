import { useEffect, useRef, useState } from "react";
import { Activity, CircleAlert, Clock3, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";

type CaseRecord = components["schemas"]["Case"];
type CasePage = components["schemas"]["CasePage"];
type QueueStatus = "all" | CaseRecord["status"];
type AlertState = "all" | CaseRecord["alert_state"];
type QueueSort = "updated_desc" | "updated_asc" | "severity_desc";

const pollIntervalMs = 5_000;
const pageSize = 50;
const selectClass =
  "flex h-9 rounded-md border border-input bg-card px-3 py-1 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35";
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
      } catch (failure) {
        if (active) {
          setError(failure instanceof Error ? failure.message : t("cases.requestFailed"));
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
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );
  }

  const records = page?.data ?? [];
  const summary = {
    attention: records.filter((incident) => incident.status === "needs_attention").length,
    firing: records.filter((incident) => incident.alert_state === "firing").length,
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
    <main className="mx-auto w-full max-w-[96rem] space-y-6 p-6 lg:p-8">
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
          <Button asChild size="sm" variant="outline">
            <Link to="/cases/signals">{t("cases.signalDiagnostics")}</Link>
          </Button>
        </div>
      </div>

      {error && (
        <Alert variant="destructive">
          <CircleAlert />
          <AlertDescription className="flex flex-wrap items-center justify-between gap-3">
            <span>{error}</span>
            <Button size="sm" variant="outline" onClick={() => setRetryKey((value) => value + 1)}>
              {t("cases.retryNow")}
            </Button>
          </AlertDescription>
        </Alert>
      )}

      <section className="grid grid-cols-2 gap-3 lg:grid-cols-4" aria-label={t("cases.summary")}>
        <SummaryCard label={t("cases.summaryAttention")} value={summary.attention} urgent />
        <SummaryCard label={t("cases.summaryFiring")} value={summary.firing} />
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
            <select
              className={selectClass}
              value={status}
              onChange={(event) => {
                resetToFirstPage();
                setStatus(event.target.value as QueueStatus);
              }}
              aria-label={t("cases.filterStatus")}
            >
              <option value="all">{t("cases.allStatuses")}</option>
              <option value="running">{t("cases.status.running")}</option>
              <option value="needs_attention">{t("cases.status.needs_attention")}</option>
              <option value="resolved">{t("cases.status.resolved")}</option>
              <option value="cancelled">{t("cases.status.cancelled")}</option>
            </select>
            <select
              className={selectClass}
              value={alertState}
              onChange={(event) => {
                resetToFirstPage();
                setAlertState(event.target.value as AlertState);
              }}
              aria-label={t("cases.filterAlert")}
            >
              <option value="all">{t("cases.allAlerts")}</option>
              <option value="firing">{t("cases.alert.firing")}</option>
              <option value="recovered">{t("cases.alert.recovered")}</option>
              <option value="not_applicable">{t("cases.alert.not_applicable")}</option>
            </select>
            <select
              className={selectClass}
              value={sort}
              onChange={(event) => {
                resetToFirstPage();
                setSort(event.target.value as QueueSort);
              }}
              aria-label={t("cases.sort")}
            >
              <option value="updated_desc">{t("cases.sortNewest")}</option>
              <option value="updated_asc">{t("cases.sortOldest")}</option>
              <option value="severity_desc">{t("cases.sortSeverity")}</option>
            </select>
          </div>
        </div>

        <div className="overflow-x-auto rounded-lg border bg-card">
          <table className="w-full min-w-[70rem] text-sm">
            <thead className="border-b bg-muted/40 text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
              <tr>
                <th className="px-4 py-3">{t("cases.case")}</th>
                <th className="px-4 py-3">{t("cases.severityLabel")}</th>
                <th className="px-4 py-3">{t("cases.target")}</th>
                <th className="px-4 py-3">{t("cases.alertState")}</th>
                <th className="px-4 py-3">{t("cases.resolutionState")}</th>
                <th className="px-4 py-3">{t("cases.owner")}</th>
                <th className="px-4 py-3">{t("cases.requiredAction")}</th>
                <th className="px-4 py-3">{t("cases.updated")}</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {records.map((incident) => (
                <tr key={incident.id} className="align-top hover:bg-muted/30">
                  <td className="max-w-80 px-4 py-3">
                    <Link
                      className="font-medium text-foreground hover:text-primary hover:underline"
                      to={`/cases/${incident.id}`}
                    >
                      {incident.title}
                    </Link>
                    <p className="mt-1 truncate text-xs text-muted-foreground">
                      {incident.source} · {incident.source_ref}
                    </p>
                  </td>
                  <td className="px-4 py-3">
                    <SeverityBadge severity={incident.severity} />
                  </td>
                  <td className="max-w-52 px-4 py-3 font-medium">
                    {targetName(incident.selected_target_id)}
                  </td>
                  <td className="px-4 py-3">
                    <Badge variant={incident.alert_state === "firing" ? "destructive" : "outline"}>
                      {t(`cases.alert.${incident.alert_state}`)}
                    </Badge>
                  </td>
                  <td className="px-4 py-3">
                    <Badge
                      variant={incident.status === "needs_attention" ? "destructive" : "secondary"}
                    >
                      {t(`cases.status.${incident.status}`)}
                    </Badge>
                  </td>
                  <td className="px-4 py-3">{ownerName(incident.current_owner_id)}</td>
                  <td className="max-w-72 px-4 py-3">
                    <RequiredAction incident={incident} />
                  </td>
                  <td className="whitespace-nowrap px-4 py-3 text-muted-foreground">
                    {formatDate(incident.updated_at, i18n.resolvedLanguage)}
                  </td>
                </tr>
              ))}
              {records.length === 0 && (
                <tr>
                  <td colSpan={8} className="px-4 py-10 text-center text-muted-foreground">
                    {query || status !== "all" || alertState !== "all"
                      ? t("cases.noMatchingCases")
                      : t("cases.noCases")}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
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
    </main>
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
    <Card className={urgent && value > 0 ? "border-destructive/60" : undefined}>
      <CardContent className="flex items-center justify-between p-4">
        <span className="text-sm text-muted-foreground">{label}</span>
        <span
          className={
            urgent && value > 0
              ? "text-2xl font-semibold text-destructive"
              : "text-2xl font-semibold"
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
    ? incident.required_human_input
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
