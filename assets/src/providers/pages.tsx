import { useCallback, useEffect, useState } from "react";
import { Activity, ArrowLeft, Bot, BrainCircuit, Webhook } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useLocation, useNavigate, useParams } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { AIProviderCreateForm, ProviderSetup } from "@/providers/ai-section";
import { ProviderChoiceCard } from "@/providers/choice-card";
import { SignalProviderCreateForm, SignalProviderSection } from "@/providers/signal-section";
import { loadSettingsSnapshot, type SettingsSnapshot } from "@/settings/data";

type ProviderPageKind = "ai" | "signal";
type AIService = "openai" | "anthropic";
type SignalAdapter = "alertmanager-webhook" | "generic-webhook" | "zabbix-webhook";

const aiChoices = {
  openai: { title: "OpenAI", description: "setup.choiceOpenAI", icon: BrainCircuit },
  anthropic: { title: "Anthropic", description: "setup.choiceAnthropic", icon: Bot },
} as const;

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

function ProviderCreatePage({ kind }: { kind: ProviderPageKind }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const { providerType } = useParams();
  const [error, setError] = useState("");
  const canManage = account?.role === "admin";
  const overview = kind === "ai" ? "/ai" : "/signals";
  const choices = kind === "ai" ? aiChoices : signalChoices;
  const choiceEntries = Object.entries(choices);
  const selectedChoice = choiceEntries.find(([id]) => id === providerType)?.[1];
  const selected = selectedChoice ? providerType : undefined;

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
          {selectedChoice?.title ??
            t(kind === "ai" ? "setup.chooseAIType" : "cases.chooseSignalType")}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {t(
            selectedChoice
              ? selectedChoice.description
              : kind === "ai"
                ? "setup.chooseAITypeDescription"
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
          service={selected as AIService}
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
