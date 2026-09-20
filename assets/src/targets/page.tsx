import { useEffect, useMemo, useState } from "react";
import { Cable, DatabaseZap, Link2, Plus, Search } from "lucide-react";
import { type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { apiClient } from "@/api/client";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";
import { TargetTopology } from "@/targets/topology";

export function TargetPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [editingRelationships, setEditingRelationships] = useState(false);
  const [draftRelationship, setDraftRelationship] = useState<{
    source: string;
    target: string;
  } | null>(null);
  const [relationshipKind, setRelationshipKind] = useState("hosted_by");
  const [relationshipPending, setRelationshipPending] = useState(false);
  const canManage = account?.role === "admin";

  useEffect(() => {
    let active = true;
    loadTargetSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch(() => {
        if (active) setError(t("targets.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  const activeTargets = useMemo(
    () => snapshot?.targets.filter((target) => target.active) ?? [],
    [snapshot],
  );
  const targets = useMemo(() => {
    if (!snapshot) return [];
    const search = query.trim().toLocaleLowerCase();
    return activeTargets
      .filter(
        (target) =>
          !search ||
          [target.name, target.kind, target.platform].some((value) =>
            value.toLocaleLowerCase().includes(search),
          ),
      )
      .sort((left, right) => left.name.localeCompare(right.name));
  }, [activeTargets, query, snapshot]);

  async function createRelationship(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draftRelationship) return;
    setRelationshipPending(true);
    setError("");
    try {
      await apiClient.POST("/api/v1/target-relationships", {
        body: {
          relationship: {
            source_target_id: draftRelationship.source,
            destination_target_id: draftRelationship.target,
            kind: relationshipKind,
            facts: {},
            valid_until: null,
          },
        },
      });
      setSnapshot(await loadTargetSnapshot());
      setDraftRelationship(null);
      setEditingRelationships(false);
      setRelationshipKind("hosted_by");
    } catch {
      setError(t("targets.requestFailed"));
    } finally {
      setRelationshipPending(false);
    }
  }

  if (!snapshot) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

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
          {canManage && (
            <Button asChild>
              <Link to="/targets/new">
                <Plus />
                {t("targets.addTarget")}
              </Link>
            </Button>
          )}
        </div>
      </div>

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}

      <section className="space-y-3">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h2 className="text-xl font-semibold">{t("targets.topology")}</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {t(
                editingRelationships
                  ? "targets.connectRelationshipInstruction"
                  : "targets.topologyDescription",
              )}
            </p>
          </div>
          {canManage && activeTargets.length > 1 && (
            <Button
              variant={editingRelationships ? "default" : "outline"}
              onClick={() => {
                setEditingRelationships((current) => !current);
                setDraftRelationship(null);
              }}
            >
              <Link2 />
              {t(editingRelationships ? "common.cancel" : "targets.addRelationship")}
            </Button>
          )}
        </div>
        {activeTargets.length > 0 ? (
          <TargetTopology
            targets={activeTargets}
            relationships={snapshot.relationships}
            methods={snapshot.methods}
            editMode={editingRelationships}
            draft={draftRelationship}
            onConnect={(source, target) => setDraftRelationship({ source, target })}
          />
        ) : (
          <Card>
            <CardContent className="py-10 text-center text-sm text-muted-foreground">
              {t("targets.noTargets")}
            </CardContent>
          </Card>
        )}
        {draftRelationship && (
          <Card>
            <CardContent className="pt-6">
              <form className="flex flex-wrap items-end gap-4" onSubmit={createRelationship}>
                <div className="min-w-64 flex-1">
                  <p className="text-sm font-medium">
                    {activeTargets.find((target) => target.id === draftRelationship.source)?.name}
                    {" → "}
                    {activeTargets.find((target) => target.id === draftRelationship.target)?.name}
                  </p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {t("targets.relationshipDirection")}
                  </p>
                </div>
                <div className="min-w-56 space-y-2">
                  <label htmlFor="topology-relationship-kind" className="text-sm font-medium">
                    {t("targets.relationshipKind")}
                  </label>
                  <Input
                    id="topology-relationship-kind"
                    value={relationshipKind}
                    onChange={(event) => setRelationshipKind(event.target.value)}
                    required
                    maxLength={80}
                  />
                </div>
                <Button type="submit" disabled={relationshipPending}>
                  {relationshipPending ? <Spinner /> : <Plus />}
                  {t("targets.saveRelationship")}
                </Button>
              </form>
            </CardContent>
          </Card>
        )}
      </section>

      <section className="space-y-4">
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
            onChange={(event) => setQuery(event.target.value)}
            placeholder={t("targets.searchPlaceholder")}
            aria-label={t("targets.searchPlaceholder")}
          />
        </div>

        {targets.length === 0 ? (
          <Card>
            <CardContent className="py-10 text-center text-sm text-muted-foreground">
              {t(query ? "targets.noSearchResults" : "targets.noTargets")}
            </CardContent>
          </Card>
        ) : (
          <div className="overflow-x-auto rounded-lg border bg-card">
            <table className="w-full min-w-[54rem] text-sm">
              <thead className="border-b bg-muted/40 text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
                <tr>
                  <th className="px-4 py-3">{t("targets.name")}</th>
                  <th className="px-4 py-3">{t("targets.kind")}</th>
                  <th className="px-4 py-3">{t("targets.platform")}</th>
                  <th className="px-4 py-3 text-right">{t("targets.accessMethods")}</th>
                  <th className="px-4 py-3 text-right">{t("targets.layerRelationships")}</th>
                  <th className="px-4 py-3 text-right">{t("targets.policies")}</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {targets.map((target) => {
                  const methods = snapshot.methods.filter(
                    (item) => item.target_id === target.id && item.active,
                  ).length;
                  const policies = snapshot.policies.filter(
                    (item) => item.target_id === target.id && item.enabled,
                  ).length;
                  const relationships = snapshot.relationships.filter(
                    (item) =>
                      item.active &&
                      (item.source_target_id === target.id ||
                        item.destination_target_id === target.id),
                  ).length;
                  return (
                    <tr key={target.id} className="hover:bg-muted/30">
                      <td className="px-4 py-3">
                        <Link
                          to={`/targets/${target.id}`}
                          className="font-medium text-foreground hover:text-primary hover:underline"
                        >
                          {target.name}
                        </Link>
                      </td>
                      <td className="px-4 py-3 text-muted-foreground">{target.kind}</td>
                      <td className="px-4 py-3">
                        <Badge variant="outline">{target.platform}</Badge>
                      </td>
                      <td className="px-4 py-3 text-right tabular-nums">{methods}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{relationships}</td>
                      <td className="px-4 py-3 text-right tabular-nums">{policies}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
