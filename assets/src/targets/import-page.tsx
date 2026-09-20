import { useCallback, useEffect, useState } from "react";
import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";
import { InventoryImportSection } from "@/targets/inventory-import-section";

export function TargetImportPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const refresh = useCallback(async () => setSnapshot(await loadTargetSnapshot()), []);

  useEffect(() => {
    let active = true;
    loadTargetSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch(
        (failure: unknown) =>
          active &&
          setError(failure instanceof Error ? failure.message : t("targets.requestFailed")),
      );
    return () => {
      active = false;
    };
  }, [t]);

  if (!snapshot)
    return (
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );

  return (
    <main className="mx-auto w-full max-w-7xl space-y-6 p-6 lg:p-8">
      <Button asChild size="sm" variant="ghost" className="-ml-3">
        <Link to="/targets">
          <ArrowLeft />
          {t("targets.back")}
        </Link>
      </Button>
      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}
      <InventoryImportSection
        providers={snapshot.providers}
        imports={snapshot.imports}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
    </main>
  );
}
