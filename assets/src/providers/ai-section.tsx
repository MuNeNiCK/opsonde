import { useState, type FormEvent } from "react";
import { CheckCircle2, CircleAlert, KeyRound, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient } from "@/api/client";
import type { components } from "@/api/schema";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";

type AIUsageRoleAssignment = components["schemas"]["AIUsageRoleAssignment"];
type Provider = components["schemas"]["Provider"];

type Props = {
  providers: Provider[];
  assignments: AIUsageRoleAssignment[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

function selectClassName() {
  return "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";
}

function configurationValue(provider: Provider, key: string) {
  const value = provider.configuration[key];
  return typeof value === "string" ? value : "";
}

export function ProviderSetup({ providers, assignments, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const aiProviders = providers.filter((provider) => provider.kind === "ai");

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    try {
      await action();
      await onRefresh();
      return true;
    } catch {
      onError(t("setup.requestFailed"));
      return false;
    } finally {
      setPending(null);
    }
  }

  async function createProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const name = form.get("name");
    const service = form.get("service");
    const model = form.get("model");
    const endpoint = form.get("endpoint");
    const apiKey = form.get("api_key");

    if (
      typeof name !== "string" ||
      typeof service !== "string" ||
      typeof model !== "string" ||
      typeof endpoint !== "string" ||
      typeof apiKey !== "string"
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    const configuration: Record<string, string> = { provider: service, model };
    if (endpoint) configuration.endpoint = endpoint;
    const credentials = apiKey ? { api_key: apiKey } : {};

    const created = await mutate("create-provider", () =>
      apiClient.POST("/api/v1/providers", {
        body: {
          provider: {
            name,
            kind: "ai",
            adapter_type: "req-llm",
            configuration,
            credentials,
          },
        },
      }),
    );

    if (created) formElement.reset();
  }

  async function providerAction(provider: Provider, action: "check" | "enable" | "disable") {
    const body = { provider: { expected_revision: provider.revision } };
    await mutate(`${provider.id}-${action}`, () => {
      if (action === "check") {
        return apiClient.POST("/api/v1/providers/{id}/check", {
          params: { path: { id: provider.id } },
          body,
        });
      }
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

  async function createAssignment(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const providerId = form.get("provider_id");
    const role = form.get("role");
    const priority = form.get("priority");

    if (
      typeof providerId !== "string" ||
      (role !== "resolver" && role !== "reviewer") ||
      typeof priority !== "string"
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    await mutate("create-assignment", () =>
      apiClient.POST("/api/v1/ai-usage-role-assignments", {
        body: {
          assignment: { provider_id: providerId, role, priority: Number(priority) },
        },
      }),
    );
  }

  async function toggleAssignment(assignment: AIUsageRoleAssignment) {
    await mutate(`assignment-${assignment.id}`, () =>
      apiClient.PATCH("/api/v1/ai-usage-role-assignments/{id}", {
        params: { path: { id: assignment.id } },
        body: {
          assignment: {
            expected_revision: assignment.revision,
            enabled: !assignment.enabled,
          },
        },
      }),
    );
  }

  return (
    <section id="ai" className="scroll-mt-6 space-y-6">
      <div>
        <h2 className="text-xl font-semibold">{t("setup.aiTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("setup.aiDescription")}</p>
      </div>

      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle>{t("setup.addAI")}</CardTitle>
            <CardDescription>{t("setup.secretDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={createProvider}>
              <div className="space-y-2">
                <Label htmlFor="provider-name">{t("setup.name")}</Label>
                <Input id="provider-name" name="name" required maxLength={120} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="provider-service">{t("setup.service")}</Label>
                <select id="provider-service" name="service" className={selectClassName()}>
                  <option value="openai">OpenAI</option>
                  <option value="anthropic">Anthropic</option>
                  <option value="ollama">Ollama</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="provider-model">{t("setup.model")}</Label>
                <Input id="provider-model" name="model" required maxLength={200} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="provider-endpoint">{t("setup.endpoint")}</Label>
                <Input id="provider-endpoint" name="endpoint" type="url" placeholder="https://…" />
              </div>
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="provider-api-key">{t("setup.apiKey")}</Label>
                <Input id="provider-api-key" name="api_key" type="password" autoComplete="off" />
              </div>
              <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending !== null}>
                {pending === "create-provider" ? <Spinner /> : <Plus />}
                {t("setup.addConnection")}
              </Button>
            </form>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 xl:grid-cols-2">
        {aiProviders.map((provider) => {
          const currentCheck = provider.check.checked_revision === provider.revision;
          const passed = currentCheck && provider.check.status === "passed";
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <CardTitle>{provider.name}</CardTitle>
                  <Badge variant={provider.enabled ? "default" : "secondary"}>
                    {t(provider.enabled ? "setup.enabled" : "setup.disabled")}
                  </Badge>
                </div>
                <CardDescription>
                  {configurationValue(provider, "provider")} ·{" "}
                  {configurationValue(provider, "model")}
                </CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="flex items-start gap-2 text-sm">
                  {passed ? (
                    <CheckCircle2 className="mt-0.5 size-4 text-success" />
                  ) : (
                    <CircleAlert className="mt-0.5 size-4 text-warning" />
                  )}
                  <div>
                    <p>{t(passed ? "setup.checkPassed" : "setup.checkRequired")}</p>
                    {provider.check.message && (
                      <details className="text-muted-foreground">
                        <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                        <p>{provider.check.message}</p>
                      </details>
                    )}
                  </div>
                </div>
                {canManage && (
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={pending !== null}
                      onClick={() => void providerAction(provider, "check")}
                    >
                      {pending === `${provider.id}-check` && <Spinner />}
                      {t("setup.check")}
                    </Button>
                    {!provider.enabled && (
                      <Button
                        size="sm"
                        disabled={!passed || pending !== null}
                        onClick={() => void providerAction(provider, "enable")}
                      >
                        {pending === `${provider.id}-enable` && <Spinner />}
                        {t("setup.enable")}
                      </Button>
                    )}
                    {provider.enabled && (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending !== null}
                        onClick={() => void providerAction(provider, "disable")}
                      >
                        {pending === `${provider.id}-disable` && <Spinner />}
                        {t("setup.disable")}
                      </Button>
                    )}
                  </div>
                )}
              </CardContent>
            </Card>
          );
        })}
      </div>

      <Card id="ai-roles" className="scroll-mt-6">
        <CardHeader>
          <CardTitle>{t("setup.rolesTitle")}</CardTitle>
          <CardDescription>{t("setup.rolesDescription")}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-5">
          {canManage && aiProviders.length > 0 && (
            <form
              className="grid gap-4 md:grid-cols-[1fr_1fr_8rem_auto]"
              onSubmit={createAssignment}
            >
              <div className="space-y-2">
                <Label htmlFor="role-provider">{t("setup.connection")}</Label>
                <select id="role-provider" name="provider_id" className={selectClassName()}>
                  {aiProviders.map((provider) => (
                    <option key={provider.id} value={provider.id}>
                      {provider.name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="role-name">{t("setup.role")}</Label>
                <select id="role-name" name="role" className={selectClassName()}>
                  <option value="resolver">Resolver</option>
                  <option value="reviewer">Reviewer</option>
                </select>
              </div>
              <div className="space-y-2">
                <Label htmlFor="role-priority">{t("setup.priority")}</Label>
                <Input
                  id="role-priority"
                  name="priority"
                  type="number"
                  min={0}
                  max={10000}
                  defaultValue={100}
                  required
                />
              </div>
              <Button type="submit" className="self-end" disabled={pending !== null}>
                {pending === "create-assignment" ? <Spinner /> : <KeyRound />}
                {t("setup.assign")}
              </Button>
            </form>
          )}

          <div className="divide-y rounded-md border">
            {assignments.map((assignment) => {
              const provider = providers.find((item) => item.id === assignment.provider_id);
              return (
                <div
                  key={assignment.id}
                  className="flex flex-wrap items-center justify-between gap-3 p-3"
                >
                  <div>
                    <p className="font-medium">{provider?.name ?? assignment.provider_id}</p>
                    <p className="text-sm text-muted-foreground">
                      {assignment.role === "resolver" ? "Resolver" : "Reviewer"} ·{" "}
                      {t("setup.priority")} {assignment.priority}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <Badge variant={assignment.enabled ? "default" : "secondary"}>
                      {t(assignment.enabled ? "setup.enabled" : "setup.disabled")}
                    </Badge>
                    {canManage && (
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={pending !== null}
                        onClick={() => void toggleAssignment(assignment)}
                      >
                        {t(assignment.enabled ? "setup.disable" : "setup.enable")}
                      </Button>
                    )}
                  </div>
                </div>
              );
            })}
            {assignments.length === 0 && (
              <p className="p-4 text-sm text-muted-foreground">{t("setup.noRoles")}</p>
            )}
          </div>
        </CardContent>
      </Card>
    </section>
  );
}
