import { useState, type FormEvent } from "react";
import { CheckCircle2, CircleAlert, KeyRound, Pencil, Plus, Save, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link } from "react-router-dom";
import { apiClient } from "@/api/client";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
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

function configurationValue(provider: Provider, key: string) {
  const value = provider.configuration[key];
  return typeof value === "string" ? value : "";
}

function configurationNumber(provider: Provider, key: string, fallback: number) {
  const value = provider.configuration[key];
  return typeof value === "number" ? value : fallback;
}

export function AIProviderCreateForm({
  service,
  onCreated,
  onError,
}: {
  service: "openai" | "anthropic" | "ollama";
  onCreated: () => void;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [pending, setPending] = useState(false);

  async function createProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const name = form.get("name");
    const model = form.get("model");
    const endpoint = form.get("endpoint");
    const apiKey = form.get("api_key");
    const timeoutMs = form.get("timeout_ms");
    const maxTokens = form.get("max_tokens");

    if (
      typeof name !== "string" ||
      typeof model !== "string" ||
      typeof endpoint !== "string" ||
      typeof apiKey !== "string" ||
      typeof timeoutMs !== "string" ||
      typeof maxTokens !== "string"
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    const configuration: Record<string, string | number> = {
      provider: service,
      model,
      timeout_ms: Number(timeoutMs),
      max_tokens: Number(maxTokens),
    };
    if (endpoint) configuration.endpoint = endpoint;

    setPending(true);
    onError("");
    try {
      await apiClient.POST("/api/v1/providers", {
        body: {
          provider: {
            name,
            kind: "ai",
            adapter_type: "req-llm",
            configuration,
            credentials: apiKey ? { api_key: apiKey } : {},
          },
        },
      });
      onCreated();
    } catch {
      onError(t("setup.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{t("setup.connection")}</CardTitle>
        <CardDescription>{t("setup.secretDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4 md:grid-cols-2" onSubmit={createProvider}>
          <AIProviderFields idPrefix="provider" fixedService={service} />
          <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending}>
            {pending ? <Spinner /> : <Plus />}
            {t("setup.addConnection")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function ProviderSetup({ providers, assignments, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [editingProviderId, setEditingProviderId] = useState<string | null>(null);
  const [localError, setLocalError] = useState("");
  const [success, setSuccess] = useState("");
  const aiProviders = providers.filter((provider) => provider.kind === "ai");

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    setLocalError("");
    setSuccess("");
    try {
      await action();
      await onRefresh();
      return true;
    } catch {
      const message = t("setup.requestFailed");
      setLocalError(message);
      onError(message);
      return false;
    } finally {
      setPending(null);
    }
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

  async function updateProvider(provider: Provider, event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const name = form.get("name");
    const service = form.get("service");
    const model = form.get("model");
    const endpoint = form.get("endpoint");
    const apiKey = form.get("api_key");
    const timeoutMs = form.get("timeout_ms");
    const maxTokens = form.get("max_tokens");

    if (
      typeof name !== "string" ||
      typeof service !== "string" ||
      typeof model !== "string" ||
      typeof endpoint !== "string" ||
      typeof apiKey !== "string" ||
      typeof timeoutMs !== "string" ||
      typeof maxTokens !== "string"
    ) {
      setLocalError(t("setup.requestFailed"));
      return;
    }

    const configuration: Record<string, unknown> = {
      ...provider.configuration,
      provider: service,
      model,
      timeout_ms: Number(timeoutMs),
      max_tokens: Number(maxTokens),
    };
    if (endpoint) configuration.endpoint = endpoint;
    else delete configuration.endpoint;

    const providerUpdate: components["schemas"]["UpdateProviderRequest"]["provider"] = {
      expected_revision: provider.revision,
      name,
      configuration,
    };
    if (apiKey) providerUpdate.credentials = { api_key: apiKey };

    const updated = await mutate(`${provider.id}-update`, () =>
      apiClient.PATCH("/api/v1/providers/{id}", {
        params: { path: { id: provider.id } },
        body: { provider: providerUpdate },
      }),
    );

    if (updated) {
      setEditingProviderId(null);
      setSuccess(t("setup.connectionUpdated", { name }));
    }
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
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{t("setup.aiTitle")}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{t("setup.aiDescription")}</p>
        </div>
        {canManage && (
          <Button asChild>
            <Link to="/ai/new">
              <Plus />
              {t("setup.addAI")}
            </Link>
          </Button>
        )}
      </div>

      {localError && (
        <Alert variant="destructive">
          <AlertDescription>{localError}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert>
          <CheckCircle2 />
          <AlertDescription>{success}</AlertDescription>
        </Alert>
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
                  <>
                    <div className="flex flex-wrap gap-2">
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending !== null}
                        onClick={() =>
                          setEditingProviderId(
                            editingProviderId === provider.id ? null : provider.id,
                          )
                        }
                      >
                        {editingProviderId === provider.id ? <X /> : <Pencil />}
                        {t(editingProviderId === provider.id ? "common.cancel" : "setup.edit")}
                      </Button>
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

                    {editingProviderId === provider.id && (
                      <form
                        className="grid gap-4 rounded-md border bg-muted/20 p-4 md:grid-cols-2"
                        onSubmit={(event) => void updateProvider(provider, event)}
                      >
                        <AIProviderFields
                          idPrefix={`provider-${provider.id}`}
                          provider={provider}
                          editing
                        />
                        <Button
                          type="submit"
                          className="md:col-span-2 md:w-fit"
                          disabled={pending !== null}
                        >
                          {pending === `${provider.id}-update` ? <Spinner /> : <Save />}
                          {t("setup.saveConnection")}
                        </Button>
                      </form>
                    )}
                  </>
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
                <FormSelect
                  id="role-provider"
                  name="provider_id"
                  defaultValue={aiProviders[0]?.id}
                  options={aiProviders.map((provider) => ({
                    value: provider.id,
                    label: provider.name,
                  }))}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="role-name">{t("setup.role")}</Label>
                <FormSelect
                  id="role-name"
                  name="role"
                  defaultValue="resolver"
                  options={[
                    { value: "resolver", label: "Resolver" },
                    { value: "reviewer", label: "Reviewer" },
                  ]}
                />
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

function AIProviderFields({
  idPrefix,
  provider,
  editing = false,
  fixedService,
}: {
  idPrefix: string;
  provider?: Provider;
  editing?: boolean;
  fixedService?: "openai" | "anthropic" | "ollama";
}) {
  const { t } = useTranslation();
  const value = (key: string) => (provider ? configurationValue(provider, key) : "");
  const number = (key: string, fallback: number) =>
    provider ? configurationNumber(provider, key, fallback) : fallback;

  return (
    <>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-name`}>{t("setup.name")}</Label>
        <Input
          id={`${idPrefix}-name`}
          name="name"
          defaultValue={provider?.name}
          required
          maxLength={120}
        />
      </div>
      {fixedService ? (
        <input type="hidden" name="service" value={fixedService} />
      ) : (
        <div className="space-y-2">
          <Label htmlFor={`${idPrefix}-service`}>{t("setup.service")}</Label>
          <FormSelect
            id={`${idPrefix}-service`}
            name="service"
            defaultValue={value("provider") || "openai"}
            options={[
              { value: "openai", label: "OpenAI" },
              { value: "anthropic", label: "Anthropic" },
              { value: "ollama", label: "Ollama" },
            ]}
          />
        </div>
      )}
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-model`}>{t("setup.model")}</Label>
        <Input
          id={`${idPrefix}-model`}
          name="model"
          defaultValue={value("model")}
          required
          maxLength={200}
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-endpoint`}>{t("setup.endpoint")}</Label>
        <Input
          id={`${idPrefix}-endpoint`}
          name="endpoint"
          type="url"
          defaultValue={value("endpoint")}
          placeholder="https://…"
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-timeout-ms`}>{t("setup.timeoutMs")}</Label>
        <Input
          id={`${idPrefix}-timeout-ms`}
          name="timeout_ms"
          type="number"
          min={100}
          max={600_000}
          defaultValue={number("timeout_ms", 180_000)}
          required
        />
        <p className="text-xs text-muted-foreground">{t("setup.timeoutMsDescription")}</p>
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-max-tokens`}>{t("setup.maxTokens")}</Label>
        <Input
          id={`${idPrefix}-max-tokens`}
          name="max_tokens"
          type="number"
          min={1}
          max={32_768}
          defaultValue={number("max_tokens", 4_096)}
          required
        />
        <p className="text-xs text-muted-foreground">{t("setup.maxTokensDescription")}</p>
      </div>
      <div className="space-y-2 md:col-span-2">
        <Label htmlFor={`${idPrefix}-api-key`}>{t("setup.apiKey")}</Label>
        <Input
          id={`${idPrefix}-api-key`}
          name="api_key"
          type="password"
          autoComplete="off"
          required={!editing && fixedService !== "ollama"}
        />
        {editing && (
          <p className="text-xs text-muted-foreground">{t("setup.editConnectionDescription")}</p>
        )}
      </div>
    </>
  );
}
