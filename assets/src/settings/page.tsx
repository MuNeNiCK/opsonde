import { useEffect, useState, type ReactNode } from "react";
import { Bot, Check, CircleDashed, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
import { useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { AccountSection } from "@/settings/account-section";
import { OIDCSetup } from "@/settings/oidc-section";
import { loadSettingsSnapshot, readiness, type SettingsSnapshot } from "@/settings/data";

export function SetupPage() {
  const { t } = useTranslation();
  const { hash } = useLocation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  useEffect(() => {
    let active = true;
    loadSettingsSnapshot()
      .then((next) => {
        if (active) setSnapshot(next);
      })
      .catch(() => {
        if (active) setError(t("setup.requestFailed"));
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
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  const status = readiness(snapshot);
  const activeAI = status.ai;
  const resolverReady = status.resolver;
  const reviewerRequired = snapshot.authority.authority_mode === "auto" && !status.reviewer;

  return (
    <div className="space-y-8 p-6 lg:p-8">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">{t("setup.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("setup.description")}</p>
      </div>

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
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
          detail={status.reviewer ? t("setup.reviewerReady") : t("setup.reviewerNotAssigned")}
        />
        <StatusCard
          icon={<ShieldCheck />}
          title={t("setup.authorityStatus")}
          ready={status.authority}
          readyText={t(`setup.modes.${snapshot.authority.authority_mode}.name`)}
          pendingText={t(reviewerRequired ? "setup.reviewerRequired" : "setup.authorityPending")}
          detail={
            snapshot.authority.signal_automation_enabled
              ? t("setup.automationOn")
              : t("setup.automationOff")
          }
        />
      </section>

      {canManage && account && <AccountSection currentAccountId={account.id} />}
      <OIDCSetup canManage={canManage} onError={setError} />
    </div>
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
