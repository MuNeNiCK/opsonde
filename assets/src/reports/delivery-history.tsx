import { useEffect, useState } from "react";
import { RefreshCw, RotateCcw } from "lucide-react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { components } from "@/api/schema";
import { usePagedData } from "@/api/use-paged-data";
import { useAuthentication } from "@/auth/context";
import { PageControls } from "@/components/page-controls";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button, buttonVariants } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";

type Summary = components["schemas"]["DeliverySummary"];
type Row = Summary & { reportName: string; providerName: string };
type Props = { refreshKey: number; canAct: boolean; onRetry: (reportId: string) => void };

async function readHistory(after: string | undefined, signal: AbortSignal) {
  const deliveries = await apiClient
    .GET("/api/v1/deliveries/summaries", { params: { query: { limit: 50, after } }, signal })
    .then(apiData);
  signal.throwIfAborted();
  if (!deliveries.data.length) return { ...deliveries, data: [] as Row[] };
  const references = new AbortController();
  const referenceSignal = AbortSignal.any([signal, references.signal]);
  try {
    const [reports, providers] = await Promise.all([
      apiClient
        .GET("/api/v1/reports", {
          params: {
            query: { ids: [...new Set(deliveries.data.map((item) => item.report_id))], limit: 100 },
          },
          querySerializer: commaSeparatedQuery,
          signal: referenceSignal,
        })
        .then(apiData),
      apiClient
        .GET("/api/v1/providers/summaries", {
          params: {
            query: {
              ids: [...new Set(deliveries.data.map((item) => item.provider_id))],
              kinds: ["notification"],
              limit: 100,
            },
          },
          querySerializer: commaSeparatedQuery,
          signal: referenceSignal,
        })
        .then(apiData),
    ]);
    signal.throwIfAborted();
    const caseIds = [...new Set(reports.data.map((item) => item.case_id))];
    const cases = caseIds.length
      ? await apiClient
          .GET("/api/v1/cases/summaries", {
            params: { query: { ids: caseIds, limit: 100 } },
            querySerializer: commaSeparatedQuery,
            signal: referenceSignal,
          })
          .then(apiData)
      : { data: [] };
    signal.throwIfAborted();
    const titles = new Map(cases.data.map((item) => [item.id, item.title]));
    const reportNames = new Map(
      reports.data.map((item) => [
        item.id,
        `${titles.get(item.case_id) ?? item.case_id} · ${item.language} · r${item.case_revision}`,
      ]),
    );
    const providerNames = new Map(providers.data.map((item) => [item.id, item.name]));
    return {
      ...deliveries,
      data: deliveries.data.map((item) => ({
        ...item,
        reportName: reportNames.get(item.report_id) ?? item.report_id,
        providerName: providerNames.get(item.provider_id) ?? item.provider_id,
      })),
    };
  } catch (failure) {
    references.abort();
    throw failure;
  }
}

export function DeliveryHistory({ refreshKey, ...props }: Props) {
  const { account } = useAuthentication();
  return <History key={`${account?.id}:${account?.role}:${refreshKey}`} {...props} />;
}

function History({ canAct, onRetry }: Omit<Props, "refreshKey">) {
  const { t, i18n } = useTranslation();
  const page = usePagedData(readHistory);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  useEffect(() => {
    if (
      page.pending ||
      page.error != null ||
      !page.view?.data.some((item) => item.status === "queued" || item.status === "dispatching")
    )
      return;
    const timer = window.setTimeout(() => void page.retry().catch(() => {}), 4000);
    return () => window.clearTimeout(timer);
  }, [page]);
  return (
    <section className="space-y-4" aria-label={t("reports.deliveries")}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold">{t("reports.deliveries")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.deliveriesDescription")}</p>
        </div>
        <Button
          size="sm"
          variant="outline"
          disabled={page.pending}
          onClick={() => void page.retry().catch(() => {})}
        >
          <RefreshCw /> {t("reports.refresh")}
        </Button>
      </div>
      {page.error != null && (
        <Alert variant="destructive">
          <AlertDescription>
            {page.error instanceof Error ? page.error.message : t("reports.requestFailed")}
          </AlertDescription>
        </Alert>
      )}
      {page.pending && <Spinner />}
      <div className="divide-y rounded-lg border bg-card">
        {page.view?.data.map((item) => (
          <div key={item.id} className="p-4 text-sm">
            <div className="flex flex-wrap items-start justify-between gap-4">
              <div>
                <p className="font-medium">{item.reportName}</p>
                <p className="mt-1 text-muted-foreground">
                  {item.providerName} ·{" "}
                  {new Intl.DateTimeFormat(i18n.resolvedLanguage, {
                    dateStyle: "medium",
                    timeStyle: "short",
                  }).format(new Date(item.enqueued_at))}
                </p>
              </div>
              <Badge
                variant={
                  item.status === "failed" || item.status === "unknown"
                    ? "destructive"
                    : "secondary"
                }
              >
                {t(`reports.deliveryStatus.${item.status}`)}
              </Badge>
            </div>
            {item.reference && (
              <p className="mt-3 text-xs text-muted-foreground">
                {t("reports.deliveryReference")}: {item.reference}
              </p>
            )}
            <div className="mt-3 flex flex-wrap gap-2">
              <Link
                className={buttonVariants({ size: "sm", variant: "outline" })}
                to={`/reports/${item.report_id}/print`}
              >
                {t("reports.openReport")}
              </Link>
              {(item.status === "failed" || item.status === "unknown") && canAct && (
                <Button size="sm" onClick={() => onRetry(item.report_id)}>
                  <RotateCcw />
                  {t("reports.retryDelivery")}
                </Button>
              )}
              <Button
                size="sm"
                variant="ghost"
                aria-expanded={selectedId === item.id}
                onClick={() => setSelectedId(selectedId === item.id ? null : item.id)}
              >
                {t("reports.deliveryDetails")}
              </Button>
            </div>
            {selectedId === item.id && (
              <DeliveryDetails key={`${item.id}:${item.revision}`} summary={item} />
            )}
          </div>
        ))}
        {page.view?.data.length === 0 && (
          <p className="p-6 text-center text-sm text-muted-foreground">
            {t("reports.noDeliveries")}
          </p>
        )}
      </div>
      <PageControls
        index={page.view?.index ?? 0}
        hasNext={!!page.view?.page.next}
        pending={page.pending}
        previous={() => {
          setSelectedId(null);
          page.previous();
        }}
        next={() => {
          setSelectedId(null);
          page.next();
        }}
      />
    </section>
  );
}

function DeliveryDetails({ summary }: { summary: Summary }) {
  const { t } = useTranslation();
  const [details, setDetails] = useState<components["schemas"]["Delivery"]["details"] | null>(null);
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    const controller = new AbortController();
    void apiClient
      .GET("/api/v1/deliveries/{id}", {
        params: { path: { id: summary.id } },
        signal: controller.signal,
      })
      .then(apiData)
      .then((receipt) => {
        if (controller.signal.aborted) return;
        if (
          receipt.data.id !== summary.id ||
          receipt.data.report_id !== summary.report_id ||
          receipt.data.provider_id !== summary.provider_id ||
          receipt.data.revision < summary.revision
        )
          throw new Error(t("cases.stateChanged"));
        setDetails(receipt.data.details);
        setError("");
      })
      .catch((failure: unknown) => {
        if (!controller.signal.aborted)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      });
    return () => controller.abort();
  }, [summary.id, summary.report_id, summary.provider_id, summary.revision, attempt, t]);
  return (
    <div className="mt-3">
      {error ? (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
          <Button size="sm" variant="outline" onClick={() => setAttempt((value) => value + 1)}>
            {t("reports.refresh")}
          </Button>
        </Alert>
      ) : details === null ? (
        <Spinner />
      ) : (
        <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 text-xs">
          {JSON.stringify(details, null, 2)}
        </pre>
      )}
    </div>
  );
}
