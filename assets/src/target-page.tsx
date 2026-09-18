import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { apiCollection } from "@/api";
import { useAuthentication } from "@/auth-context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Spinner } from "@/components/ui/spinner";
import { InventoryImportSection } from "@/inventory-import-section";
import type { Provider } from "@/setup-types";
import { TargetProviderSection } from "@/target-provider-section";
import { TargetRegisterSection } from "@/target-register-section";
import type {
  AccessMethod,
  ExternalIdentity,
  InventoryImport,
  ManagementBoundary,
  Target,
  TargetPolicy,
  TargetRelationship,
  TargetSnapshot,
} from "@/target-types";

async function loadSnapshot(): Promise<TargetSnapshot> {
  const [providers, boundaries, targets, identities, methods, relationships, policies, imports] =
    await Promise.all([
      apiCollection<Provider>("/providers"),
      apiCollection<ManagementBoundary>("/management-boundaries"),
      apiCollection<Target>("/targets"),
      apiCollection<ExternalIdentity>("/external-identities"),
      apiCollection<AccessMethod>("/access-methods"),
      apiCollection<TargetRelationship>("/target-relationships"),
      apiCollection<TargetPolicy>("/target-policies"),
      apiCollection<InventoryImport>("/inventory-imports"),
    ]);
  return { providers, boundaries, targets, identities, methods, relationships, policies, imports };
}

export function TargetPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  const refresh = useCallback(async () => {
    setSnapshot(await loadSnapshot());
  }, []);

  useEffect(() => {
    let active = true;
    loadSnapshot()
      .then((next) => {
        if (active) setSnapshot(next);
      })
      .catch((failure: unknown) => {
        if (active)
          setError(failure instanceof Error ? failure.message : t("targets.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  if (!snapshot) {
    return (
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );
  }

  return (
    <main className="mx-auto w-full max-w-7xl space-y-10 p-6 lg:p-8">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t("targets.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("targets.description")}</p>
      </div>

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

      <TargetProviderSection
        providers={snapshot.providers}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
      <TargetRegisterSection
        providers={snapshot.providers}
        boundaries={snapshot.boundaries}
        targets={snapshot.targets}
        identities={snapshot.identities}
        methods={snapshot.methods}
        relationships={snapshot.relationships}
        policies={snapshot.policies}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
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
