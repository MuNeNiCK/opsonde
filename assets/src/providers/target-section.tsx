import { useState } from "react";
import { CheckCircle2, CircleAlert, Network } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient } from "@/api/client";
import type { components } from "@/api/schema";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";

type Provider = components["schemas"]["Provider"];

type Props = {
  providers: Provider[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

function firstFingerprintEndpoint(provider: Provider) {
  const fingerprints = provider.configuration.host_key_fingerprints;
  if (!fingerprints || typeof fingerprints !== "object" || Array.isArray(fingerprints)) return "";
  return Object.keys(fingerprints)[0] ?? "";
}

export function TargetProviderSection({ providers, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [checkInputs, setCheckInputs] = useState<Record<string, string>>({});
  const visibleProviders = providers.filter(
    (provider) => provider.kind === "target" || provider.kind === "inventory",
  );

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    try {
      await action();
      await onRefresh();
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  async function providerAction(provider: Provider, action: "check" | "enable" | "disable") {
    const checkInput =
      provider.kind === "target"
        ? {
            endpoint:
              checkInputs[provider.id] ||
              firstFingerprintEndpoint(provider) ||
              (typeof provider.configuration.base_url === "string"
                ? provider.configuration.base_url
                : ""),
          }
        : { resource: "devices", filters: {}, page_size: 50 };

    await mutate(`${provider.id}-${action}`, () => {
      if (action === "check") {
        return apiClient.POST("/api/v1/providers/{id}/check", {
          params: { path: { id: provider.id } },
          body: {
            provider: {
              expected_revision: provider.revision,
              check_input: checkInput,
            },
          },
        });
      }
      const body = { provider: { expected_revision: provider.revision } };
      if (action === "enable") {
        return apiClient.POST("/api/v1/providers/{id}/enable", {
          params: { path: { id: provider.id } },
          body,
        });
      }
      return apiClient.POST("/api/v1/providers/{id}/disable", {
        params: { path: { id: provider.id } },
        body,
      });
    });
  }

  return (
    <section className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold">{t("targets.connectionsTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("targets.connectionsDescription")}</p>
      </div>

      <div className="grid gap-4 xl:grid-cols-2">
        {visibleProviders.map((provider) => {
          const currentCheck = provider.check.checked_revision === provider.revision;
          const passed = currentCheck && provider.check.status === "passed";
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <CardTitle className="flex items-center gap-2 text-base">
                    <Network className="size-4" />
                    {provider.name}
                  </CardTitle>
                  <Badge variant={provider.enabled ? "default" : "secondary"}>
                    {t(provider.enabled ? "targets.enabled" : "targets.disabled")}
                  </Badge>
                </div>
                <CardDescription>{provider.adapter_type}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="flex items-start gap-2 text-sm">
                  {passed ? (
                    <CheckCircle2 className="mt-0.5 size-4 text-success" />
                  ) : (
                    <CircleAlert className="mt-0.5 size-4 text-warning" />
                  )}
                  <span>{t(passed ? "targets.checkPassed" : "targets.checkRequired")}</span>
                </div>
                {provider.check.message && (
                  <details className="text-sm text-muted-foreground">
                    <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                    <p>{provider.check.message}</p>
                  </details>
                )}
                {canManage && (
                  <div className="space-y-3">
                    {provider.kind === "target" && (
                      <Input
                        aria-label={t("targets.checkEndpoint")}
                        placeholder={t("targets.checkEndpoint")}
                        value={checkInputs[provider.id] ?? firstFingerprintEndpoint(provider)}
                        onChange={(event) =>
                          setCheckInputs((current) => ({
                            ...current,
                            [provider.id]: event.target.value,
                          }))
                        }
                      />
                    )}
                    <div className="flex flex-wrap gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending !== null}
                        onClick={() => void providerAction(provider, "check")}
                      >
                        {pending === `${provider.id}-check` && <Spinner />}
                        {t("targets.check")}
                      </Button>
                      {!provider.enabled ? (
                        <Button
                          size="sm"
                          disabled={!passed || pending !== null}
                          onClick={() => void providerAction(provider, "enable")}
                        >
                          {pending === `${provider.id}-enable` && <Spinner />}
                          {t("targets.enable")}
                        </Button>
                      ) : (
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={pending !== null}
                          onClick={() => void providerAction(provider, "disable")}
                        >
                          {pending === `${provider.id}-disable` && <Spinner />}
                          {t("targets.disable")}
                        </Button>
                      )}
                    </div>
                  </div>
                )}
              </CardContent>
            </Card>
          );
        })}
      </div>
    </section>
  );
}
