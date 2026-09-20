import { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Spinner } from "@/components/ui/spinner";
import { ProviderSetup } from "@/providers/ai-section";
import { SignalProviderSection } from "@/providers/signal-section";
import { loadSettingsSnapshot, type SettingsSnapshot } from "@/settings/data";

type ProviderPageKind = "ai" | "signal";

function ProviderPage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

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
      {!canManage && (
        <Alert>
          <AlertDescription>{t("setup.readOnly")}</AlertDescription>
        </Alert>
      )}
      {kind === "ai" ? (
        <ProviderSetup
          providers={snapshot.providers}
          assignments={snapshot.assignments}
          canManage={canManage}
          onRefresh={refresh}
          onError={setError}
        />
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
