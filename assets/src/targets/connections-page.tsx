import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, Cable, DatabaseZap, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { TargetProviderSection } from "@/providers/target-section";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";

type CreateKind = "target" | "inventory" | null;

export function TargetConnectionsPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [createKind, setCreateKind] = useState<CreateKind>(null);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
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
    <div className="mx-auto w-full max-w-7xl space-y-6 p-6 lg:p-8">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <Button asChild size="sm" variant="ghost" className="-ml-3">
          <Link to="/targets">
            <ArrowLeft />
            {t("targets.back")}
          </Link>
        </Button>
        {canManage && (
          <div className="flex flex-wrap gap-2">
            <Button
              variant={createKind === "target" ? "default" : "outline"}
              onClick={() => setCreateKind(createKind === "target" ? null : "target")}
            >
              <Cable />
              {t("targets.addConnection")}
            </Button>
            <Button
              variant={createKind === "inventory" ? "default" : "outline"}
              onClick={() => setCreateKind(createKind === "inventory" ? null : "inventory")}
            >
              <DatabaseZap />
              {t("targets.addNetBox")}
            </Button>
          </div>
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
          <AlertDescription>{success}</AlertDescription>
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
        createKind={createKind}
        onRefresh={refresh}
        onError={setError}
        onCreated={() => {
          setCreateKind(null);
          setSuccess(t("targets.connectionCreated"));
        }}
      />
    </div>
  );
}
