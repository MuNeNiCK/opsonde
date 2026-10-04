import { useCallback, useState } from "react";
import { Cable, DatabaseZap, Plus, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { apiClient, apiData } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import { PageControls } from "@/components/page-controls";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { TargetTopologySection } from "@/targets/topology-section";

export function TargetPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [query, setQuery] = useState("");
  const [focus, setFocus] = useState<string | null>(null);
  const search = query.trim();
  const inventory = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        apiClient
          .GET("/api/v1/targets/summaries", {
            params: { query: { active: true, query: search, limit: 50, after } },
            signal,
          })
          .then(apiData),
      [search],
    ),
  );
  const targets = inventory.view?.data ?? [];

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("targets.title")}</h1>
          <p className="mt-2 text-muted-foreground">{t("targets.inventoryDescription")}</p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button asChild variant="outline">
            <Link to="/targets/connections">
              <Cable />
              {t("targets.manageConnections")}
            </Link>
          </Button>
          <Button asChild variant="outline">
            <Link to="/targets/imports">
              <DatabaseZap />
              {t("targets.inventoryImport")}
            </Link>
          </Button>
          {account?.role === "admin" && (
            <Button asChild>
              <Link to="/targets/new">
                <Plus />
                {t("targets.addTarget")}
              </Link>
            </Button>
          )}
        </div>
      </div>
      <section className="space-y-4" aria-label={t("targets.inventory")}>
        <div>
          <h2 className="text-xl font-semibold">{t("targets.inventory")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {t("targets.inventoryTableDescription")}
          </p>
        </div>
        <div className="relative max-w-xl">
          <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="pl-9"
            value={query}
            maxLength={200}
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("targets.searchPlaceholder")}
            aria-label={t("targets.searchPlaceholder")}
          />
        </div>
        {inventory.error != null && (
          <Alert variant="destructive">
            <AlertDescription>{t("targets.requestFailed")}</AlertDescription>
            <Button variant="outline" onClick={() => void inventory.retry().catch(() => {})}>
              {t("common.refresh")}
            </Button>
          </Alert>
        )}
        {inventory.pending && (
          <div className="flex items-center gap-2">
            <Spinner />
            {t("common.loading")}
          </div>
        )}
        {inventory.view && (
          <>
            <PageControls
              index={inventory.view.index}
              hasNext={!!inventory.view.page.next}
              pending={inventory.pending}
              previous={inventory.previous}
              next={inventory.next}
            />
            {targets.length === 0 ? (
              <p className="py-10 text-center text-sm text-muted-foreground">
                {t(query ? "targets.noSearchResults" : "targets.noTargets")}
              </p>
            ) : (
              <div className="overflow-x-auto rounded-lg border">
                <table className="w-full text-left text-sm">
                  <thead className="bg-muted/30 text-muted-foreground">
                    <tr>
                      <th className="px-4 py-3">{t("targets.name")}</th>
                      <th className="px-4 py-3">{t("targets.kind")}</th>
                      <th className="px-4 py-3">{t("targets.typeId")}</th>
                      <th className="px-4 py-3 text-right">{t("targets.accessMethods")}</th>
                      <th className="px-4 py-3 text-right">{t("targets.layerRelationships")}</th>
                      <th className="px-4 py-3 text-right">{t("targets.operatingInstructions")}</th>
                      <th className="px-4 py-3">{t("targets.topology")}</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y">
                    {targets.map((target) => (
                      <tr key={target.id} className="hover:bg-muted/30">
                        <td className="px-4 py-3">
                          <Link
                            to={`/targets/${target.id}`}
                            className="font-medium hover:text-primary hover:underline"
                          >
                            {target.name}
                          </Link>
                        </td>
                        <td className="px-4 py-3 text-muted-foreground">{target.kind}</td>
                        <td className="px-4 py-3">
                          <Badge variant="outline">{target.type_id}</Badge>
                        </td>
                        <td className="px-4 py-3 text-right tabular-nums">{target.method_count}</td>
                        <td className="px-4 py-3 text-right tabular-nums">
                          {target.relationship_count}
                        </td>
                        <td className="px-4 py-3 text-right">
                          {target.has_operating_instructions ? "✓" : "—"}
                        </td>
                        <td className="px-4 py-3">
                          <Button size="sm" variant="outline" onClick={() => setFocus(target.id)}>
                            {t("targets.viewTopology")}
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )}
      </section>
      {focus ? (
        <TargetTopologySection key={focus} targetId={focus} onChange={inventory.reload} />
      ) : (
        <p className="text-sm text-muted-foreground">{t("targets.chooseTopologyTarget")}</p>
      )}
    </div>
  );
}
