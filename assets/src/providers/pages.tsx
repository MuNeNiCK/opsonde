import { useCallback, useEffect, useState } from "react";
import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useLocation, useNavigate } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { AIProviderCreateForm, ProviderSetup } from "@/providers/ai-section";
import { SignalProviderCreateForm, SignalProviderSection } from "@/providers/signal-section";
import { AuthoritySetup } from "@/settings/authority-section";
import { loadSettingsSnapshot, type SettingsSnapshot } from "@/settings/data";

type ProviderPageKind = "ai" | "signal";

function ProviderPage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const location = useLocation();
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const created = (location.state as { created?: ProviderPageKind } | null)?.created === kind;

  const refresh = useCallback(async () => {
    setSnapshot(await loadSettingsSnapshot());
  }, []);

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
    if (!snapshot || !location.hash) return;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById(location.hash.slice(1))?.scrollIntoView();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [location.hash, snapshot]);

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
      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {created && (
        <Alert>
          <AlertDescription>
            {t(kind === "ai" ? "setup.aiCreated" : "cases.signalCreated")}
          </AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      )}
      {kind === "ai" ? (
        <>
          <ProviderSetup
            providers={snapshot.providers}
            assignments={snapshot.assignments}
            canManage={canManage}
            onRefresh={refresh}
            onError={setError}
          />
          <AuthoritySetup
            key={snapshot.authority.setting_revision}
            setting={snapshot.authority}
            canManage={canManage}
            onRefresh={refresh}
            onError={setError}
          />
        </>
      ) : (
        <SignalProviderSection
          providers={snapshot.providers}
          canManage={canManage}
          onRefresh={refresh}
          onError={setError}
        />
      )}
    </div>
  );
}

export function AIProviderPage() {
  return <ProviderPage kind="ai" />;
}

export function SignalProviderPage() {
  return <ProviderPage kind="signal" />;
}

function ProviderCreatePage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const overview = kind === "ai" ? "/ai" : "/signals";

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={overview}>
            <ArrowLeft />
            {t(kind === "ai" ? "setup.backToAI" : "cases.backToSignals")}
          </Link>
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">
          {t(kind === "ai" ? "setup.addAI" : "cases.addSignal")}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {t(kind === "ai" ? "setup.aiDescription" : "cases.signalDescription")}
        </p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canManage ? (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      ) : kind === "ai" ? (
        <AIProviderCreateForm
          onCreated={() => void navigate("/ai", { replace: true, state: { created: "ai" } })}
          onError={setError}
        />
      ) : (
        <SignalProviderCreateForm
          onCreated={() =>
            void navigate("/signals", { replace: true, state: { created: "signal" } })
          }
          onError={setError}
        />
      )}
    </div>
  );
}

export function AIProviderCreatePage() {
  return <ProviderCreatePage kind="ai" />;
}

export function SignalProviderCreatePage() {
  return <ProviderCreatePage kind="signal" />;
}
