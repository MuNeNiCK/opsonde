import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { InventoryImportSection } from "@/targets/inventory-import-section";

export function TargetImportPage() {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const canManage = account?.role === "admin";

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <Button asChild size="sm" variant="ghost" className="-ml-3">
        <Link to="/targets">
          <ArrowLeft />
          {t("targets.back")}
        </Link>
      </Button>
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}
      <InventoryImportSection canManage={canManage} />
    </div>
  );
}
