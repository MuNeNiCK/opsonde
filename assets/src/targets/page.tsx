import { useEffect, useMemo, useState } from "react";
import { Cable, DatabaseZap, Plus, Search } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";

export function TargetPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
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

  const targets = useMemo(() => {
    if (!snapshot) return [];
    const search = query.trim().toLocaleLowerCase();
    return snapshot.targets
      .filter((target) => target.active)
      .filter(
        (target) =>
          !search ||
          [target.name, target.kind, target.platform].some((value) =>
            value.toLocaleLowerCase().includes(search),
          ),
      )
      .sort((left, right) => left.name.localeCompare(right.name));
  }, [query, snapshot]);

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
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {targets.map((target) => {
            const methods = snapshot.methods.filter(
              (item) => item.target_id === target.id && item.active,
            );
            const policies = snapshot.policies.filter(
              (item) => item.target_id === target.id && item.enabled,
            );
            const relationships = snapshot.relationships.filter(
              (item) =>
                item.active &&
                (item.source_target_id === target.id || item.destination_target_id === target.id),
            );
            return (
              <Link
                key={target.id}
                to={"/targets/" + target.id}
                className="group rounded-xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                <Card className="h-full transition-colors group-hover:border-primary/50">
                  <CardHeader>
                    <div className="flex items-start justify-between gap-3">
                      <CardTitle className="text-base">{target.name}</CardTitle>
                      <Badge variant="outline">{target.platform}</Badge>
                    </div>
                    <CardDescription>{target.kind}</CardDescription>
                  </CardHeader>
                  <CardContent className="grid grid-cols-3 gap-3 text-sm">
                    <Metric label={t("targets.accessMethods")} value={methods.length} />
                    <Metric label={t("targets.layerRelationships")} value={relationships.length} />
                    <Metric label={t("targets.policies")} value={policies.length} />
                  </CardContent>
                </Card>
              </Link>
            );
          })}
        </div>
      )}
    </div>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className="mt-1 font-medium">{value}</p>
    </div>
  );
}
