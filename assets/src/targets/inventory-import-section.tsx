import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { FileUp, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { PageControls } from "@/components/page-controls";
import { PagedSelect } from "@/components/paged-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type Provider = components["schemas"]["ProviderSummary"];
type InventoryImport = components["schemas"]["InventoryImport"];

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

export function InventoryImportSection({ canManage }: { canManage: boolean }) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [selectedProvider, setSelectedProvider] = useState<Provider | null>(null);
  const [error, setError] = useState("");
  const [header, setHeader] = useState<{
    id: string;
    record: InventoryImport | null;
    error: unknown;
  } | null>(null);
  const mounted = useRef(false);
  const selectedRead = useRef<AbortController | null>(null);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      selectedRead.current?.abort();
    };
  }, []);
  const history = usePagedData(
    useCallback(async (after: string | undefined, signal: AbortSignal) => {
      const result = apiData(
        await apiClient.GET("/api/v1/inventory-imports", {
          params: { query: { limit: 50, after } },
          signal,
        }),
      );
      if (!signal.aborted) setSelectedId((current) => current ?? result.data[0]?.id ?? null);
      return result;
    }, []),
  );
  const rowPage = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) => {
        if (!selectedId) return Promise.resolve({ data: [], page: { next: null } });
        return apiClient
          .GET("/api/v1/inventory-imports/{id}/rows/summaries", {
            params: { path: { id: selectedId }, query: { limit: 50, after } },
            signal,
          })
          .then(apiData);
      },
      [selectedId],
    ),
  );
  const loadProviders = useCallback(async (after: string | undefined, signal: AbortSignal) => {
    const result = apiData(
      await apiClient.GET("/api/v1/providers/summaries", {
        params: { query: { kinds: ["inventory"], eligible: true, limit: 50, after } },
        querySerializer: commaSeparatedQuery,
        signal,
      }),
    );
    if (!signal.aborted) setSelectedProvider((current) => current ?? result.data[0] ?? null);
    return result;
  }, []);
  const readSelected = useCallback(async () => {
    if (!selectedId || !mounted.current) return;
    selectedRead.current?.abort();
    const controller = new AbortController();
    selectedRead.current = controller;
    return Promise.resolve()
      .then(() =>
        apiClient.GET("/api/v1/inventory-imports/{id}", {
          params: { path: { id: selectedId } },
          signal: controller.signal,
        }),
      )
      .then(apiData)
      .then((result) => {
        if (!controller.signal.aborted)
          setHeader({ id: selectedId, record: result.data, error: null });
      })
      .catch((cause) => {
        if (!controller.signal.aborted) {
          setHeader((previous) => ({
            id: selectedId,
            record: previous?.id === selectedId ? previous.record : null,
            error: cause,
          }));
          throw cause;
        }
      });
  }, [selectedId]);
  useEffect(() => {
    void readSelected().catch(() => {});
    return () => selectedRead.current?.abort();
  }, [readSelected]);
  const currentHeader = header?.id === selectedId ? header : null;
  const selected = currentHeader?.record ?? null;
  const rows = rowPage.view?.data ?? [];
  async function refresh() {
    setError("");
    await Promise.allSettled([history.retry(), readSelected(), rowPage.retry()]);
  }

  async function mutate(
    key: string,
    action: () => Promise<InventoryImport>,
    form?: HTMLFormElement,
  ) {
    setPending(key);
    setError("");
    try {
      const next = await action();
      if (!mounted.current) return;
      selectedRead.current?.abort();
      setSelectedId(next.id);
      setHeader({ id: next.id, record: next, error: null });
      form?.reset();
      await history.retry();
    } catch {
      if (mounted.current) setError(t("targets.requestFailed"));
    } finally {
      if (mounted.current) setPending(null);
    }
  }

  async function previewManual(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const element = event.currentTarget;
    const form = new FormData(element);
    await mutate(
      "manual-preview",
      async () => {
        const response = apiData(
          await apiClient.POST("/api/v1/inventory-imports/manual-preview", {
            body: {
              inventory_import: { source: value(form, "source"), csv: value(form, "csv") },
            },
          }),
        );
        return response.data;
      },
      element,
    );
  }

  async function previewProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const element = event.currentTarget;
    const form = new FormData(element);
    const provider = selectedProvider;
    if (!provider) return;
    await mutate(
      "provider-preview",
      async () => {
        const response = apiData(
          await apiClient.POST("/api/v1/inventory-imports/provider-preview", {
            body: {
              inventory_import: {
                source: value(form, "source"),
                provider_id: provider.id,
                provider_revision: provider.revision,
                scope: {
                  resource: value(form, "resource"),
                  filters: {},
                  page_size: Number(value(form, "page_size")),
                },
              },
            },
          }),
        );
        return response.data;
      },
      element,
    );
  }

  async function applySelected() {
    if (!selected) return;
    await mutate(`apply-${selected.id}`, async () => {
      const response = apiData(
        await apiClient.POST("/api/v1/inventory-imports/{id}/apply", {
          params: { path: { id: selected.id } },
          body: {
            inventory_import: {
              expected_revision: selected.revision,
              expected_digest: selected.content_digest,
            },
          },
        }),
      );
      return response.data;
    });
  }

  return (
    <section className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold">{t("targets.importTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("targets.importDescription")}</p>
      </div>

      {!!(error || history.error || currentHeader?.error || rowPage.error) && (
        <Alert variant="destructive">
          <AlertDescription>{error || t("targets.requestFailed")}</AlertDescription>
        </Alert>
      )}
      <Button
        variant="outline"
        disabled={pending !== null || history.pending || rowPage.pending}
        onClick={() => void refresh()}
      >
        {t("common.refresh")}
      </Button>

      {canManage && (
        <div className="grid gap-4 xl:grid-cols-2">
          <Card className="min-w-0">
            <CardHeader>
              <CardTitle>{t("targets.manualImport")}</CardTitle>
              <CardDescription>{t("targets.manualImportDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="min-w-0 space-y-4" onSubmit={previewManual}>
                <div className="space-y-2">
                  <Label htmlFor="manual-source">{t("targets.source")}</Label>
                  <Input id="manual-source" name="source" placeholder="manual" required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="manual-csv">CSV</Label>
                  <Textarea
                    className="min-w-0"
                    id="manual-csv"
                    name="csv"
                    rows={8}
                    required
                    placeholder={
                      'external_id,identity_kind,name,kind,type_id,facts_json\nserver-1,linux,server-1,host,linux,"{}"'
                    }
                  />
                </div>
                <Button type="submit" disabled={pending !== null}>
                  {pending === "manual-preview" ? <Spinner /> : <FileUp />}
                  {t("targets.preview")}
                </Button>
              </form>
            </CardContent>
          </Card>

          <Card className="min-w-0">
            <CardHeader>
              <CardTitle>{t("targets.providerImport")}</CardTitle>
              <CardDescription>{t("targets.providerImportDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="grid min-w-0 gap-4 md:grid-cols-2" onSubmit={previewProvider}>
                <div className="space-y-2 md:col-span-2">
                  <PagedSelect
                    id="import-provider"
                    label={t("targets.connection")}
                    selected={selectedProvider}
                    onChange={setSelectedProvider}
                    load={loadProviders}
                    disabled={pending !== null}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="provider-source">{t("targets.source")}</Label>
                  <Input id="provider-source" name="source" defaultValue="netbox" required />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="provider-resource">{t("targets.resource")}</Label>
                  <FormSelect
                    id="provider-resource"
                    name="resource"
                    defaultValue="devices"
                    options={[
                      { value: "devices", label: "devices" },
                      { value: "virtual_machines", label: "virtual_machines" },
                    ]}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="provider-page-size">{t("targets.pageSize")}</Label>
                  <Input
                    id="provider-page-size"
                    name="page_size"
                    type="number"
                    min={1}
                    max={100}
                    defaultValue={50}
                    required
                  />
                </div>
                <Button
                  type="submit"
                  className="md:col-span-2 md:w-fit"
                  disabled={pending !== null || !selectedProvider}
                >
                  {pending === "provider-preview" ? <Spinner /> : <Plus />}
                  {t("targets.preview")}
                </Button>
              </form>
            </CardContent>
          </Card>
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-[minmax(16rem,0.8fr)_minmax(0,2fr)]">
        <Card className="min-w-0">
          <CardHeader>
            <CardTitle>{t("targets.importHistory")}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2" role="region" aria-label={t("targets.importHistory")}>
            {history.pending && <Spinner />}
            {history.view && (
              <PageControls
                index={history.view.index}
                hasNext={!!history.view.page.next}
                pending={history.pending}
                previous={history.previous}
                next={history.next}
              />
            )}
            {history.view?.data.length === 0 && !history.pending && !history.error && (
              <p className="text-sm text-muted-foreground">{t("targets.noImports")}</p>
            )}
            {history.view?.data.map((item) => (
              <Button
                key={item.id}
                variant={item.id === selectedId ? "secondary" : "ghost"}
                className="h-auto w-full justify-between py-3"
                disabled={pending !== null || history.pending}
                onClick={() => setSelectedId(item.id)}
              >
                <span className="min-w-0 truncate">{item.source}</span>
                <Badge variant="outline">{t(`targets.importStatus.${item.status}`)}</Badge>
              </Button>
            ))}
          </CardContent>
        </Card>

        <Card className="min-w-0">
          <CardHeader>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div>
                <CardTitle>{selected?.source ?? t("targets.importPreview")}</CardTitle>
                {selected && (
                  <CardDescription>
                    {t("targets.importCounts", {
                      rows: selected.row_count,
                      errors: selected.error_count,
                    })}
                  </CardDescription>
                )}
              </div>
              {canManage && selected?.status === "previewed" && selected.error_count === 0 && (
                <Button
                  disabled={pending !== null || !!currentHeader?.error}
                  onClick={() => void applySelected()}
                >
                  {pending === `apply-${selected.id}` && <Spinner />}
                  {t("targets.apply")}
                </Button>
              )}
            </div>
          </CardHeader>
          <CardContent role="region" aria-label={t("targets.importPreview")}>
            {selectedId && !currentHeader && <Spinner />}
            {rowPage.pending && selectedId && <Spinner />}
            {selected && rowPage.view && (
              <PageControls
                index={rowPage.view.index}
                hasNext={!!rowPage.view.page.next}
                pending={rowPage.pending}
                previous={rowPage.previous}
                next={rowPage.next}
              />
            )}
            {!selectedId ? (
              <p className="text-sm text-muted-foreground">{t("targets.selectImport")}</p>
            ) : selected &&
              !rowPage.pending &&
              !rowPage.error &&
              rowPage.view?.data.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t("targets.noImportRows")}</p>
            ) : selected ? (
              <div className="space-y-2">
                {rows.map((row) => (
                  <div key={row.id} className="rounded-md border p-3 text-sm">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-medium">{row.identity_value}</span>
                      <Badge variant={row.errors.length === 0 ? "secondary" : "destructive"}>
                        {t(`targets.importDisposition.${row.disposition}`)}
                      </Badge>
                    </div>
                    {row.errors.length > 0 && (
                      <div className="mt-1 text-destructive">
                        <p>{t("targets.importRowInvalid")}</p>
                        <details className="mt-1 text-xs">
                          <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                          <p className="mt-1">{row.errors.join(", ")}</p>
                        </details>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            ) : null}
          </CardContent>
        </Card>
      </div>
    </section>
  );
}
