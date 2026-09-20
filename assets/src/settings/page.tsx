import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Bot, Check, CircleDashed, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useLocation } from "react-router-dom";
import { AuthoritySetup } from "@/settings/authority-section";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { OIDCSetup } from "@/settings/oidc-section";
import { ProviderSetup } from "@/providers/ai-section";
import { SignalProviderSection } from "@/providers/signal-section";
import { loadSettingsSnapshot, readiness, type SettingsSnapshot } from "@/settings/data";

export function SetupPage() {
  const { t } = useTranslation();
  const { hash } = useLocation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  const refresh = useCallback(async () => {
    const next = await loadSettingsSnapshot();
    setSnapshot(next);
  }, []);

  useEffect(() => {
    let active = true;
    loadSettingsSnapshot()
      .then((next) => {
        if (active) setSnapshot(next);
      })
      .catch((failure: unknown) => {
        if (active) setError(failure instanceof Error ? failure.message : t("setup.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  useEffect(() => {
    if (!snapshot || !hash) return;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById(hash.slice(1))?.scrollIntoView();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [hash, snapshot]);

  if (!snapshot) {
    return (
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );
  }

  const status = readiness(snapshot);
  const activeAI = status.ai;
  const resolverReady = status.resolver;
  const activeAIIds = new Set(
    snapshot.providers
      .filter(
        (provider) =>
          provider.kind === "ai" &&
          provider.enabled &&
          provider.check.status === "passed" &&
          provider.check.checked_revision === provider.revision,
      )
      .map((provider) => provider.id),
  );
  const reviewerConfigured = snapshot.assignments.some(
    (assignment) =>
      assignment.role === "reviewer" &&
      assignment.enabled &&
      activeAIIds.has(assignment.provider_id),
  );

  return (
    <main className="mx-auto w-full max-w-7xl space-y-8 p-6 lg:p-8">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t("setup.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("setup.description")}</p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {!canManage && (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      )}

      <section className="grid gap-4 md:grid-cols-3" aria-label={t("setup.checklist")}>
        <StatusCard
          icon={<Bot />}
          title={t("setup.connectionStatus")}
          ready={activeAI}
          readyText={t("setup.ready")}
          pendingText={t("setup.connectionPending")}
        />
        <StatusCard
          icon={<Check />}
          title={t("setup.resolverStatus")}
          ready={resolverReady}
          readyText={t("setup.ready")}
          pendingText={t("setup.resolverPending")}
          detail={reviewerConfigured ? t("setup.reviewerReady") : t("setup.reviewerFallback")}
        />
        <StatusCard
          icon={<ShieldCheck />}
          title={t("setup.authorityStatus")}
          ready={status.authority}
          readyText={t(`setup.modes.${snapshot.authority.authority_mode}.name`)}
          pendingText={t("setup.authorityPending")}
          detail={
            snapshot.authority.signal_automation_enabled
              ? t("setup.automationOn")
              : t("setup.automationOff")
          }
        />
      </section>

      <ProviderSetup
        providers={snapshot.providers}
        assignments={snapshot.assignments}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
      <SignalProviderSection
        providers={snapshot.providers}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
      <OIDCSetup canManage={canManage} onError={setError} />
      <AuthoritySetup
        key={snapshot.authority.setting_revision}
        setting={snapshot.authority}
        canManage={canManage}
        onRefresh={refresh}
        onError={setError}
      />
    </main>
  );
}

function StatusCard({
  icon,
  title,
  ready,
  readyText,
  pendingText,
  detail,
}: {
  icon: ReactNode;
  title: string;
  ready: boolean;
  readyText: string;
  pendingText: string;
  detail?: string;
}) {
  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between">
        <CardTitle className="flex items-center gap-2 text-base">
          <span className="text-primary [&>svg]:size-4">{icon}</span>
          {title}
        </CardTitle>
        <Badge variant={ready ? "default" : "secondary"}>
          {ready ? <Check className="size-3" /> : <CircleDashed className="size-3" />}
          {ready ? readyText : pendingText}
        </Badge>
      </CardHeader>
      {detail && <CardContent className="text-sm text-muted-foreground">{detail}</CardContent>}
    </Card>
  );
}
