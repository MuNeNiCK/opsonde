import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Spinner } from "@/components/ui/spinner";
import { InventoryImportSection } from "@/targets/inventory-import-section";
import { TargetProviderSection } from "@/providers/target-section";
import { TargetRegisterSection } from "@/targets/register-section";

type Provider = components["schemas"]["Provider"];
type ManagementBoundary = components["schemas"]["ManagementBoundary"];
type Target = components["schemas"]["Target"];
type ExternalIdentity = components["schemas"]["ExternalIdentity"];
type AccessMethod = components["schemas"]["AccessMethod"];
type TargetRelationship = components["schemas"]["TargetRelationship"];
type TargetPolicy = components["schemas"]["TargetPolicy"];
type InventoryImport = components["schemas"]["InventoryImport"];
type TargetSnapshot = {
  providers: Provider[];
  boundaries: ManagementBoundary[];
  targets: Target[];
  identities: ExternalIdentity[];
  methods: AccessMethod[];
  relationships: TargetRelationship[];
  policies: TargetPolicy[];
  imports: InventoryImport[];
};

async function loadSnapshot(): Promise<TargetSnapshot> {
  const [providers, boundaries, targets, identities, methods, relationships, policies, imports] =
    await Promise.all([
      collectPages((after) =>
        apiClient
          .GET("/api/v1/providers", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/management-boundaries", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/external-identities", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/access-methods", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/target-relationships", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/target-policies", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/inventory-imports", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
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
