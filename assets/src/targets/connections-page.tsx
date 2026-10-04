import { useCallback, useState } from "react";
import { ArrowLeft, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import { PageControls } from "@/components/page-controls";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { TargetProviderSection } from "@/providers/target-section";

export function TargetConnectionsPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const location = useLocation();
  const [error, setError] = useState("");
  const success = (location.state as { created?: string } | null)?.created === "target";
  const checkFailed = (location.state as { checkFailed?: boolean } | null)?.checkFailed === true;
  const canManage = account?.role === "admin";
  const providers = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        apiClient
          .GET("/api/v1/providers/summaries", {
            params: { query: { kinds: ["target", "inventory"], limit: 50, after } },
            querySerializer: commaSeparatedQuery,
            signal,
          })
          .then(apiData),
      [],
    ),
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
      {!!(error || providers.error) && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error || t("targets.requestFailed")}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert variant={checkFailed ? "destructive" : "default"}>
          <Plus />
          <AlertDescription>
            {t(checkFailed ? "targets.connectionSavedCheckFailed" : "targets.connectionCreated")}
          </AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}
      <Button
        variant="outline"
        disabled={providers.pending}
        onClick={() => {
          setError("");
          void providers.retry().catch(() => {});
        }}
      >
        {t("common.refresh")}
      </Button>
      {providers.pending && (
        <div className="flex items-center gap-2 text-muted-foreground">
          <Spinner />
          {t("common.loading")}
        </div>
      )}
      {providers.view && (
        <>
          <PageControls
            index={providers.view.index}
            hasNext={!!providers.view.page.next}
            pending={providers.pending}
            previous={providers.previous}
            next={providers.next}
          />
          <TargetProviderSection
            providers={providers.view.data}
            canManage={canManage}
            readPending={providers.pending || !!providers.error}
            onRefresh={providers.retry}
            onError={setError}
          />
        </>
      )}
    </div>
  );
}
