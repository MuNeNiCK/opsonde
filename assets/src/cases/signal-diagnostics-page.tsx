import { useEffect, useState } from "react";
import { ArrowLeft, RefreshCw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";

type SignalEvent = components["schemas"]["SignalEvent"];
type SignalReceiptPage = components["schemas"]["SignalReceiptPage"];

export function SignalDiagnosticsPage() {
  const { t, i18n } = useTranslation();
  const [page, setPage] = useState<SignalReceiptPage | null>(null);
  const [cursors, setCursors] = useState<Array<string | null>>([null]);
  const [pageIndex, setPageIndex] = useState(0);
  const [events, setEvents] = useState<Record<string, SignalEvent[]>>({});
  const [loadingReceipt, setLoadingReceipt] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [retryKey, setRetryKey] = useState(0);
  const [error, setError] = useState("");
  const cursor = cursors[pageIndex] ?? null;

  useEffect(() => {
    let active = true;
    apiClient
      .GET("/api/v1/signal-receipts", {
        params: { query: { limit: 50, after: cursor ?? undefined } },
      })
      .then(apiData)
      .then((next) => {
        if (!active) return;
        setPage(next);
        setError("");
      })
      .catch(() => {
        if (active) setError(t("cases.requestFailed"));
      })
      .finally(() => {
        if (active) setRefreshing(false);
      });
    return () => {
      active = false;
    };
  }, [cursor, retryKey, t]);

  async function openReceipt(receiptId: string) {
    if (events[receiptId]) {
      setEvents((current) => {
        const next = { ...current };
        delete next[receiptId];
        return next;
      });
      return;
    }

    setLoadingReceipt(receiptId);
    setError("");
    try {
      const response = await apiClient.GET("/api/v1/signal-receipts/{id}/events", {
        params: { path: { id: receiptId }, query: { limit: 100 } },
      });
      setEvents((current) => ({ ...current, [receiptId]: apiData(response).data }));
    } catch {
      setError(t("cases.requestFailed"));
    } finally {
      setLoadingReceipt(null);
    }
  }

  if (!page && !error) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  function nextPage() {
    if (!page?.page.next) return;
    const nextIndex = pageIndex + 1;
    setPage(null);
    setCursors((current) => [...current.slice(0, nextIndex), page.page.next]);
    setPageIndex(nextIndex);
  }

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3">
          <Link to="/cases">
            <ArrowLeft />
            {t("cases.back")}
          </Link>
        </Button>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">
              {t("cases.signalDiagnostics")}
            </h1>
            <p className="mt-2 text-muted-foreground">{t("cases.receiptsDescription")}</p>
          </div>
          <Button
            size="sm"
            variant="outline"
            disabled={refreshing}
            onClick={() => {
              setRefreshing(true);
              setRetryKey((value) => value + 1);
            }}
          >
            {refreshing ? <Spinner /> : <RefreshCw />}
            {t("cases.refresh")}
          </Button>
        </div>
      </div>

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <div className="divide-y rounded-lg border bg-card">
        {(page?.data ?? []).map((receipt) => (
          <div key={receipt.id} className="p-4">
            <button
              type="button"
              className="flex w-full items-center justify-between gap-4 text-left"
              onClick={() => void openReceipt(receipt.id)}
            >
              <span className="min-w-0">
                <span className="block truncate font-medium">{receipt.source}</span>
                <span className="block truncate font-mono text-xs text-muted-foreground">
                  {receipt.receipt_id}
                </span>
              </span>
              <span className="flex shrink-0 items-center gap-3 text-sm text-muted-foreground">
                {formatDate(receipt.received_at, i18n.resolvedLanguage)}
                <Badge variant="secondary">{receipt.event_count}</Badge>
                {loadingReceipt === receipt.id && <Spinner />}
              </span>
            </button>
            {events[receipt.id] && (
              <div className="mt-4 space-y-2 border-l pl-4">
                {events[receipt.id].map((event) => (
                  <div
                    key={event.id}
                    className="flex flex-wrap items-center justify-between gap-3 text-sm"
                  >
                    <span>
                      <Badge variant={event.state === "firing" ? "destructive" : "outline"}>
                        {t(`cases.alert.${event.state}`)}
                      </Badge>{" "}
                      <span className="ml-2 font-mono text-xs">{event.event_key}</span>
                    </span>
                    {event.case_id ? (
                      <Button asChild size="sm" variant="ghost">
                        <Link to={`/cases/${event.case_id}`}>{t("cases.openCase")}</Link>
                      </Button>
                    ) : (
                      <span className="text-muted-foreground">{t("cases.noCase")}</span>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        ))}
        {(page?.data.length ?? 0) === 0 && (
          <p className="p-8 text-center text-sm text-muted-foreground">{t("cases.noReceipts")}</p>
        )}
      </div>

      <div className="flex items-center justify-between">
        <Button
          variant="outline"
          disabled={pageIndex === 0}
          onClick={() => {
            setPage(null);
            setPageIndex((current) => Math.max(0, current - 1));
          }}
        >
          {t("cases.previousPage")}
        </Button>
        <span className="text-sm text-muted-foreground">
          {t("cases.pageNumber", { page: pageIndex + 1 })}
        </span>
        <Button variant="outline" disabled={!page?.page.next} onClick={nextPage}>
          {t("cases.nextPage")}
        </Button>
      </div>
    </div>
  );
}

function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
