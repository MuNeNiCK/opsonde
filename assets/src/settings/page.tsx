import { useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { AccountSection } from "@/settings/account-section";
import { OIDCSetup } from "@/settings/oidc-section";

export function SetupPage() {
  const { t } = useTranslation();
  const { hash } = useLocation();
  const { account } = useAuthentication();
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";

  useEffect(() => {
    if (!hash) return;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById(hash.slice(1))?.scrollIntoView();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [hash]);

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

      {canManage && account && <AccountSection currentAccountId={account.id} />}
      <OIDCSetup canManage={canManage} onError={setError} />
    </div>
  );
}
