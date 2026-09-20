import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { TargetProviderSection } from "@/providers/target-section";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";

export function TargetConnectionsPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const location = useLocation();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [error, setError] = useState("");
  const success = (location.state as { created?: string } | null)?.created === "target";
  const canManage = account?.role === "admin";
  const refresh = useCallback(async () => setSnapshot(await loadTargetSnapshot()), []);

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

  if (!snapshot)
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <Button asChild size="sm" variant="ghost" className="-ml-3">
          <Link to="/targets">
            <ArrowLeft />
            {t("targets.back")}
          </Link>
        </Button>
        {canManage && (
          <Button asChild>
            <Link to="/targets/connections/new">
              <Plus />
              {t("targets.addConnection")}
            </Link>
          </Button>
        )}
      </div>
      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert>
          <Plus />
          <AlertDescription>{t("targets.connectionCreated")}</AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}
      <TargetProviderSection
        providers={snapshot.providers}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
    </div>
  );
}
