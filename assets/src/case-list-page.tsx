import { useCallback, useEffect, useState } from "react";
import { ArrowRight, RefreshCw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiCollection } from "@/api";
import { useAuthentication } from "@/auth-context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import type { CaseRecord, SignalEvent, SignalReceipt } from "@/case-types";
import { SignalProviderSection } from "@/signal-provider-section";
import type { Provider } from "@/setup-types";
import type { Target } from "@/target-types";

type Snapshot = {
  cases: CaseRecord[];
  receipts: SignalReceipt[];
  providers: Provider[];
  targets: Target[];
};

async function loadSnapshot(): Promise<Snapshot> {
  const [cases, receipts, providers, targets] = await Promise.all([
    apiCollection<CaseRecord>("/cases"),
    apiCollection<SignalReceipt>("/signal-receipts"),
    apiCollection<Provider>("/providers"),
    apiCollection<Target>("/targets"),
  ]);
  return { cases, receipts, providers, targets };
}

export function CaseListPage() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [events, setEvents] = useState<Record<string, SignalEvent[]>>({});
  const [loadingReceipt, setLoadingReceipt] = useState<string | null>(null);
  const [error, setError] = useState("");

  const refresh = useCallback(async () => {
    setSnapshot(await loadSnapshot());
  }, []);

  useEffect(() => {
    let active = true;
    loadSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch((failure: unknown) => {
        if (active) setError(failure instanceof Error ? failure.message : t("cases.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

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
      const records = await apiCollection<SignalEvent>(`/signal-receipts/${receiptId}/events`);
      setEvents((current) => ({ ...current, [receiptId]: records }));
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : t("cases.requestFailed"));
    } finally {
      setLoadingReceipt(null);
    }
  }

  if (!snapshot) {
    return (
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );
  }

  const targetName = (id: string | null) =>
    id ? (snapshot.targets.find((target) => target.id === id)?.name ?? id) : t("cases.unresolved");

  return (
    <main className="mx-auto w-full max-w-7xl space-y-10 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("cases.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("cases.description")}</p>
        </div>
        <Button variant="outline" onClick={() => void refresh()}>
          <RefreshCw />
          {t("cases.refresh")}
        </Button>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <SignalProviderSection
        providers={snapshot.providers}
        canManage={account?.role === "admin"}
        onRefresh={refresh}
        onError={setError}
      />

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-semibold">{t("cases.activeCases")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("cases.activeDescription")}</p>
        </div>
        <div className="grid gap-4 xl:grid-cols-2">
          {snapshot.cases.map((incident) => (
            <Card key={incident.id}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div className="min-w-0">
                    <CardTitle className="break-words">{incident.title}</CardTitle>
                    <CardDescription className="mt-1">
                      {incident.source} · {incident.source_ref}
                    </CardDescription>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Badge
                      variant={incident.status === "needs_attention" ? "destructive" : "secondary"}
                    >
                      {t(`cases.status.${incident.status}`)}
                    </Badge>
                    <Badge variant="outline">{t(`cases.severity.${incident.severity}`)}</Badge>
                  </div>
                </div>
              </CardHeader>
              <CardContent className="space-y-4">
                <dl className="grid gap-3 text-sm sm:grid-cols-2">
                  <Metric
                    label={t("cases.target")}
                    value={targetName(incident.selected_target_id)}
                  />
                  <Metric
                    label={t("cases.authority")}
                    value={t(`setup.modes.${incident.authority_mode}.name`)}
                  />
                  <Metric
                    label={t("cases.alertState")}
                    value={t(`cases.alert.${incident.alert_state}`)}
                  />
                  <Metric
                    label={t("cases.updated")}
                    value={formatDate(incident.updated_at, i18n.resolvedLanguage)}
                  />
                </dl>
                {incident.required_human_input && (
                  <p className="rounded-md border border-warning/30 bg-warning/10 p-3 text-sm">
                    {incident.required_human_input}
                  </p>
                )}
                <Button asChild size="sm">
                  <Link to={`/cases/${incident.id}`}>
                    {t("cases.openCase")}
                    <ArrowRight />
                  </Link>
                </Button>
              </CardContent>
            </Card>
          ))}
          {snapshot.cases.length === 0 && (
            <Card className="xl:col-span-2">
              <CardContent className="py-8 text-center text-sm text-muted-foreground">
                {t("cases.noCases")}
              </CardContent>
            </Card>
          )}
        </div>
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-semibold">{t("cases.receipts")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("cases.receiptsDescription")}</p>
        </div>
        <div className="divide-y rounded-lg border bg-card">
          {snapshot.receipts.map((receipt) => (
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
          {snapshot.receipts.length === 0 && (
            <p className="p-6 text-center text-sm text-muted-foreground">{t("cases.noReceipts")}</p>
          )}
        </div>
      </section>
    </main>
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
