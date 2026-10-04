import { useCallback, useEffect, useState } from "react";
import { Plus, Printer, RefreshCw, Settings2, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { TechnicalDetails } from "@/components/technical-details";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { NotificationProviderSection } from "@/providers/notification-section";
import { CaseReportDocument } from "@/reports/case-document";
import { ReportGenerateForm } from "@/reports/generate-form";
import { DeliveryCreateForm } from "@/reports/delivery-form";
import { DeliveryHistory } from "@/reports/delivery-history";

type CaseRecord = components["schemas"]["Case"];
type Delivery = components["schemas"]["Delivery"];
type Report = components["schemas"]["Report"];
type ReportSummary = components["schemas"]["ReportSummary"];
type Provider = components["schemas"]["Provider"];
type Target = components["schemas"]["Target"];
type ReportSetting = components["schemas"]["ReportSetting"];

type Snapshot = {
  cases: CaseRecord[];
  reports: ReportSummary[];
  reportNext: string | null;
  reportIndex: number;
  reportCursors: (string | null)[];
  deliveries: Delivery[];
  providers: Provider[];
  targets: Target[];
  setting: ReportSetting;
};
function loadReportPage(after: string | null) {
  return apiClient
    .GET("/api/v1/reports", { params: { query: { limit: 50, after: after ?? undefined } } })
    .then(apiData);
}
async function loadSnapshot(
  after: string | null,
): Promise<Omit<Snapshot, "reportIndex" | "reportCursors">> {
  const [cases, reports, deliveries, providers, targets, setting] = await Promise.all([
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    loadReportPage(after),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/deliveries", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/providers", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    apiClient
      .GET("/api/v1/report-setting")
      .then(apiData)
      .then((result) => result.data),
  ]);
  return {
    cases,
    reports: reports.data,
    reportNext: reports.page.next,
    deliveries,
    providers,
    targets,
    setting,
  };
}

export function ReportPage() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [panel, setPanel] = useState<"generate" | "deliver" | "destinations" | null>(null);
  const [selectedReportId, setSelectedReportId] = useState("");
  const [deliveryRefreshKey, setDeliveryRefreshKey] = useState(0);
  const [detailReportId, setDetailReportId] = useState("");
  const canAct = account?.role === "admin" || account?.role === "operator";
  const canManageProviders = account?.role === "admin";
  const reportCursor = snapshot?.reportCursors[snapshot.reportIndex] ?? null;
  const refresh = useCallback(async () => {
    const next = await loadSnapshot(reportCursor);
    setSnapshot((current) =>
      !current
        ? { ...next, reportIndex: 0, reportCursors: [null] }
        : current.reportCursors[current.reportIndex] === reportCursor
          ? { ...current, ...next }
          : current,
    );
    setDeliveryRefreshKey((value) => value + 1);
  }, [reportCursor]);

  useEffect(() => {
    let active = true;
    loadSnapshot(null)
      .then((next) => active && setSnapshot({ ...next, reportIndex: 0, reportCursors: [null] }))
      .catch((cause: unknown) => {
        if (active) setError(cause instanceof Error ? cause.message : t("reports.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  async function changeReportPage(index: number, cursor: string | null) {
    setPending("page");
    setError("");
    try {
      const page = await loadReportPage(cursor);
      setSnapshot((current) =>
        current
          ? {
              ...current,
              reports: page.data,
              reportNext: page.page.next,
              reportIndex: index,
              reportCursors: [...current.reportCursors.slice(0, index), cursor],
            }
          : current,
      );
      setDetailReportId("");
      setSelectedReportId("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t("reports.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  async function updateAutomaticGeneration(enabled: boolean) {
    if (!snapshot || !canManageProviders) return;
    setPending("setting");
    setError("");
    try {
      const result = await apiClient.PUT("/api/v1/report-setting", {
        body: {
          report_setting: {
            expected_revision: snapshot.setting.revision,
            automatic_case_reports_enabled: enabled,
          },
        },
      });
      const setting = apiData(result).data;
      setSnapshot((current) => (current ? { ...current, setting } : current));
    } catch {
      setError(t("reports.automaticUpdateFailed"));
      await refresh().catch(() => undefined);
    } finally {
      setPending(null);
    }
  }

  if (!snapshot) {
    if (!error) return <Loading />;
    return (
      <div className="space-y-4 p-6 lg:p-8">
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
        <Button
          variant="outline"
          onClick={() =>
            void refresh()
              .then(() => setError(""))
              .catch(() => setError(t("reports.requestFailed")))
          }
        >
          <RefreshCw /> {t("reports.refresh")}
        </Button>
      </div>
    );
  }
  const caseTitle = (id: string) => snapshot.cases.find((item) => item.id === id)?.title ?? id;
  const targetName = (id: string) => snapshot.targets.find((item) => item.id === id)?.name ?? id;
  const targetForCase = (id: string) => {
    const incident = snapshot.cases.find((item) => item.id === id);
    return incident?.selected_target_id ?? incident?.initial_target_id ?? null;
  };

  function openDelivery(reportId = "") {
    setSelectedReportId(reportId);
    setPanel("deliver");
    window.requestAnimationFrame(() => document.getElementById("report-action")?.scrollIntoView());
  }

  function toggleReportDetails(reportId: string) {
    if (detailReportId === reportId) {
      setDetailReportId("");
      return;
    }
    setDetailReportId(reportId);
    window.requestAnimationFrame(() =>
      document.getElementById(`report-detail-${reportId}`)?.scrollIntoView({ block: "nearest" }),
    );
  }

  const detailReport = snapshot.reports.find((report) => report.id === detailReportId);

  return (
    <div className="space-y-10 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("reports.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("reports.description")}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button asChild variant="outline">
            <Link to="/reports/operations">{t("reports.periodTitle")}</Link>
          </Button>
          <Button
            variant="outline"
            onClick={() =>
              void refresh()
                .then(() => setError(""))
                .catch((cause: unknown) =>
                  setError(cause instanceof Error ? cause.message : t("reports.requestFailed")),
                )
            }
          >
            <RefreshCw />
            {t("reports.refresh")}
          </Button>
          {canAct && (
            <Button onClick={() => setPanel(panel === "generate" ? null : "generate")}>
              {panel === "generate" ? <X /> : <Plus />}
              {t(panel === "generate" ? "common.cancel" : "reports.generate")}
            </Button>
          )}
          {canManageProviders && (
            <Button
              variant="outline"
              onClick={() => setPanel(panel === "destinations" ? null : "destinations")}
            >
              {panel === "destinations" ? <X /> : <Settings2 />}
              {t(panel === "destinations" ? "common.cancel" : "reports.manageDestinations")}
            </Button>
          )}
        </div>
      </div>
      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canAct && (
        <Alert>
          <AlertDescription>{t("reports.readOnly")}</AlertDescription>
        </Alert>
      )}

      <section className="flex flex-wrap items-center justify-between gap-4 rounded-lg border bg-card p-5">
        <div className="max-w-3xl">
          <h2 className="font-semibold">{t("reports.automaticTitle")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.automaticDescription")}</p>
          {!canManageProviders && (
            <p className="mt-2 text-xs text-muted-foreground">{t("reports.automaticAdminOnly")}</p>
          )}
        </div>
        <div className="flex items-center gap-3">
          {pending === "setting" && <Spinner />}
          <Label htmlFor="automatic-case-reports">
            {t(
              snapshot.setting.automatic_case_reports_enabled
                ? "reports.automaticOn"
                : "reports.automaticOff",
            )}
          </Label>
          <Switch
            id="automatic-case-reports"
            checked={snapshot.setting.automatic_case_reports_enabled}
            onCheckedChange={(enabled) => void updateAutomaticGeneration(enabled)}
            disabled={!canManageProviders || pending !== null}
          />
        </div>
      </section>

      {panel === "destinations" && <NotificationProviderSection canManage={canManageProviders} />}

      {canAct && (panel === "generate" || panel === "deliver") && (
        <section id="report-action">
          {panel === "generate" ? (
            <ReportGenerateForm onGenerated={refresh} onClose={() => setPanel(null)} />
          ) : (
            <DeliveryCreateForm
              initialReportId={selectedReportId}
              onEnqueued={refresh}
              onClose={() => {
                setPanel(null);
                setSelectedReportId("");
              }}
            />
          )}
        </section>
      )}

      <section className="space-y-4" aria-label={t("reports.history")}>
        <div>
          <h2 className="text-xl font-semibold">{t("reports.history")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.historyDescription")}</p>
        </div>
        <div className="rounded-lg border bg-card">
          <Table className="min-w-[68rem]">
            <TableHeader>
              <TableRow>
                <TableHead>{t("reports.columns.case")}</TableHead>
                <TableHead>{t("reports.columns.generated")}</TableHead>
                <TableHead>{t("reports.columns.outcome")}</TableHead>
                <TableHead>{t("reports.columns.records")}</TableHead>
                <TableHead>{t("reports.columns.format")}</TableHead>
                <TableHead>{t("reports.columns.delivery")}</TableHead>
                <TableHead className="text-right">{t("reports.columns.actions")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {snapshot.reports.map((report) => {
                const targetId = targetForCase(report.case_id);
                const deliveries = snapshot.deliveries
                  .filter((delivery) => delivery.report_id === report.id)
                  .sort((left, right) => left.enqueued_at.localeCompare(right.enqueued_at));
                const latestDelivery = deliveries.at(-1);
                return (
                  <TableRow
                    key={report.id}
                    id={`report-${report.id}`}
                    data-state={detailReportId === report.id ? "selected" : undefined}
                  >
                    <TableCell className="min-w-80 whitespace-normal">
                      <Link to={`/cases/${report.case_id}`} className="font-medium hover:underline">
                        {caseTitle(report.case_id)}
                      </Link>
                      {targetId && (
                        <Link
                          to={`/targets/${targetId}`}
                          className="mt-1 block text-xs text-muted-foreground hover:underline"
                        >
                          {targetName(targetId)}
                        </Link>
                      )}
                    </TableCell>
                    <TableCell>{formatDate(report.generated_at, i18n.resolvedLanguage)}</TableCell>
                    <TableCell>
                      <Badge variant="secondary">{t(`cases.status.${report.outcome}`)}</Badge>
                    </TableCell>
                    <TableCell>
                      {t("reports.recordCounts", {
                        operations: report.operation_count,
                        verifications: report.verification_count,
                      })}
                    </TableCell>
                    <TableCell>
                      <span className="uppercase">{report.language}</span> · r{report.case_revision}
                    </TableCell>
                    <TableCell>
                      {latestDelivery ? (
                        <div className="flex items-center gap-2">
                          <Badge
                            variant={
                              latestDelivery.status === "failed" ||
                              latestDelivery.status === "unknown"
                                ? "destructive"
                                : "outline"
                            }
                          >
                            {t(`reports.deliveryStatus.${latestDelivery.status}`)}
                          </Badge>
                          {deliveries.length > 1 && (
                            <span className="text-xs text-muted-foreground">
                              ×{deliveries.length}
                            </span>
                          )}
                        </div>
                      ) : (
                        <span className="text-muted-foreground">{t("reports.notDelivered")}</span>
                      )}
                    </TableCell>
                    <TableCell>
                      <div className="flex justify-end gap-2">
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => toggleReportDetails(report.id)}
                        >
                          {t(
                            detailReportId === report.id
                              ? "reports.hideDetails"
                              : "reports.viewDetails",
                          )}
                        </Button>
                        {canAct && (
                          <Button size="sm" onClick={() => openDelivery(report.id)}>
                            {t("reports.deliver")}
                          </Button>
                        )}
                      </div>
                    </TableCell>
                  </TableRow>
                );
              })}
              {snapshot.reports.length === 0 && (
                <TableRow>
                  <TableCell colSpan={7} className="py-8 text-center text-muted-foreground">
                    {t("reports.noReports")}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
        </div>
        <div className="flex items-center justify-between gap-3">
          <Button
            variant="outline"
            disabled={pending !== null || snapshot.reportIndex === 0}
            onClick={() =>
              void changeReportPage(
                snapshot.reportIndex - 1,
                snapshot.reportCursors[snapshot.reportIndex - 1],
              )
            }
          >
            {t("cases.previousPage")}
          </Button>
          <span className="text-sm text-muted-foreground">
            {t("cases.pageNumber", { page: snapshot.reportIndex + 1 })}
          </span>
          <Button
            variant="outline"
            disabled={pending !== null || !snapshot.reportNext}
            onClick={() => void changeReportPage(snapshot.reportIndex + 1, snapshot.reportNext)}
          >
            {t("cases.nextPage")}
          </Button>
        </div>
        {detailReport && (
          <Card id={`report-detail-${detailReport.id}`}>
            <CardHeader>
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <CardTitle>{caseTitle(detailReport.case_id)}</CardTitle>
                  <CardDescription>
                    {formatDate(detailReport.generated_at, i18n.resolvedLanguage)} · r
                    {detailReport.case_revision}
                  </CardDescription>
                </div>
                <Button size="sm" variant="ghost" onClick={() => setDetailReportId("")}>
                  <X /> {t("common.close")}
                </Button>
              </div>
            </CardHeader>
            <CardContent className="space-y-4">
              <SelectedReportBody key={detailReport.id} id={detailReport.id} />
              <div className="flex flex-wrap gap-2">
                <Button asChild size="sm" variant="outline">
                  <Link to={`/reports/${detailReport.id}/print`}>
                    <Printer /> {t("reports.print")}
                  </Link>
                </Button>
                <Button asChild size="sm" variant="outline">
                  <Link to={`/cases/${detailReport.case_id}`}>{t("reports.openCase")}</Link>
                </Button>
                {targetForCase(detailReport.case_id) && (
                  <Button asChild size="sm" variant="outline">
                    <Link to={`/targets/${targetForCase(detailReport.case_id)}`}>
                      {targetName(targetForCase(detailReport.case_id) as string)}
                    </Link>
                  </Button>
                )}
              </div>
            </CardContent>
          </Card>
        )}
      </section>

      <DeliveryHistory refreshKey={deliveryRefreshKey} canAct={canAct} onRetry={openDelivery} />
    </div>
  );
}

export function ReportPrintPage() {
  const { reportId } = useParams();
  const { t } = useTranslation();
  const [report, setReport] = useState<Report | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    if (!reportId) return;
    let active = true;
    apiClient
      .GET("/api/v1/reports/{id}", { params: { path: { id: reportId } } })
      .then((response) => apiData(response).data)
      .then((result) => active && setReport(result))
      .catch(() => active && setError(true));
    return () => {
      active = false;
    };
  }, [reportId]);

  if (error) return <p className="p-8">{t("reports.requestFailed")}</p>;
  if (!report) return <Loading />;

  return (
    <main className="mx-auto max-w-4xl space-y-6 p-6 text-foreground print:max-w-none print:p-0">
      <div className="flex items-center justify-between gap-3 print:hidden">
        <Button asChild variant="outline">
          <Link to="/reports">{t("reports.backToReports")}</Link>
        </Button>
        <Button onClick={() => window.print()}>
          <Printer /> {t("reports.print")}
        </Button>
      </div>
      <CaseReportDocument report={report} />
    </main>
  );
}

function SelectedReportBody({ id }: { id: string }) {
  const { t } = useTranslation();
  const [report, setReport] = useState<Report | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    apiClient
      .GET("/api/v1/reports/{id}", {
        params: { path: { id } },
        signal: controller.signal,
      })
      .then(apiData)
      .then((result) => {
        if (!controller.signal.aborted) setReport(result.data);
      })
      .catch((cause: unknown) => {
        if (!controller.signal.aborted)
          setError(cause instanceof Error ? cause.message : t("reports.requestFailed"));
      });
    return () => controller.abort();
  }, [id, t]);
  if (error)
    return (
      <Alert variant="destructive">
        <AlertDescription>{error}</AlertDescription>
      </Alert>
    );
  if (!report) return <Loading />;
  return (
    <>
      <CaseReportDocument report={report} />
      <p className="break-all font-mono text-xs text-muted-foreground">
        SHA-256 {report.content_digest}
      </p>
      <TechnicalDetails title={t("reports.technicalDetails")} value={report.content} />
    </>
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
function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
