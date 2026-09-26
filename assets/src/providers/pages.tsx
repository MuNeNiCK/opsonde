import { useCallback, useEffect, useState } from "react";
import { Activity, ArrowLeft, Bot, BrainCircuit, Webhook } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import { Label } from "@/components/ui/label";
import { AIProviderCreateForm, ProviderSetup } from "@/providers/ai-section";
import { ProviderChoiceCard } from "@/providers/choice-card";
import { SignalProviderCreateForm, SignalProviderSection } from "@/providers/signal-section";
import { loadSettingsSnapshot, type SettingsSnapshot } from "@/settings/data";

type ProviderPageKind = "ai" | "signal";
type AIService = components["schemas"]["AIService"];
type SignalAdapter = "alertmanager-webhook" | "generic-webhook" | "zabbix-webhook";

async function loadAIServices(): Promise<AIService[]> {
  return apiClient
    .GET("/api/v1/ai-services")
    .then(apiData)
    .then((response) => response.data);
}

const signalChoices = {
  "alertmanager-webhook": {
    title: "Alertmanager",
    description: "cases.choiceAlertmanager",
    icon: Activity,
  },
  "zabbix-webhook": {
    title: "Zabbix",
    description: "cases.choiceZabbix",
    icon: Webhook,
  },
  "generic-webhook": {
    title: "Generic Webhook",
    description: "cases.choiceGenericWebhook",
    icon: Webhook,
  },
} as const;

const aiAuthDescriptions: Record<AIService["auth"], string> = {
  api_key: "setup.cardApiKey",
  optional_api_key: "setup.cardOptionalApiKey",
  none: "setup.cardNoCredential",
  service_account_json: "setup.cardServiceAccount",
  oauth_access_token: "setup.cardOAuth",
};

const featuredAIServices = [
  "openai",
  "anthropic",
  "google",
  "google_vertex",
  "azure",
  "amazon_bedrock",
  "openrouter",
  "ollama",
];

function ProviderPage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const location = useLocation();
  const [snapshot, setSnapshot] = useState<SettingsSnapshot | null>(null);
  const [services, setServices] = useState<AIService[] | null>(null);
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const created = (location.state as { created?: ProviderPageKind } | null)?.created === kind;

  const refresh = useCallback(async () => {
    const [nextSnapshot, nextServices] = await Promise.all([
      loadSettingsSnapshot(),
      kind === "ai" ? loadAIServices() : Promise.resolve(null),
    ]);
    setSnapshot(nextSnapshot);
    setServices(nextServices);
  }, [kind]);

  useEffect(() => {
    let active = true;
    Promise.all([loadSettingsSnapshot(), kind === "ai" ? loadAIServices() : Promise.resolve(null)])
      .then(([next, nextServices]) => {
        if (active) {
          setSnapshot(next);
          setServices(nextServices);
        }
      })
      .catch(() => {
        if (active) setError(t("setup.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [kind, t]);

  useEffect(() => {
    if (!snapshot || !location.hash) return;
    const frame = window.requestAnimationFrame(() => {
      document.getElementById(location.hash.slice(1))?.scrollIntoView();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [location.hash, snapshot]);

  if (!snapshot || (kind === "ai" && !services)) {
    if (error) {
      return (
        <div className="p-6">
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        </div>
      );
    }
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
        <ProviderSetup
          providers={snapshot.providers}
          services={services ?? []}
          assignments={snapshot.assignments}
          authorityMode={snapshot.authority.authority_mode}
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

function ProviderCreatePage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const { providerType } = useParams();
  const [error, setError] = useState("");
  const [services, setServices] = useState<AIService[] | null>(null);
  const [serviceQuery, setServiceQuery] = useState("");
  const canManage = account?.role === "admin";
  const overview = kind === "ai" ? "/ai" : "/signals";
  const choiceEntries = Object.entries(signalChoices);
  const aiService = services?.find((item) => item.id === providerType);
  const filteredServices = (services ?? [])
    .filter((service) =>
      `${service.name} ${service.id}`
        .toLocaleLowerCase()
        .includes(serviceQuery.trim().toLocaleLowerCase()),
    )
    .sort((left, right) => {
      const leftRank = featuredAIServices.indexOf(left.id);
      const rightRank = featuredAIServices.indexOf(right.id);
      if (leftRank !== -1 || rightRank !== -1) {
        if (leftRank === -1) return 1;
        if (rightRank === -1) return -1;
        return leftRank - rightRank;
      }
      return left.name.localeCompare(right.name);
    });
  const selectedChoice = choiceEntries.find(([id]) => id === providerType)?.[1];
  const selected = kind === "ai" ? aiService?.id : selectedChoice ? providerType : undefined;

  useEffect(() => {
    if (kind !== "ai") return;
    let active = true;
    loadAIServices()
      .then((items) => {
        if (active) setServices(items);
      })
      .catch(() => {
        if (active) setError(t("setup.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [kind, t]);

  if (kind === "ai" && !services) {
    if (error) {
      return (
        <div className="p-6">
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        </div>
      );
    }
    return (
      <div className="p-8">
        <Spinner />
      </div>
    );
  }

  if (providerType && !selected) return <Navigate to={`${overview}/new`} replace />;

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={selected ? `${overview}/new` : overview}>
            <ArrowLeft />
            {t(
              selected
                ? kind === "ai"
                  ? "setup.backToAITypes"
                  : "cases.backToSignalTypes"
                : kind === "ai"
                  ? "setup.backToAI"
                  : "cases.backToSignals",
            )}
          </Link>
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">
          {(kind === "ai" ? aiService?.name : selectedChoice?.title) ??
            t(kind === "ai" ? "setup.chooseAIType" : "cases.chooseSignalType")}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {t(
            kind === "ai"
              ? "setup.chooseAITypeDescription"
              : selectedChoice
                ? selectedChoice.description
                : "cases.chooseSignalTypeDescription",
          )}
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
      ) : kind === "ai" && !selected ? (
        <div className="space-y-4">
          <div className="max-w-md space-y-2">
            <Label htmlFor="ai-service-search">{t("setup.searchAIServices")}</Label>
            <Input
              id="ai-service-search"
              type="search"
              value={serviceQuery}
              onChange={(event) => setServiceQuery(event.target.value)}
              placeholder={t("setup.searchAIServicesPlaceholder")}
            />
          </div>
          {filteredServices.length > 0 ? (
            <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              {filteredServices.map((service) => (
                <ProviderChoiceCard
                  key={service.id}
                  to={`/ai/new/${service.id}`}
                  title={service.name}
                  description={t(
                    service.id === "openai"
                      ? "setup.choiceOpenAI"
                      : service.id === "anthropic"
                        ? "setup.choiceAnthropic"
                        : aiAuthDescriptions[service.auth],
                  )}
                  icon={service.id === "openai" ? BrainCircuit : Bot}
                />
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">{t("setup.noAIServicesFound")}</p>
          )}
        </div>
      ) : !selected ? (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {choiceEntries.map(([id, item]) => (
            <ProviderChoiceCard
              key={id}
              to={`${overview}/new/${id}`}
              title={item.title}
              description={t(item.description)}
              icon={item.icon}
            />
          ))}
        </div>
      ) : kind === "ai" ? (
        <AIProviderCreateForm
          service={aiService!}
          onCreated={() => void navigate("/ai", { replace: true, state: { created: "ai" } })}
          onError={setError}
        />
      ) : (
        <SignalProviderCreateForm
          adapterType={selected as SignalAdapter}
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
