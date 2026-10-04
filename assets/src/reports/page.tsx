import { useCallback, useEffect, useRef, useState } from "react";
import { Plus, Printer, RefreshCw, Settings2, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useParams } from "react-router-dom";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";
import { usePagedData } from "@/api/use-paged-data";
import { useAuthentication } from "@/auth/context";
import { TechnicalDetails } from "@/components/technical-details";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
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
import { AutomaticReportSetting } from "@/reports/automatic-setting";

type Report = components["schemas"]["Report"];
type ReportSummary = components["schemas"]["ReportSummary"];
type Row = ReportSummary & {
  caseTitle: string;
  targetId: string | null;
  targetName: string | null;
  latestDelivery: components["schemas"]["LatestDeliverySummary"] | null;
};

async function readReportWindow(after: string | undefined, signal: AbortSignal) {
  const reports = await apiClient
    .GET("/api/v1/reports", {
      params: { query: { limit: 50, after } },
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  if (!reports.data.length) return { ...reports, data: [] as Row[] };
  const references = new AbortController();
  const referenceSignal = AbortSignal.any([signal, references.signal]);
  try {
    const [cases, deliveries] = await Promise.all([
      apiClient
        .GET("/api/v1/cases/summaries", {
          params: {
            query: { ids: [...new Set(reports.data.map((row) => row.case_id))], limit: 100 },
          },
          querySerializer: commaSeparatedQuery,
          signal: referenceSignal,
        })
        .then(apiData),
      apiClient
        .GET("/api/v1/deliveries/latest", {
          params: { query: { report_ids: reports.data.map((row) => row.id) } },
          querySerializer: commaSeparatedQuery,
          signal: referenceSignal,
        })
        .then(apiData),
    ]);
    signal.throwIfAborted();
    const targetIds = [
      ...new Set(
        cases.data
          .map((row) => row.selected_target_id ?? row.initial_target_id)
          .filter((id): id is string => !!id),
      ),
    ];
    const targets = targetIds.length
      ? await apiClient
          .GET("/api/v1/targets/summaries", {
            params: { query: { ids: targetIds, limit: 100 } },
            querySerializer: commaSeparatedQuery,
            signal: referenceSignal,
          })
          .then(apiData)
      : { data: [] };
    signal.throwIfAborted();
    const caseById = new Map(cases.data.map((row) => [row.id, row]));
    const targetById = new Map(targets.data.map((row) => [row.id, row.name]));
    const deliveryByReport = new Map(deliveries.data.map((row) => [row.report_id, row]));
    return {
      ...reports,
      data: reports.data.map((report) => {
        const incident = caseById.get(report.case_id);
        const targetId = incident?.selected_target_id ?? incident?.initial_target_id ?? null;
        return {
          ...report,
          caseTitle: incident?.title ?? report.case_id,
          targetId,
          targetName: targetId ? (targetById.get(targetId) ?? targetId) : null,
          latestDelivery: deliveryByReport.get(report.id) ?? null,
        };
      }),
    };
  } catch (failure) {
    references.abort();
    throw failure;
  }
}

export function ReportPage() {
  const { account } = useAuthentication();
  return <Reports key={`${account?.id}:${account?.role}`} />;
}

function Reports() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const page = usePagedData(readReportWindow);
  const retryWindow = useRef(page.retry);
  useEffect(() => {
    retryWindow.current = page.retry;
  }, [page.retry]);
  const snapshot = page.view;
  const [error, setError] = useState("");
  const [panel, setPanel] = useState<"generate" | "deliver" | "destinations" | null>(null);
  const [selectedReportId, setSelectedReportId] = useState("");
  const [deliveryRefreshKey, setDeliveryRefreshKey] = useState(0);
  const [settingRefreshKey, setSettingRefreshKey] = useState(0);
  const [detailReportId, setDetailReportId] = useState("");
  const canAct = account?.role === "admin" || account?.role === "operator";
  const canManageProviders = account?.role === "admin";
  const refresh = useCallback(async () => {
    await retryWindow.current();
    setDeliveryRefreshKey((value) => value + 1);
  }, []);

  function changeReportPage(direction: "previous" | "next") {
    setError("");
    setDetailReportId("");
    setSelectedReportId("");
    page[direction]();
  }

  const readError =
    error ||
    (page.error instanceof Error
      ? page.error.message
      : page.error
        ? t("reports.requestFailed")
        : "");
  if (!snapshot) {
    if (!readError) return <Loading />;
    return (
      <div className="space-y-4 p-6 lg:p-8">
        <Alert variant="destructive">
          <AlertDescription>{readError}</AlertDescription>
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
  const caseTitle = (id: string) =>
    snapshot.data.find((row) => row.case_id === id)?.caseTitle ?? id;
  const targetName = (id: string) =>
    snapshot.data.find((row) => row.targetId === id)?.targetName ?? id;
  const targetForCase = (id: string) =>
    snapshot.data.find((row) => row.case_id === id)?.targetId ?? null;

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

  const detailReport = snapshot.data.find((report) => report.id === detailReportId);

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
                .then(() => {
                  setError("");
                  setSettingRefreshKey((value) => value + 1);
                })
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
      {readError && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{readError}</AlertDescription>
        </Alert>
      )}
      {!canAct && (
        <Alert>
          <AlertDescription>{t("reports.readOnly")}</AlertDescription>
        </Alert>
      )}

      <AutomaticReportSetting refreshKey={settingRefreshKey} />

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
              {snapshot.data.map((report) => {
                const targetId = targetForCase(report.case_id);
                const latestDelivery = report.latestDelivery;
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
                          {latestDelivery.attempt_count > 1 && (
                            <span className="text-xs text-muted-foreground">
                              ×{latestDelivery.attempt_count}
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
              {snapshot.data.length === 0 && (
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
            disabled={snapshot.index === 0}
            onClick={() => changeReportPage("previous")}
          >
            {t("cases.previousPage")}
          </Button>
          <span className="text-sm text-muted-foreground">
            {t("cases.pageNumber", { page: snapshot.index + 1 })}
          </span>
          <Button
            variant="outline"
            disabled={!snapshot.page.next}
            onClick={() => changeReportPage("next")}
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
