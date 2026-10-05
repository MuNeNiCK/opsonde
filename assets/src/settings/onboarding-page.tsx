import { useEffect, useState, type ReactNode } from "react";
import {
  ArrowRight,
  Bot,
  Check,
  CircleDashed,
  RadioTower,
  Server,
  ShieldCheck,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate } from "react-router-dom";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { loadSetupReadiness, type SetupReadiness } from "@/settings/data";
import { useAuthentication } from "@/auth/context";

type Step = {
  key: "ai" | "resolver" | "authority" | "signal" | "target";
  icon: ReactNode;
  href: string;
};

export function OnboardingPage() {
  const { account } = useAuthentication();
  return <Onboarding key={`${account?.id}:${account?.role}:${account?.role_version}`} />;
}

function Onboarding() {
  const { t } = useTranslation();
  const [status, setStatus] = useState<SetupReadiness | null | undefined>();
  const [error, setError] = useState("");

  useEffect(() => {
    const owner = new AbortController();
    loadSetupReadiness(owner.signal)
      .then((next) => !owner.signal.aborted && setStatus(next))
      .catch(() => {
        if (!owner.signal.aborted) {
          setStatus(null);
          setError(t("setup.requestFailed"));
        }
      });
    return () => {
      owner.abort();
    };
  }, [t]);

  if (status === undefined) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  if (status === null) {
    return (
      <div className="p-6 lg:p-8">
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      </div>
    );
  }

  if (status.complete) return <Navigate to="/cases" replace />;

  const steps: Step[] = [
    { key: "ai", icon: <Bot />, href: "/ai/new" },
    { key: "resolver", icon: <Bot />, href: "/ai#ai-connections" },
    {
      key: "authority",
      icon: <ShieldCheck />,
      href:
        status.authority_mode === "auto" && !status.reviewer
          ? "/ai#ai-connections"
          : "/ai/authority",
    },
    { key: "signal", icon: <RadioTower />, href: "/signals/new" },
    {
      key: "target",
      icon: <Server />,
      href: status.first_target_id ? `/targets/${status.first_target_id}` : "/targets/new",
    },
  ];
  const completed = steps.filter((step) => status[step.key]).length;

  return (
    <div className="space-y-8 p-6 lg:p-8">
      <div className="space-y-2">
        <Badge variant="secondary">
          {t("onboarding.progress", { completed, total: steps.length })}
        </Badge>
        <h1 className="text-3xl font-semibold tracking-tight">{t("onboarding.title")}</h1>
        <p className="max-w-3xl text-muted-foreground">{t("onboarding.description")}</p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      <div className="grid gap-4 md:grid-cols-2">
        {steps.map((step) => {
          const ready = status[step.key];
          return (
            <Card key={step.key}>
              <CardHeader className="flex-row items-start justify-between gap-4">
                <div className="space-y-2">
                  <CardTitle className="flex items-center gap-2 text-base">
                    <span className="text-primary [&>svg]:size-4">{step.icon}</span>
                    {t(`onboarding.steps.${step.key}.title`)}
                  </CardTitle>
                  <p className="text-sm text-muted-foreground">
                    {step.key === "authority" &&
                    status.authority_mode === "auto" &&
                    !status.reviewer
                      ? t("onboarding.steps.authority.reviewerRequired")
                      : t(`onboarding.steps.${step.key}.description`)}
                  </p>
                </div>
                <Badge variant={ready ? "default" : "secondary"}>
                  {ready ? <Check className="size-3" /> : <CircleDashed className="size-3" />}
                  {t(ready ? "onboarding.ready" : "onboarding.pending")}
                </Badge>
              </CardHeader>
              {!ready && (
                <CardContent>
                  <Button asChild size="sm">
                    <Link to={step.href}>
                      {step.key === "authority" &&
                      status.authority_mode === "auto" &&
                      !status.reviewer
                        ? t("onboarding.steps.authority.assignReviewer")
                        : t(`onboarding.steps.${step.key}.action`)}
                      <ArrowRight />
                    </Link>
                  </Button>
                </CardContent>
              )}
            </Card>
          );
        })}

        <Card>
          <CardHeader className="flex-row items-start justify-between gap-4">
            <div className="space-y-2">
              <CardTitle className="text-base">{t("onboarding.oidcTitle")}</CardTitle>
              <p className="text-sm text-muted-foreground">{t("onboarding.oidcDescription")}</p>
            </div>
            <Badge variant="outline">{t("onboarding.optional")}</Badge>
          </CardHeader>
          <CardContent>
            <Button asChild size="sm" variant="outline">
              <Link to="/settings#oidc">{t("onboarding.configureOIDC")}</Link>
            </Button>
          </CardContent>
        </Card>
      </div>

      <div className="flex flex-wrap items-center gap-3 border-t pt-6">
        <Button asChild variant="outline">
          <Link to="/cases">{t("onboarding.continueLater")}</Link>
        </Button>
        <p className="text-sm text-muted-foreground">{t("onboarding.resume")}</p>
      </div>
    </div>
  );
}
