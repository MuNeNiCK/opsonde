import { useEffect, useState } from "react";
import { ArrowLeft, Database, Server } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useNavigate, useParams } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { ProviderChoiceCard } from "@/providers/choice-card";
import { TargetConnectionForm, type ConnectionChoice } from "@/targets/connection-form";
import type { TargetTypeCatalog } from "@/targets/data";

const netboxChoice: ConnectionChoice = { id: "netbox", label: "NetBox", access_method_types: [] };

export function TargetConnectionCreatePage() {
  const { family } = useParams();
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const [catalog, setCatalog] = useState<TargetTypeCatalog | null>(null);
  const choice =
    family === "netbox" ? netboxChoice : catalog?.types.find((type) => type.id === family);

  useEffect(() => {
    let active = true;
    apiClient
      .GET("/api/v1/target-types")
      .then(apiData)
      .then((response) => {
        if (active) setCatalog(response.data);
      })
      .catch(() => {
        if (active) setError(t("targets.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  if (!catalog)
    return (
      <div className="flex flex-1 items-center justify-center gap-2 p-6 text-muted-foreground">
        {error ? (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : (
          <>
            <Spinner />
            {t("common.loading")}
          </>
        )}
      </div>
    );

  if (family && !choice) return <Navigate to="/targets/connections/new" replace />;

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={choice ? "/targets/connections/new" : "/targets/connections"}>
            <ArrowLeft />
            {t(choice ? "targets.backToConnectionTypes" : "targets.backToConnections")}
          </Link>
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">
          {choice
            ? t(`targets.typeLabels.${choice.id}`, { defaultValue: choice.label })
            : t("targets.chooseProviderType")}
        </h1>
        <p className="mt-2 text-muted-foreground">{t("targets.chooseProviderDescription")}</p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {account?.role !== "admin" ? (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      ) : choice ? (
        <TargetConnectionForm
          key={choice.id}
          choice={choice}
          catalog={catalog}
          onError={setError}
          onCreated={({ provider, checkPassed }) =>
            void navigate("/targets/connections", {
              replace: true,
              state: {
                created: "target",
                checkFailed: provider.kind === "inventory" && !checkPassed,
              },
            })
          }
        />
      ) : (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {[...catalog.types, netboxChoice].map((item) => {
            const category =
              "category_id" in item
                ? catalog.categories.find((category) => category.id === item.category_id)
                : null;
            return (
              <ProviderChoiceCard
                key={item.id}
                to={`/targets/connections/new/${item.id}`}
                title={t(`targets.typeLabels.${item.id}`, { defaultValue: item.label })}
                description={
                  item.id === "netbox"
                    ? t("targets.choiceNetBox")
                    : item.access_method_types
                        .map(
                          (type) =>
                            catalog.methods.find((method) => method.adapter_type === type)?.label ??
                            type,
                        )
                        .join(" · ")
                }
                badge={
                  category
                    ? t(`targets.categoryLabels.${category.id}`, { defaultValue: category.label })
                    : undefined
                }
                icon={item.id === "netbox" ? Database : Server}
              />
            );
          })}
        </div>
      )}
    </div>
  );
}
