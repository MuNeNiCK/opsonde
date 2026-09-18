import { useCallback, useEffect, useState, type FormEvent } from "react";
import { RefreshCw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiCollection, apiRequest } from "@/api";
import type { Delivery, Report } from "@/assurance-types";
import { useAuthentication } from "@/auth-context";
import type { CaseRecord } from "@/case-types";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { NotificationProviderSection } from "@/notification-provider-section";
import type { Provider } from "@/setup-types";

type Snapshot = {
  cases: CaseRecord[];
  reports: Report[];
  deliveries: Delivery[];
  providers: Provider[];
};
const selectClass =
  "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";

async function loadSnapshot(): Promise<Snapshot> {
  const [cases, reports, deliveries, providers] = await Promise.all([
    apiCollection<CaseRecord>("/cases"),
    apiCollection<Report>("/reports"),
    apiCollection<Delivery>("/deliveries"),
    apiCollection<Provider>("/providers"),
  ]);
  return { cases, reports, deliveries, providers };
}

export function ReportPage() {
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState("");
  const canAct = account?.role === "admin" || account?.role === "operator";
  const canManageProviders = account?.role === "admin";
  const refresh = useCallback(async () => setSnapshot(await loadSnapshot()), []);

  useEffect(() => {
    let active = true;
    loadSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch((failure: unknown) => {
        if (active)
          setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  useEffect(() => {
    if (
      !snapshot?.deliveries.some(
        (delivery) => delivery.status === "queued" || delivery.status === "dispatching",
      )
    )
      return;
    const timer = window.setInterval(() => void refresh().catch(() => undefined), 4000);
    return () => window.clearInterval(timer);
  }, [refresh, snapshot?.deliveries]);

  async function generate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const caseId = formValue(form, "case_id");
    const incident = snapshot?.cases.find((item) => item.id === caseId);
    if (!incident) return;
    await mutate("generate", () =>
      apiRequest(`/cases/${incident.id}/reports`, {
        method: "POST",
        body: JSON.stringify({ report: { expected_case_revision: incident.revision } }),
      }),
    );
  }

  async function deliver(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const report = snapshot?.reports.find((item) => item.id === formValue(form, "report_id"));
    const provider = snapshot?.providers.find((item) => item.id === formValue(form, "provider_id"));
    if (!report || !provider) return;
    await mutate("deliver", () =>
      apiRequest("/deliveries", {
        method: "POST",
        body: JSON.stringify({
          delivery: {
            report_id: report.id,
            report_revision: report.revision,
            provider_id: provider.id,
            provider_revision: provider.revision,
            idempotency_key: crypto.randomUUID(),
          },
        }),
      }),
    );
  }

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    setError("");
    try {
      await action();
      await refresh();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  if (!snapshot) return <Loading />;
  const reportable = snapshot.cases.filter((item) => item.status !== "running");
  const notificationProviders = snapshot.providers.filter(
    (provider) =>
      provider.kind === "notification" &&
      provider.enabled &&
      provider.check.status === "passed" &&
      provider.check.checked_revision === provider.revision,
  );
  const caseTitle = (id: string) => snapshot.cases.find((item) => item.id === id)?.title ?? id;
  const reportName = (id: string) => {
    const report = snapshot.reports.find((item) => item.id === id);
    return report ? `${caseTitle(report.case_id)} · ${report.language}` : id;
  };
  const providerName = (id: string) =>
    snapshot.providers.find((item) => item.id === id)?.name ?? id;

  return (
    <main className="mx-auto w-full max-w-7xl space-y-10 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("reports.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("reports.description")}</p>
        </div>
        <Button variant="outline" onClick={() => void refresh()}>
          <RefreshCw />
          {t("reports.refresh")}
        </Button>
      </div>
      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canAct && (
        <Alert>
          <AlertDescription>{t("reports.readOnly")}</AlertDescription>
        </Alert>
      )}

      <NotificationProviderSection
        providers={snapshot.providers}
        canManage={canManageProviders}
        onRefresh={refresh}
        onError={setError}
      />

      {canAct && (
        <section className="grid gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>{t("reports.generate")}</CardTitle>
              <CardDescription>{t("reports.generateDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="space-y-4" onSubmit={generate}>
                <div className="space-y-2">
                  <Label htmlFor="report-case">{t("reports.case")}</Label>
                  <select id="report-case" name="case_id" className={selectClass} required>
                    <option value="">{t("reports.chooseCase")}</option>
                    {reportable.map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.title} · {item.report_language} · r{item.revision}
                      </option>
                    ))}
                  </select>
                </div>
                <Button type="submit" disabled={pending !== null || reportable.length === 0}>
                  {pending === "generate" && <Spinner />}
                  {t("reports.generate")}
                </Button>
              </form>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>{t("reports.deliver")}</CardTitle>
              <CardDescription>{t("reports.deliverDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="space-y-4" onSubmit={deliver}>
                <div className="space-y-2">
                  <Label htmlFor="delivery-report">{t("reports.report")}</Label>
                  <select id="delivery-report" name="report_id" className={selectClass} required>
                    <option value="">{t("reports.chooseReport")}</option>
                    {snapshot.reports.map((item) => (
                      <option key={item.id} value={item.id}>
                        {caseTitle(item.case_id)} · {item.language} · {item.outcome}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="delivery-provider">{t("reports.destination")}</Label>
                  <select
                    id="delivery-provider"
                    name="provider_id"
                    className={selectClass}
                    required
                  >
                    <option value="">{t("reports.chooseDestination")}</option>
                    {notificationProviders.map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.name}
                      </option>
                    ))}
                  </select>
                </div>
                <Button
                  type="submit"
                  disabled={
                    pending !== null ||
                    snapshot.reports.length === 0 ||
                    notificationProviders.length === 0
                  }
                >
                  {pending === "deliver" && <Spinner />}
                  {t("reports.createDelivery")}
                </Button>
              </form>
            </CardContent>
          </Card>
        </section>
      )}

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-semibold">{t("reports.history")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.historyDescription")}</p>
        </div>
        <div className="grid gap-4 xl:grid-cols-2">
          {snapshot.reports.map((report) => (
            <Card key={report.id}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <CardTitle>{caseTitle(report.case_id)}</CardTitle>
                    <CardDescription>
                      {formatDate(report.generated_at, i18n.resolvedLanguage)} · r
                      {report.case_revision}
                    </CardDescription>
                  </div>
                  <div className="flex gap-2">
                    <Badge variant="outline">{report.language}</Badge>
                    <Badge variant="secondary">{t(`cases.status.${report.outcome}`)}</Badge>
                  </div>
                </div>
              </CardHeader>
              <CardContent className="space-y-3">
                <p className="break-all font-mono text-xs text-muted-foreground">
                  SHA-256 {report.content_digest}
                </p>
                <Button asChild size="sm" variant="outline">
                  <Link to={`/cases/${report.case_id}`}>{t("reports.openCase")}</Link>
                </Button>
                <details>
                  <summary className="cursor-pointer text-sm font-medium">
                    {t("reports.content")}
                  </summary>
                  <pre className="mt-3 max-h-96 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 text-xs">
                    {JSON.stringify(report.content, null, 2)}
                  </pre>
                </details>
              </CardContent>
            </Card>
          ))}
          {snapshot.reports.length === 0 && <Empty text={t("reports.noReports")} />}
        </div>
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-xl font-semibold">{t("reports.deliveries")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("reports.deliveriesDescription")}</p>
        </div>
        <div className="divide-y rounded-lg border bg-card">
          {snapshot.deliveries.map((delivery) => (
            <div key={delivery.id} className="p-4 text-sm">
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <p className="font-medium">{reportName(delivery.report_id)}</p>
                  <p className="mt-1 text-muted-foreground">
                    {providerName(delivery.provider_id)} ·{" "}
                    {formatDate(delivery.enqueued_at, i18n.resolvedLanguage)}
                  </p>
                </div>
                <Badge
                  variant={
                    delivery.status === "failed" || delivery.status === "unknown"
                      ? "destructive"
                      : "secondary"
                  }
                >
                  {t(`reports.deliveryStatus.${delivery.status}`)}
                </Badge>
              </div>
              {delivery.reference && (
                <p className="mt-3 break-all font-mono text-xs">{delivery.reference}</p>
              )}
              <details className="mt-3">
                <summary className="cursor-pointer text-xs text-muted-foreground">
                  {t("reports.deliveryDetails")}
                </summary>
                <pre className="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 text-xs">
                  {JSON.stringify(delivery.details, null, 2)}
                </pre>
              </details>
            </div>
          ))}
          {snapshot.deliveries.length === 0 && (
            <p className="p-6 text-center text-sm text-muted-foreground">
              {t("reports.noDeliveries")}
            </p>
          )}
        </div>
      </section>
    </main>
  );
}

function Loading() {
  const { t } = useTranslation();
  return (
    <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
      <Spinner />
      <span>{t("common.loading")}</span>
    </main>
  );
}
function Empty({ text }: { text: string }) {
  return (
    <Card className="xl:col-span-2">
      <CardContent className="py-8 text-center text-sm text-muted-foreground">{text}</CardContent>
    </Card>
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
