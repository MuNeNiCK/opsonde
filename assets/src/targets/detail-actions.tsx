import { useState, type FormEvent, type ReactNode } from "react";
import { Cable, Fingerprint, Link2, Plus, ShieldBan, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { targetAdapter } from "@/targets/adapters";
import type { Provider, Target } from "@/targets/data";

type Action = "identity" | "access" | "relationship" | "policy";

export function TargetDetailActions({
  target,
  targets,
  providers,
  onComplete,
  onError,
}: {
  target: Target;
  targets: Target[];
  providers: Provider[];
  onComplete: (message: string) => Promise<void>;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [action, setAction] = useState<Action | null>(null);
  const [pending, setPending] = useState(false);
  const enabledProviders = providers.filter(
    (provider) =>
      provider.kind === "target" &&
      provider.enabled &&
      provider.check.status === "passed" &&
      provider.check.checked_revision === provider.revision,
  );

  async function submit(
    event: FormEvent<HTMLFormElement>,
    request: (form: FormData) => Promise<unknown>,
  ) {
    event.preventDefault();
    setPending(true);
    onError("");
    try {
      await request(new FormData(event.currentTarget));
      setAction(null);
      await onComplete(t("targets.changeSaved"));
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  async function createAccessMethod(form: FormData) {
    const provider = enabledProviders.find((item) => item.id === value(form, "provider_id"));
    const adapter = provider && targetAdapter(provider.adapter_type);
    if (!provider || !adapter) throw new Error(t("targets.connectionRequired"));
    const response = apiData(
      await apiClient.POST("/api/v1/providers/{id}/target-capabilities", {
        params: { path: { id: provider.id } },
        body: { provider: { expected_revision: provider.revision } },
      }),
    );
    const capabilities = Array.from(
      new Set(
        [...response.data.observations, ...response.data.effects].map(
          (operation) => operation.capability,
        ),
      ),
    );
    return apiClient.POST("/api/v1/access-methods", {
      body: {
        access_method: {
          target_id: target.id,
          provider_id: provider.id,
          name: value(form, "name"),
          platform: adapter.platform,
          method: adapter.method,
          endpoint: value(form, "endpoint"),
          provider_revision: provider.revision,
          priority: Number(value(form, "priority")),
          capabilities,
        },
      },
    });
  }

  if (!action) {
    return (
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="outline" onClick={() => setAction("identity")}>
          <Fingerprint />
          {t("targets.addIdentity")}
        </Button>
        <Button size="sm" variant="outline" onClick={() => setAction("access")}>
          <Cable />
          {t("targets.addAccessMethod")}
        </Button>
        <Button size="sm" variant="outline" onClick={() => setAction("relationship")}>
          <Link2 />
          {t("targets.addRelationship")}
        </Button>
        <Button size="sm" variant="outline" onClick={() => setAction("policy")}>
          <ShieldBan />
          {t("targets.addPolicy")}
        </Button>
      </div>
    );
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex items-start justify-between gap-3">
          <div>
            <CardTitle>{t("targets.action." + action)}</CardTitle>
            <CardDescription>{target.name}</CardDescription>
          </div>
          <Button
            size="icon-sm"
            variant="ghost"
            onClick={() => setAction(null)}
            aria-label={t("common.cancel")}
          >
            <X />
          </Button>
        </div>
      </CardHeader>
      <CardContent>
        {action === "identity" && (
          <form
            className="grid gap-4 md:grid-cols-2"
            onSubmit={(event) =>
              void submit(event, (form) =>
                apiClient.POST("/api/v1/external-identities", {
                  body: {
                    external_identity: {
                      target_id: target.id,
                      source: value(form, "source"),
                      kind: value(form, "kind"),
                      value: value(form, "value"),
                    },
                  },
                }),
              )
            }
          >
            <Field label={t("targets.source")} name="source" placeholder="zabbix" required />
            <Field label={t("targets.identityKind")} name="kind" placeholder="hostid" required />
            <Field label={t("targets.identityValue")} name="value" required />
            <Submit pending={pending} label={t("targets.addIdentity")} />
          </form>
        )}
        {action === "access" && (
          <form
            className="grid gap-4 md:grid-cols-2"
            onSubmit={(event) => void submit(event, createAccessMethod)}
          >
            <Select label={t("targets.connection")} name="provider_id" required>
              <option value="">{t("targets.chooseConnection")}</option>
              {enabledProviders.map((provider) => (
                <option key={provider.id} value={provider.id}>
                  {provider.name} · {provider.adapter_type}
                </option>
              ))}
            </Select>
            <Field label={t("targets.name")} name="name" required />
            <Field
              label={t("targets.endpoint")}
              name="endpoint"
              placeholder="ssh://host:22"
              required
            />
            <Field
              label={t("targets.priority")}
              name="priority"
              type="number"
              min={0}
              max={10000}
              defaultValue={100}
              required
            />
            <Submit
              pending={pending}
              label={t("targets.addAccessMethod")}
              disabled={enabledProviders.length === 0}
            />
          </form>
        )}
        {action === "relationship" && (
          <form
            className="grid gap-4 md:grid-cols-2"
            onSubmit={(event) =>
              void submit(event, (form) =>
                apiClient.POST("/api/v1/target-relationships", {
                  body: {
                    relationship: {
                      source_target_id: target.id,
                      destination_target_id: value(form, "destination_target_id"),
                      kind: value(form, "kind"),
                      facts: {},
                      valid_until: null,
                    },
                  },
                }),
              )
            }
          >
            <Select label={t("targets.destinationTarget")} name="destination_target_id" required>
              <option value="">{t("targets.chooseTarget")}</option>
              {targets
                .filter((item) => item.active && item.id !== target.id)
                .map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name}
                  </option>
                ))}
            </Select>
            <Field
              label={t("targets.relationshipKind")}
              name="kind"
              placeholder="hosted_by"
              required
            />
            <Submit
              pending={pending}
              label={t("targets.addRelationship")}
              disabled={targets.filter((item) => item.active && item.id !== target.id).length === 0}
            />
          </form>
        )}
        {action === "policy" && (
          <form
            className="grid gap-4 md:grid-cols-2"
            onSubmit={(event) =>
              void submit(event, (form) => {
                const requestKind = value(form, "request_kinds");
                const requestKinds: Array<"observation" | "effect"> =
                  requestKind === "both"
                    ? ["observation", "effect"]
                    : [requestKind === "effect" ? "effect" : "observation"];
                return apiClient.POST("/api/v1/target-policies", {
                  body: {
                    target_policy: {
                      target_id: target.id,
                      name: value(form, "name"),
                      request_kinds: requestKinds,
                      capabilities: values(value(form, "capabilities")),
                      operations: values(value(form, "operations")),
                      selector_match: {
                        [value(form, "selector")]: { prefix: value(form, "prefix") },
                      },
                      parameter_match: {},
                      reason: value(form, "reason"),
                    },
                  },
                });
              })
            }
          >
            <Field label={t("targets.name")} name="name" required />
            <Select label={t("targets.requestKinds")} name="request_kinds">
              <option value="both">{t("targets.observationAndEffect")}</option>
              <option value="observation">observation</option>
              <option value="effect">effect</option>
            </Select>
            <Field
              label={t("targets.capabilitiesOptional")}
              name="capabilities"
              placeholder="effect.interface"
            />
            <Field
              label={t("targets.operationsOptional")}
              name="operations"
              placeholder="ios_xe.interface.admin_state.set"
            />
            <Field label={t("targets.selectorField")} name="selector" placeholder="path" required />
            <Field
              label={t("targets.forbiddenPrefix")}
              name="prefix"
              placeholder="/usr/credential"
              required
            />
            <Field label={t("targets.reason")} name="reason" required />
            <Submit pending={pending} label={t("targets.addPolicy")} />
          </form>
        )}
      </CardContent>
    </Card>
  );
}

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

function values(input: string) {
  return input
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function Field({
  label,
  name,
  ...props
}: React.ComponentProps<typeof Input> & { label: string; name: string }) {
  const id = "target-action-" + name;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} {...props} />
    </div>
  );
}

function Select({
  label,
  name,
  children,
  ...props
}: React.SelectHTMLAttributes<HTMLSelectElement> & {
  label: string;
  name: string;
  children: ReactNode;
}) {
  const id = "target-action-" + name;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <select
        id={id}
        name={name}
        className="flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35"
        {...props}
      >
        {children}
      </select>
    </div>
  );
}

function Submit({
  pending,
  label,
  disabled = false,
}: {
  pending: boolean;
  label: string;
  disabled?: boolean;
}) {
  return (
    <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending || disabled}>
      {pending ? <Spinner /> : <Plus />}
      {label}
    </Button>
  );
}
