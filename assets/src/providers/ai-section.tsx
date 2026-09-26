import { useState, type FormEvent } from "react";
import {
  CheckCircle2,
  ChevronDown,
  CircleAlert,
  Pencil,
  Plus,
  Save,
  ShieldCheck,
  Trash2,
  X,
} from "lucide-react";
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
import { Textarea } from "@/components/ui/textarea";

type AIUsageRoleAssignment = components["schemas"]["AIUsageRoleAssignment"];
type Provider = components["schemas"]["Provider"];
type UsageScope = "all" | "resolver" | "reviewer";
export type AIService = components["schemas"]["AIService"];

type Props = {
  providers: Provider[];
  services: AIService[];
  assignments: AIUsageRoleAssignment[];
  authorityMode: components["schemas"]["AuthoritySetting"]["authority_mode"];
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

function usageScope(assignments: AIUsageRoleAssignment[]): UsageScope | null {
  const resolver = assignments.find((assignment) => assignment.role === "resolver")?.enabled;
  const reviewer = assignments.find((assignment) => assignment.role === "reviewer")?.enabled;
  if (resolver && reviewer) return "all";
  if (resolver) return "resolver";
  if (reviewer) return "reviewer";
  return null;
}

function usageOptions(t: (key: string) => string) {
  return [
    { value: "all", label: t("setup.usageAll") },
    { value: "resolver", label: "Resolver" },
    { value: "reviewer", label: "Reviewer" },
  ];
}

function credentialField(service: AIService) {
  if (service.auth === "none") return null;
  if (service.auth === "service_account_json") return "service_account_json";
  if (service.auth === "oauth_access_token") return "access_token";
  return "api_key";
}

function formConfiguration(form: FormData, service: AIService) {
  const configuration: Record<string, string> = {};
  for (const field of service.configuration_fields) {
    const value = form.get(field);
    if (typeof value !== "string") return null;
    if (value) configuration[field] = value;
  }
  return configuration;
}

export function AIProviderCreateForm({
  service,
  onCreated,
  onError,
}: {
  service: AIService;
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
    const secretField = credentialField(service);
    const secret = secretField ? form.get(secretField) : null;
    const extraConfiguration = formConfiguration(form, service);
    const timeoutMs = form.get("timeout_ms");
    const maxTokens = form.get("max_tokens");
    const reasoningEffort = form.get("reasoning_effort");
    const usageScope = form.get("usage_scope");
    const usagePriority = form.get("usage_priority");

    if (
      typeof name !== "string" ||
      typeof model !== "string" ||
      typeof endpoint !== "string" ||
      (secretField !== null && typeof secret !== "string") ||
      (service.auth !== "none" && service.auth !== "optional_api_key" && !secret) ||
      extraConfiguration === null ||
      typeof timeoutMs !== "string" ||
      typeof maxTokens !== "string" ||
      typeof reasoningEffort !== "string" ||
      (usageScope !== "all" && usageScope !== "resolver" && usageScope !== "reviewer") ||
      typeof usagePriority !== "string"
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    const configuration: Record<string, string | number> = {
      provider: service.id,
      model,
      timeout_ms: Number(timeoutMs),
      max_tokens: Number(maxTokens),
    };
    if (endpoint) configuration.endpoint = endpoint;
    if (reasoningEffort) configuration.reasoning_effort = reasoningEffort;
    Object.assign(configuration, extraConfiguration);

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
            credentials: secretField && secret ? { [secretField]: secret } : {},
            usage_scope: usageScope,
            usage_priority: Number(usagePriority),
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
        <CardDescription>
          {t(
            service.id === "ollama"
              ? "setup.ollamaLocal"
              : service.auth === "none"
                ? "setup.noCredential"
                : "setup.secretDescription",
          )}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4 md:grid-cols-2" onSubmit={createProvider}>
          <AIProviderFields idPrefix="provider" service={service} />
          <div className="space-y-2">
            <Label htmlFor="provider-usage-scope">{t("setup.usageScope")}</Label>
            <FormSelect
              id="provider-usage-scope"
              name="usage_scope"
              defaultValue="all"
              options={usageOptions(t)}
            />
          </div>
          <div className="space-y-2">
            <Label htmlFor="provider-usage-priority">{t("setup.priority")}</Label>
            <Input
              id="provider-usage-priority"
              name="usage_priority"
              type="number"
              min={0}
              max={10000}
              defaultValue={100}
              required
            />
          </div>
          <p className="text-sm text-muted-foreground md:col-span-2">
            {t("setup.priorityDescription")}
          </p>
          <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending}>
            {pending ? <Spinner /> : <Plus />}
            {t("setup.addConnection")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function ProviderSetup({
  providers,
  services,
  assignments,
  authorityMode,
  canManage,
  onRefresh,
  onError,
}: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const [managingProviderId, setManagingProviderId] = useState<string | null>(null);
  const [editingProviderId, setEditingProviderId] = useState<string | null>(null);
  const [deletingProviderId, setDeletingProviderId] = useState<string | null>(null);
  const [draftScope, setDraftScope] = useState<UsageScope | null>(null);
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
    const service = services.find((item) => item.id === configurationValue(provider, "provider"));
    const model = form.get("model");
    const endpoint = form.get("endpoint");
    const secretField = service ? credentialField(service) : null;
    const secret = secretField ? form.get(secretField) : null;
    const extraConfiguration = service ? formConfiguration(form, service) : null;
    const timeoutMs = form.get("timeout_ms");
    const maxTokens = form.get("max_tokens");
    const reasoningEffort = form.get("reasoning_effort");

    if (
      typeof name !== "string" ||
      !service ||
      typeof model !== "string" ||
      typeof endpoint !== "string" ||
      (secretField !== null && typeof secret !== "string") ||
      extraConfiguration === null ||
      typeof timeoutMs !== "string" ||
      typeof maxTokens !== "string" ||
      typeof reasoningEffort !== "string"
    ) {
      setLocalError(t("setup.requestFailed"));
      return;
    }

    const configuration: Record<string, unknown> = {
      ...provider.configuration,
      provider: service.id,
      model,
      timeout_ms: Number(timeoutMs),
      max_tokens: Number(maxTokens),
    };
    if (endpoint) configuration.endpoint = endpoint;
    else delete configuration.endpoint;
    if (reasoningEffort) configuration.reasoning_effort = reasoningEffort;
    else delete configuration.reasoning_effort;
    for (const field of service.configuration_fields) delete configuration[field];
    Object.assign(configuration, extraConfiguration);

    const providerUpdate: components["schemas"]["UpdateProviderRequest"]["provider"] = {
      expected_revision: provider.revision,
      name,
      configuration,
    };
    if (secretField && secret) providerUpdate.credentials = { [secretField]: secret };

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

  async function deleteProvider(provider: Provider) {
    const deleted = await mutate(`${provider.id}-delete`, () =>
      apiClient.DELETE("/api/v1/providers/{id}", {
        params: { path: { id: provider.id } },
        body: { provider: { expected_revision: provider.revision } },
      }),
    );

    if (deleted) {
      setManagingProviderId(null);
      setDeletingProviderId(null);
      setEditingProviderId(null);
      setSuccess(t("setup.connectionDeleted", { name: provider.name }));
    }
  }

  async function saveUsage(provider: Provider, event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const scope = form.get("scope");
    const priority = form.get("priority");

    if (
      (scope !== "all" && scope !== "resolver" && scope !== "reviewer") ||
      typeof priority !== "string"
    ) {
      onError(t("setup.requestFailed"));
      return;
    }

    const assigned = assignments.filter((assignment) => assignment.provider_id === provider.id);
    const saved = await mutate(`${provider.id}-usage`, () =>
      apiClient.PUT("/api/v1/providers/{id}/ai-usage", {
        params: { path: { id: provider.id } },
        body: {
          usage: {
            scope,
            priority: Number(priority),
            expected_resolver_revision:
              assigned.find((item) => item.role === "resolver")?.revision ?? null,
            expected_reviewer_revision:
              assigned.find((item) => item.role === "reviewer")?.revision ?? null,
          },
        },
      }),
    );
    if (saved) {
      setManagingProviderId(null);
      setDraftScope(null);
      setSuccess(t("setup.usageSaved", { name: provider.name }));
    }
  }

  function ordered(role: "resolver" | "reviewer") {
    return assignments
      .filter((assignment) => {
        const provider = aiProviders.find((item) => item.id === assignment.provider_id);
        return (
          assignment.role === role &&
          assignment.enabled &&
          provider?.enabled &&
          provider.check.status === "passed" &&
          provider.check.checked_revision === provider.revision
        );
      })
      .sort(
        (a, b) =>
          a.priority - b.priority ||
          a.inserted_at.localeCompare(b.inserted_at) ||
          a.id.localeCompare(b.id),
      );
  }

  const resolverOrder = ordered("resolver");
  const reviewerOrder = ordered("reviewer");

  function toggleManagement(id: string) {
    setManagingProviderId(managingProviderId === id ? null : id);
    setDraftScope(null);
    setEditingProviderId(null);
    setDeletingProviderId(null);
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

      {authorityMode === "auto" && reviewerOrder.length === 0 && (
        <Alert className="border-warning/60 [&>svg]:text-warning">
          <CircleAlert />
          <AlertDescription>{t("setup.autoReviewerWarning")}</AlertDescription>
        </Alert>
      )}

      <div id="ai-connections" className="grid scroll-mt-6 items-start gap-4 xl:grid-cols-2">
        {aiProviders.map((provider) => {
          const service = services.find(
            (item) => item.id === configurationValue(provider, "provider"),
          );
          const currentCheck = provider.check.checked_revision === provider.revision;
          const passed = currentCheck && provider.check.status === "passed";
          const assigned = assignments.filter(
            (assignment) => assignment.provider_id === provider.id,
          );
          const scope = usageScope(assigned);
          const priority =
            assigned.find((assignment) => assignment.role === "resolver")?.priority ??
            assigned.find((assignment) => assignment.role === "reviewer")?.priority ??
            100;
          const resolverRank = resolverOrder.findIndex((item) => item.provider_id === provider.id);
          const reviewerRank = reviewerOrder.findIndex((item) => item.provider_id === provider.id);
          const expanded = managingProviderId === provider.id;
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <CardTitle className="break-words">{provider.name}</CardTitle>
                  <Badge variant={provider.enabled ? "default" : "secondary"}>
                    {t(provider.enabled ? "setup.enabled" : "setup.disabled")}
                  </Badge>
                </div>
                <CardDescription className="break-all">
                  {service?.name ?? configurationValue(provider, "provider")} ·{" "}
                  {configurationValue(provider, "model")}
                </CardDescription>
                <div className="flex flex-wrap items-center gap-2 pt-1">
                  {(scope === "all" || scope === "resolver") && (
                    <Badge variant="outline">Resolver</Badge>
                  )}
                  {(scope === "all" || scope === "reviewer") && (
                    <Badge variant="outline">Reviewer</Badge>
                  )}
                  {scope ? (
                    <span className="text-xs text-muted-foreground">
                      {t("setup.priority")} {priority}
                    </span>
                  ) : (
                    <span className="text-xs text-muted-foreground">{t("setup.usageUnset")}</span>
                  )}
                </div>
                {(resolverRank >= 0 || reviewerRank >= 0) && (
                  <p className="text-xs text-muted-foreground">
                    {resolverRank >= 0 && <span>Resolver #{resolverRank + 1}</span>}
                    {resolverRank >= 0 && reviewerRank >= 0 && <span> · </span>}
                    {reviewerRank >= 0 && <span>Reviewer #{reviewerRank + 1}</span>}
                  </p>
                )}
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
                    {!provider.enabled ? (
                      <Button
                        size="sm"
                        disabled={!passed || pending !== null}
                        onClick={() => void providerAction(provider, "enable")}
                      >
                        {pending === `${provider.id}-enable` && <Spinner />}
                        {t("setup.enable")}
                      </Button>
                    ) : (
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
                    <Button
                      size="sm"
                      variant="outline"
                      aria-expanded={expanded}
                      aria-controls={expanded ? `ai-connection-${provider.id}` : undefined}
                      aria-label={`${provider.name}: ${t(expanded ? "setup.hideConnectionDetails" : "setup.showConnectionDetails")}`}
                      disabled={pending !== null}
                      onClick={() => toggleManagement(provider.id)}
                    >
                      {t(expanded ? "setup.hideConnectionDetails" : "setup.showConnectionDetails")}
                      <ChevronDown className={expanded ? "rotate-180" : ""} />
                    </Button>
                  </div>
                )}
                {expanded && canManage && (
                  <div id={`ai-connection-${provider.id}`} className="space-y-4 border-t pt-4">
                    <div className="space-y-3">
                      <form
                        key={`${provider.id}-${assigned.map((item) => `${item.role}:${item.revision}`).join("-")}`}
                        className="grid gap-3 sm:grid-cols-[1fr_8rem_auto]"
                        onSubmit={(event) => void saveUsage(provider, event)}
                      >
                        <div className="space-y-2">
                          <Label htmlFor={`${provider.id}-scope`}>{t("setup.usageScope")}</Label>
                          <FormSelect
                            id={`${provider.id}-scope`}
                            name="scope"
                            value={draftScope ?? scope ?? "all"}
                            onValueChange={(value) => {
                              if (value === "all" || value === "resolver" || value === "reviewer")
                                setDraftScope(value);
                            }}
                            options={usageOptions(t)}
                          />
                        </div>
                        <div className="space-y-2">
                          <Label htmlFor={`${provider.id}-priority`}>{t("setup.priority")}</Label>
                          <Input
                            id={`${provider.id}-priority`}
                            name="priority"
                            type="number"
                            min={0}
                            max={10000}
                            defaultValue={priority}
                            required
                          />
                        </div>
                        <Button
                          type="submit"
                          size="sm"
                          className="self-end"
                          disabled={pending !== null}
                        >
                          {pending === `${provider.id}-usage` ? <Spinner /> : <Save />}
                          {t("setup.saveUsage")}
                        </Button>
                      </form>
                      {authorityMode === "auto" &&
                        draftScope === "resolver" &&
                        reviewerOrder.length === 1 &&
                        reviewerOrder[0].provider_id === provider.id && (
                          <Alert className="border-warning/60 [&>svg]:text-warning">
                            <CircleAlert />
                            <AlertDescription>
                              {t("setup.autoReviewerChangeWarning")}
                            </AlertDescription>
                          </Alert>
                        )}
                      <p className="text-xs text-muted-foreground">{t("setup.priorityHint")}</p>
                    </div>
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
                        className="text-destructive"
                        disabled={pending !== null}
                        onClick={() =>
                          setDeletingProviderId(
                            deletingProviderId === provider.id ? null : provider.id,
                          )
                        }
                      >
                        <Trash2 />
                        {t("setup.deleteConnection")}
                      </Button>
                    </div>

                    {deletingProviderId === provider.id && (
                      <Alert variant="destructive">
                        <AlertDescription className="space-y-3">
                          <p>{t("setup.deleteConnectionConfirm", { name: provider.name })}</p>
                          <div className="flex flex-wrap gap-2">
                            <Button
                              size="sm"
                              variant="destructive"
                              disabled={pending !== null}
                              onClick={() => void deleteProvider(provider)}
                            >
                              {pending === `${provider.id}-delete` ? <Spinner /> : <Trash2 />}
                              {t("setup.confirmDeleteConnection")}
                            </Button>
                            <Button
                              size="sm"
                              variant="outline"
                              disabled={pending !== null}
                              onClick={() => setDeletingProviderId(null)}
                            >
                              {t("common.cancel")}
                            </Button>
                          </div>
                        </AlertDescription>
                      </Alert>
                    )}

                    {editingProviderId === provider.id && service && (
                      <form
                        className="grid gap-4 rounded-md border bg-muted/20 p-4 md:grid-cols-2"
                        onSubmit={(event) => void updateProvider(provider, event)}
                      >
                        <AIProviderFields
                          idPrefix={`provider-${provider.id}`}
                          provider={provider}
                          service={service}
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
                  </div>
                )}
              </CardContent>
            </Card>
          );
        })}
        {aiProviders.length === 0 && (
          <p className="rounded-lg border p-6 text-sm text-muted-foreground">
            {t("setup.noAIConnections")}
          </p>
        )}
      </div>

      <Card id="ai-authority" className="scroll-mt-6">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <ShieldCheck className="size-4 text-primary" />
            {t("setup.manageAuthority")}
          </CardTitle>
          <CardDescription>{t("setup.authorityEntryDescription")}</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
            <span>{t("setup.currentAuthorityMode")}</span>
            <Badge variant="outline">{t(`setup.modes.${authorityMode}.name`)}</Badge>
          </div>
          <Button asChild variant="outline" className="w-full sm:w-auto">
            <Link to="/ai/authority">{t("setup.openAuthority")}</Link>
          </Button>
        </CardContent>
      </Card>
    </section>
  );
}

function AIProviderFields({
  idPrefix,
  provider,
  editing = false,
  service,
}: {
  idPrefix: string;
  provider?: Provider;
  editing?: boolean;
  service: AIService;
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
        <Label htmlFor={`${idPrefix}-endpoint`}>
          {t(service.endpoint_required ? "setup.endpointRequired" : "setup.endpoint")}
        </Label>
        <Input
          id={`${idPrefix}-endpoint`}
          name="endpoint"
          type="url"
          required={service.endpoint_required}
          defaultValue={value("endpoint")}
          placeholder="https://…"
        />
      </div>
      {service.configuration_fields.map((field) => (
        <div className="space-y-2" key={field}>
          <Label htmlFor={`${idPrefix}-${field}`}>{t(`setup.aiFields.${field}`)}</Label>
          <Input
            id={`${idPrefix}-${field}`}
            name={field}
            defaultValue={value(field)}
            required={
              field === "project_id" ||
              field === "chatgpt_account_id" ||
              (field === "region" && service.id === "amazon_bedrock")
            }
          />
        </div>
      ))}
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
      <details className="space-y-2 md:col-span-2">
        <summary className="cursor-pointer text-sm font-medium">{t("setup.advancedAI")}</summary>
        <div className="mt-3 space-y-2">
          <Label htmlFor={`${idPrefix}-reasoning-effort`}>{t("setup.reasoningEffort")}</Label>
          <select
            id={`${idPrefix}-reasoning-effort`}
            name="reasoning_effort"
            defaultValue={value("reasoning_effort")}
            className="border-input bg-background h-9 w-full rounded-md border px-3 text-sm"
          >
            <option value="">{t("setup.reasoningEffortDefault")}</option>
            <option value="none">{t("setup.reasoningNone")}</option>
            <option value="low">{t("setup.reasoningLow")}</option>
            <option value="medium">{t("setup.reasoningMedium")}</option>
            <option value="high">{t("setup.reasoningHigh")}</option>
            <option value="max">{t("setup.reasoningMax")}</option>
          </select>
          <p className="text-xs text-muted-foreground">{t("setup.reasoningEffortDescription")}</p>
        </div>
      </details>
      {credentialField(service) !== null && (
        <div className="space-y-2 md:col-span-2">
          <Label htmlFor={`${idPrefix}-credential`}>
            {t(`setup.aiFields.${credentialField(service)}`)}
          </Label>
          {service.auth === "service_account_json" ? (
            <Textarea
              id={`${idPrefix}-credential`}
              name={credentialField(service)!}
              autoComplete="off"
              required={!editing}
            />
          ) : (
            <Input
              id={`${idPrefix}-credential`}
              name={credentialField(service)!}
              type="password"
              autoComplete="off"
              required={!editing && service.auth !== "optional_api_key"}
            />
          )}
          {editing && (
            <p className="text-xs text-muted-foreground">{t("setup.editConnectionDescription")}</p>
          )}
        </div>
      )}
    </>
  );
}
