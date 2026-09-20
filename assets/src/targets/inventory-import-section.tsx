import { useEffect, useState, type FormEvent } from "react";
import { FileUp, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type Provider = components["schemas"]["Provider"];
type InventoryImport = components["schemas"]["InventoryImport"];
type InventoryImportRow = components["schemas"]["InventoryImportRow"];

type Props = {
  providers: Provider[];
  imports: InventoryImport[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

export function InventoryImportSection({
  providers,
  imports,
  canManage,
  onRefresh,
  onError,
}: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(imports[0]?.id ?? null);
  const [rows, setRows] = useState<InventoryImportRow[]>([]);
  const inventoryProviders = providers.filter(
    (provider) =>
      provider.kind === "inventory" &&
      provider.enabled &&
      provider.check.status === "passed" &&
      provider.check.checked_revision === provider.revision,
  );
  const selected = imports.find((item) => item.id === selectedId) ?? null;

  useEffect(() => {
    if (!selectedId) return;
    let active = true;
    collectPages((after) =>
      apiClient
        .GET("/api/v1/inventory-imports/{id}/rows", {
          params: { path: { id: selectedId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    )
      .then((next) => {
        if (active) setRows(next);
      })
      .catch(() => {
        if (active) onError(t("targets.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [onError, selectedId, t]);

  async function mutate(
    key: string,
    action: () => Promise<InventoryImport>,
    form?: HTMLFormElement,
  ) {
    setPending(key);
    onError("");
    try {
      const next = await action();
      setSelectedId(next.id);
      form?.reset();
      await onRefresh();
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(null);
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
    const provider = inventoryProviders.find((item) => item.id === value(form, "provider_id"));
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
                      'external_id,identity_kind,name,kind,platform,facts_json\nserver-1,linux,server-1,host,linux,"{}"'
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
                  <Label htmlFor="import-provider">{t("targets.connection")}</Label>
                  <FormSelect
                    id="import-provider"
                    name="provider_id"
                    required
                    defaultValue={inventoryProviders[0]?.id}
                    options={inventoryProviders.map((provider) => ({
                      value: provider.id,
                      label: provider.name,
                    }))}
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
                  disabled={pending !== null || inventoryProviders.length === 0}
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
          <CardContent className="space-y-2">
            {imports.length === 0 && (
              <p className="text-sm text-muted-foreground">{t("targets.noImports")}</p>
            )}
            {imports.map((item) => (
              <Button
                key={item.id}
                variant={item.id === selectedId ? "secondary" : "ghost"}
                className="h-auto w-full justify-between py-3"
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
                <Button disabled={pending !== null} onClick={() => void applySelected()}>
                  {pending === `apply-${selected.id}` && <Spinner />}
                  {t("targets.apply")}
                </Button>
              )}
            </div>
          </CardHeader>
          <CardContent>
            {!selected ? (
              <p className="text-sm text-muted-foreground">{t("targets.selectImport")}</p>
            ) : rows.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t("targets.noImportRows")}</p>
            ) : (
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
            )}
          </CardContent>
        </Card>
      </div>
    </section>
  );
}
