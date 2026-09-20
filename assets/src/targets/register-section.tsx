import { useState, type FormEvent } from "react";
import { Boxes, Link2, Plus, ShieldBan } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { targetAdapter } from "@/targets/adapters";

type Provider = components["schemas"]["Provider"];
type AccessMethod = components["schemas"]["AccessMethod"];
type ExternalIdentity = components["schemas"]["ExternalIdentity"];
type ManagementBoundary = components["schemas"]["ManagementBoundary"];
type Target = components["schemas"]["Target"];
type TargetPolicy = components["schemas"]["TargetPolicy"];
type TargetRelationship = components["schemas"]["TargetRelationship"];

type Props = {
  providers: Provider[];
  boundaries: ManagementBoundary[];
  targets: Target[];
  identities: ExternalIdentity[];
  methods: AccessMethod[];
  relationships: TargetRelationship[];
  policies: TargetPolicy[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

const selectClassName =
  "flex h-10 w-full min-w-0 rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";

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

export function TargetRegisterSection({
  providers,
  boundaries,
  targets,
  identities,
  methods,
  relationships,
  policies,
  canManage,
  onRefresh,
  onError,
}: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const activeTargets = targets.filter((target) => target.active);
  const enabledProviders = providers.filter(
    (provider) =>
      provider.kind === "target" &&
      provider.enabled &&
      provider.check.status === "passed" &&
      provider.check.checked_revision === provider.revision,
  );

  async function mutate(key: string, action: () => Promise<unknown>, form?: HTMLFormElement) {
    setPending(key);
    onError("");
    try {
      await action();
      form?.reset();
      await onRefresh();
    } catch (error) {
      onError(error instanceof Error ? error.message : t("targets.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  function submit(key: string, request: (form: FormData) => Promise<unknown>) {
    return (event: FormEvent<HTMLFormElement>) => {
      event.preventDefault();
      const element = event.currentTarget;
      const form = new FormData(element);
      void mutate(key, () => request(form), element);
    };
  }

  async function createAccessMethod(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const element = event.currentTarget;
    const form = new FormData(element);
    const provider = enabledProviders.find((item) => item.id === value(form, "provider_id"));
    const adapter = provider && targetAdapter(provider.adapter_type);
    if (!provider || !adapter) {
      onError(t("targets.connectionRequired"));
      return;
    }

    await mutate(
      "access-method",
      async () => {
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
        await apiClient.POST("/api/v1/access-methods", {
          body: {
            access_method: {
              target_id: value(form, "target_id"),
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
      },
      element,
    );
  }

  return (
    <section className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold">{t("targets.inventoryTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("targets.inventoryDescription")}</p>
      </div>

      {canManage && (
        <div className="grid gap-4 xl:grid-cols-2">
          <FormCard title={t("targets.addBoundary")} description={t("targets.boundaryDescription")}>
            <form
              className="grid gap-4 md:grid-cols-2"
              onSubmit={submit("boundary", (form) =>
                apiClient.POST("/api/v1/management-boundaries", {
                  body: {
                    management_boundary: {
                      name: value(form, "name"),
                      kind: value(form, "kind"),
                      facts: {},
                    },
                  },
                }),
              )}
            >
              <Field id="boundary-name" label={t("targets.name")} name="name" required />
              <Field
                id="boundary-kind"
                label={t("targets.kind")}
                name="kind"
                placeholder="datacenter"
                required
              />
              <Submit pending={pending === "boundary"} label={t("targets.addBoundary")} />
            </form>
          </FormCard>

          <FormCard title={t("targets.addTarget")} description={t("targets.targetDescription")}>
            <form
              className="grid gap-4 md:grid-cols-2"
              onSubmit={submit("target", (form) =>
                apiClient.POST("/api/v1/targets", {
                  body: {
                    target: {
                      name: value(form, "name"),
                      kind: value(form, "kind"),
                      platform: value(form, "platform"),
                      facts: {},
                      management_boundary_id: value(form, "management_boundary_id") || null,
                    },
                  },
                }),
              )}
            >
              <Field id="record-name" label={t("targets.name")} name="name" required />
              <Field
                id="record-kind"
                label={t("targets.kind")}
                name="kind"
                placeholder="host"
                required
              />
              <Field
                id="record-platform"
                label={t("targets.platform")}
                name="platform"
                placeholder="linux"
                required
              />
              <Select
                id="record-boundary"
                label={t("targets.boundary")}
                name="management_boundary_id"
              >
                <option value="">{t("targets.noBoundary")}</option>
                {boundaries
                  .filter((boundary) => boundary.active)
                  .map((boundary) => (
                    <option key={boundary.id} value={boundary.id}>
                      {boundary.name}
                    </option>
                  ))}
              </Select>
              <Submit pending={pending === "target"} label={t("targets.addTarget")} />
            </form>
          </FormCard>

          <FormCard title={t("targets.addIdentity")} description={t("targets.identityDescription")}>
            <form
              className="grid gap-4 md:grid-cols-2"
              onSubmit={submit("identity", (form) =>
                apiClient.POST("/api/v1/external-identities", {
                  body: {
                    external_identity: {
                      target_id: value(form, "target_id"),
                      source: value(form, "source"),
                      kind: value(form, "kind"),
                      value: value(form, "value"),
                    },
                  },
                }),
              )}
            >
              <TargetSelect targets={activeTargets} id="identity-target" />
              <Field
                id="identity-source"
                label={t("targets.source")}
                name="source"
                placeholder="zabbix"
                required
              />
              <Field
                id="identity-kind"
                label={t("targets.identityKind")}
                name="kind"
                placeholder="hostid"
                required
              />
              <Field id="identity-value" label={t("targets.identityValue")} name="value" required />
              <Submit
                pending={pending === "identity"}
                label={t("targets.addIdentity")}
                disabled={activeTargets.length === 0}
              />
            </form>
          </FormCard>

          <FormCard
            title={t("targets.addAccessMethod")}
            description={t("targets.accessMethodDescription")}
          >
            <form className="grid gap-4 md:grid-cols-2" onSubmit={createAccessMethod}>
              <TargetSelect targets={activeTargets} id="method-target" />
              <Select
                id="method-provider"
                label={t("targets.connection")}
                name="provider_id"
                required
              >
                {enabledProviders.map((provider) => (
                  <option key={provider.id} value={provider.id}>
                    {provider.name} · {provider.adapter_type}
                  </option>
                ))}
              </Select>
              <Field id="method-name" label={t("targets.name")} name="name" required />
              <Field
                id="method-endpoint"
                label={t("targets.endpoint")}
                name="endpoint"
                placeholder="ssh://host:22"
                required
              />
              <Field
                id="method-priority"
                label={t("targets.priority")}
                name="priority"
                type="number"
                min={0}
                max={10000}
                defaultValue={100}
                required
              />
              <Submit
                pending={pending === "access-method"}
                label={t("targets.addAccessMethod")}
                disabled={activeTargets.length === 0 || enabledProviders.length === 0}
              />
            </form>
          </FormCard>

          <FormCard
            title={t("targets.addRelationship")}
            description={t("targets.relationshipDescription")}
          >
            <form
              className="grid gap-4 md:grid-cols-2"
              onSubmit={submit("relationship", (form) =>
                apiClient.POST("/api/v1/target-relationships", {
                  body: {
                    relationship: {
                      source_target_id: value(form, "source_target_id"),
                      destination_target_id: value(form, "destination_target_id"),
                      kind: value(form, "kind"),
                      facts: {},
                      valid_until: null,
                    },
                  },
                }),
              )}
            >
              <TargetSelect
                targets={activeTargets}
                id="relationship-source"
                name="source_target_id"
                label={t("targets.sourceTarget")}
              />
              <TargetSelect
                targets={activeTargets}
                id="relationship-destination"
                name="destination_target_id"
                label={t("targets.destinationTarget")}
              />
              <Field
                id="relationship-kind"
                label={t("targets.relationshipKind")}
                name="kind"
                placeholder="hosted_by"
                required
              />
              <Submit
                pending={pending === "relationship"}
                label={t("targets.addRelationship")}
                disabled={activeTargets.length < 2}
              />
            </form>
          </FormCard>

          <FormCard title={t("targets.addPolicy")} description={t("targets.policyDescription")}>
            <form
              className="grid gap-4 md:grid-cols-2"
              onSubmit={submit("policy", (form) => {
                const selector = value(form, "selector");
                const prefix = value(form, "prefix");
                const requestKinds: Array<"observation" | "effect"> =
                  value(form, "request_kinds") === "both"
                    ? ["observation", "effect"]
                    : [value(form, "request_kinds") === "effect" ? "effect" : "observation"];
                return apiClient.POST("/api/v1/target-policies", {
                  body: {
                    target_policy: {
                      target_id: value(form, "target_id"),
                      name: value(form, "name"),
                      request_kinds: requestKinds,
                      capabilities: values(value(form, "capabilities")),
                      operations: values(value(form, "operations")),
                      selector_match: { [selector]: { prefix } },
                      parameter_match: {},
                      reason: value(form, "reason"),
                    },
                  },
                });
              })}
            >
              <TargetSelect targets={activeTargets} id="policy-target" />
              <Field id="policy-name" label={t("targets.name")} name="name" required />
              <Select id="policy-kinds" label={t("targets.requestKinds")} name="request_kinds">
                <option value="both">{t("targets.observationAndEffect")}</option>
                <option value="observation">observation</option>
                <option value="effect">effect</option>
              </Select>
              <Field
                id="policy-capabilities"
                label={t("targets.capabilitiesOptional")}
                name="capabilities"
                placeholder="effect.interface"
              />
              <Field
                id="policy-operations"
                label={t("targets.operationsOptional")}
                name="operations"
                placeholder="ios_xe.interface.admin_state.set"
              />
              <Field
                id="policy-selector"
                label={t("targets.selectorField")}
                name="selector"
                placeholder="path"
                required
              />
              <Field
                id="policy-prefix"
                label={t("targets.forbiddenPrefix")}
                name="prefix"
                placeholder="/usr/credential"
                required
              />
              <Field id="policy-reason" label={t("targets.reason")} name="reason" required />
              <Submit
                pending={pending === "policy"}
                label={t("targets.addPolicy")}
                disabled={activeTargets.length === 0}
              />
            </form>
          </FormCard>
        </div>
      )}

      {activeTargets.length === 0 ? (
        <Card>
          <CardContent className="py-8 text-center text-sm text-muted-foreground">
            {t("targets.noTargets")}
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-4 xl:grid-cols-2">
          {activeTargets.map((target) => {
            const targetIdentities = identities.filter(
              (identity) => identity.target_id === target.id && identity.active,
            );
            const targetMethods = methods.filter(
              (method) => method.target_id === target.id && method.active,
            );
            const targetRelations = relationships.filter(
              (relationship) => relationship.source_target_id === target.id && relationship.active,
            );
            const targetPolicies = policies.filter(
              (policy) => policy.target_id === target.id && policy.enabled,
            );
            return (
              <Card key={target.id}>
                <CardHeader>
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <CardTitle className="flex items-center gap-2">
                      <Boxes className="size-4" />
                      {target.name}
                    </CardTitle>
                    <Badge variant="outline">{target.platform}</Badge>
                  </div>
                  <CardDescription>{target.kind}</CardDescription>
                </CardHeader>
                <CardContent className="space-y-4 text-sm">
                  <RecordList
                    title={t("targets.identities")}
                    empty={t("targets.noIdentities")}
                    items={targetIdentities.map(
                      (identity) => `${identity.source}:${identity.kind} = ${identity.value}`,
                    )}
                  />
                  <RecordList
                    title={t("targets.accessMethods")}
                    empty={t("targets.noAccessMethods")}
                    items={targetMethods.map(
                      (method) =>
                        `${method.name} · ${method.method} · ${method.endpoint} · P${method.priority}`,
                    )}
                  />
                  <RecordList
                    icon={<Link2 />}
                    title={t("targets.relationships")}
                    empty={t("targets.noRelationships")}
                    items={targetRelations.map(
                      (relationship) =>
                        `${relationship.kind} → ${activeTargets.find((candidate) => candidate.id === relationship.destination_target_id)?.name ?? relationship.destination_target_id}`,
                    )}
                  />
                  <RecordList
                    icon={<ShieldBan />}
                    title={t("targets.policies")}
                    empty={t("targets.noPolicies")}
                    items={targetPolicies.map((policy) => `${policy.name}: ${policy.reason}`)}
                  />
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}
    </section>
  );
}

function FormCard({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>{description}</CardDescription>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

function Field({
  id,
  label,
  ...props
}: React.ComponentProps<typeof Input> & { id: string; label: string }) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} {...props} />
    </div>
  );
}

function Select({
  id,
  label,
  children,
  ...props
}: React.SelectHTMLAttributes<HTMLSelectElement> & {
  id: string;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <select id={id} className={selectClassName} {...props}>
        {children}
      </select>
    </div>
  );
}

function TargetSelect({
  targets,
  id,
  name = "target_id",
  label,
}: {
  targets: Target[];
  id: string;
  name?: string;
  label?: string;
}) {
  const { t } = useTranslation();
  return (
    <Select id={id} label={label ?? t("targets.target")} name={name} required>
      {targets.map((target) => (
        <option key={target.id} value={target.id}>
          {target.name}
        </option>
      ))}
    </Select>
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

function RecordList({
  icon,
  title,
  empty,
  items,
}: {
  icon?: React.ReactNode;
  title: string;
  empty: string;
  items: string[];
}) {
  return (
    <div>
      <h3 className="mb-1 flex items-center gap-1.5 font-medium">
        {icon}
        {title}
      </h3>
      {items.length === 0 ? (
        <p className="text-muted-foreground">{empty}</p>
      ) : (
        <ul className="space-y-1 text-muted-foreground">
          {items.map((item) => (
            <li key={item} className="break-all">
              {item}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
