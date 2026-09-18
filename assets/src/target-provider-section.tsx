import { useState, type FormEvent } from "react";
import { CheckCircle2, CircleAlert, Network, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiRequest, type DataResponse } from "@/api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import type { Provider } from "@/setup-types";
import { targetAdapter, targetAdapterOptions } from "@/target-adapters";

type Props = {
  providers: Provider[];
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

function firstFingerprintEndpoint(provider: Provider) {
  const fingerprints = provider.configuration.host_key_fingerprints;
  if (!fingerprints || typeof fingerprints !== "object" || Array.isArray(fingerprints)) return "";
  return Object.keys(fingerprints)[0] ?? "";
}

export function TargetProviderSection({ providers, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [adapterType, setAdapterType] = useState("linux-ssh");
  const [authMethod, setAuthMethod] = useState("password");
  const [pending, setPending] = useState<string | null>(null);
  const [checkInputs, setCheckInputs] = useState<Record<string, string>>({});
  const targetProviders = providers.filter((provider) => provider.kind === "target");
  const inventoryProviders = providers.filter((provider) => provider.kind === "inventory");
  const selectedAdapter = targetAdapter(adapterType)!;

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    try {
      await action();
      await onRefresh();
      return true;
    } catch (error) {
      onError(error instanceof Error ? error.message : t("targets.requestFailed"));
      return false;
    } finally {
      setPending(null);
    }
  }

  async function createTargetProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const endpoint = value(form, "endpoint");
    let configuration: Record<string, unknown>;
    let credentials: Record<string, unknown>;

    if (selectedAdapter.family === "ssh") {
      configuration = {
        host_key_fingerprints: { [endpoint]: value(form, "fingerprint") },
      };
      if (adapterType === "linux-ssh") configuration.privilege = value(form, "privilege");
      credentials = { username: value(form, "username"), auth_method: authMethod };
      credentials[authMethod === "password" ? "password" : "private_key"] = value(
        form,
        authMethod === "password" ? "password" : "private_key",
      );
    } else if (selectedAdapter.family === "restconf") {
      configuration = { ca_certificate: value(form, "ca_certificate") };
      credentials = { username: value(form, "username"), password: value(form, "password") };
    } else {
      configuration = { namespace: value(form, "namespace") };
      credentials = { kubeconfig: value(form, "kubeconfig") };
    }

    const created = await mutate("create-target-provider", async () => {
      const response = await apiRequest<DataResponse<Provider>>("/providers", {
        method: "POST",
        body: JSON.stringify({
          provider: {
            name: value(form, "name"),
            kind: "target",
            adapter_type: adapterType,
            configuration,
            credentials,
          },
        }),
      });
      setCheckInputs((current) => ({ ...current, [response.data.id]: endpoint }));
      await apiRequest(`/providers/${response.data.id}/check`, {
        method: "POST",
        body: JSON.stringify({
          provider: {
            expected_revision: response.data.revision,
            check_input: { endpoint },
          },
        }),
      });
    });

    if (created) formElement.reset();
  }

  async function createInventoryProvider(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const resource = value(form, "resource");
    const created = await mutate("create-inventory-provider", async () => {
      const response = await apiRequest<DataResponse<Provider>>("/providers", {
        method: "POST",
        body: JSON.stringify({
          provider: {
            name: value(form, "name"),
            kind: "inventory",
            adapter_type: "netbox-api",
            configuration: {
              base_url: value(form, "base_url"),
              ca_certificate: value(form, "ca_certificate"),
            },
            credentials: { token: value(form, "token") },
          },
        }),
      });
      await apiRequest(`/providers/${response.data.id}/check`, {
        method: "POST",
        body: JSON.stringify({
          provider: {
            expected_revision: response.data.revision,
            check_input: { resource, filters: {}, page_size: 50 },
          },
        }),
      });
    });
    if (created) formElement.reset();
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

    await mutate(`${provider.id}-${action}`, () =>
      apiRequest(`/providers/${provider.id}/${action}`, {
        method: "POST",
        body: JSON.stringify({
          provider: {
            expected_revision: provider.revision,
            ...(action === "check" ? { check_input: checkInput } : {}),
          },
        }),
      }),
    );
  }

  return (
    <section className="space-y-6">
      <div>
        <h2 className="text-xl font-semibold">{t("targets.connectionsTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("targets.connectionsDescription")}</p>
      </div>

      {canManage && (
        <div className="grid gap-4 xl:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>{t("targets.addConnection")}</CardTitle>
              <CardDescription>{t("targets.secretDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="grid gap-4 md:grid-cols-2" onSubmit={createTargetProvider}>
                <Field label={t("targets.name")} name="name" required />
                <div className="space-y-2">
                  <Label htmlFor="target-adapter">{t("targets.connectionType")}</Label>
                  <select
                    id="target-adapter"
                    name="adapter_type"
                    className={selectClassName}
                    value={adapterType}
                    onChange={(event) => setAdapterType(event.target.value)}
                  >
                    {targetAdapterOptions.map((option) => (
                      <option key={option.type} value={option.type}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                </div>
                <Field
                  label={t("targets.endpoint")}
                  name="endpoint"
                  placeholder="ssh://host:22"
                  required
                />
                {selectedAdapter.family === "ssh" && (
                  <>
                    <Field
                      label={t("targets.fingerprint")}
                      name="fingerprint"
                      placeholder="SHA256:…"
                      required
                    />
                    <Field
                      label={t("targets.username")}
                      name="username"
                      autoComplete="username"
                      required
                    />
                    <div className="space-y-2">
                      <Label htmlFor="target-auth-method">{t("targets.authentication")}</Label>
                      <select
                        id="target-auth-method"
                        name="auth_method"
                        className={selectClassName}
                        value={authMethod}
                        onChange={(event) => setAuthMethod(event.target.value)}
                      >
                        <option value="password">{t("targets.password")}</option>
                        <option value="public_key">{t("targets.privateKey")}</option>
                      </select>
                    </div>
                    {authMethod === "password" ? (
                      <Field
                        label={t("targets.password")}
                        name="password"
                        type="password"
                        autoComplete="off"
                        required
                      />
                    ) : (
                      <Area label={t("targets.privateKey")} name="private_key" required />
                    )}
                    {adapterType === "linux-ssh" && (
                      <div className="space-y-2">
                        <Label htmlFor="target-privilege">{t("targets.privilege")}</Label>
                        <select id="target-privilege" name="privilege" className={selectClassName}>
                          <option value="none">none</option>
                          <option value="sudo">sudo</option>
                        </select>
                      </div>
                    )}
                  </>
                )}
                {selectedAdapter.family === "restconf" && (
                  <>
                    <Field
                      label={t("targets.username")}
                      name="username"
                      autoComplete="username"
                      required
                    />
                    <Field
                      label={t("targets.password")}
                      name="password"
                      type="password"
                      autoComplete="off"
                      required
                    />
                    <Area label={t("targets.caCertificate")} name="ca_certificate" required />
                  </>
                )}
                {selectedAdapter.family === "kubernetes" && (
                  <>
                    <Field
                      label={t("targets.namespace")}
                      name="namespace"
                      defaultValue="default"
                      required
                    />
                    <Area label={t("targets.kubeconfig")} name="kubeconfig" required />
                  </>
                )}
                <Button
                  type="submit"
                  className="md:col-span-2 md:w-fit"
                  disabled={pending !== null}
                >
                  {pending === "create-target-provider" ? <Spinner /> : <Plus />}
                  {t("targets.addAndCheck")}
                </Button>
              </form>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle>{t("targets.addNetBox")}</CardTitle>
              <CardDescription>{t("targets.netBoxDescription")}</CardDescription>
            </CardHeader>
            <CardContent>
              <form className="grid gap-4 md:grid-cols-2" onSubmit={createInventoryProvider}>
                <Field label={t("targets.name")} name="name" required />
                <Field label={t("targets.baseUrl")} name="base_url" type="url" required />
                <Field
                  label={t("targets.token")}
                  name="token"
                  type="password"
                  autoComplete="off"
                  required
                />
                <div className="space-y-2">
                  <Label htmlFor="netbox-resource">{t("targets.resource")}</Label>
                  <select id="netbox-resource" name="resource" className={selectClassName}>
                    <option value="devices">devices</option>
                    <option value="virtual_machines">virtual_machines</option>
                  </select>
                </div>
                <div className="md:col-span-2">
                  <Area label={t("targets.caCertificate")} name="ca_certificate" required />
                </div>
                <Button
                  type="submit"
                  className="md:col-span-2 md:w-fit"
                  disabled={pending !== null}
                >
                  {pending === "create-inventory-provider" ? <Spinner /> : <Plus />}
                  {t("targets.addAndCheck")}
                </Button>
              </form>
            </CardContent>
          </Card>
        </div>
      )}

      <div className="grid gap-4 xl:grid-cols-2">
        {[...targetProviders, ...inventoryProviders].map((provider) => {
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
                  <span>
                    {provider.check.message ||
                      t(passed ? "targets.checkPassed" : "targets.checkRequired")}
                  </span>
                </div>
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

function Field({
  label,
  name,
  ...props
}: React.ComponentProps<typeof Input> & { label: string; name: string }) {
  const id = `target-${name}`;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} {...props} />
    </div>
  );
}

function Area({ label, name, required }: { label: string; name: string; required?: boolean }) {
  const id = `target-${name}`;
  return (
    <div className="space-y-2 md:col-span-2">
      <Label htmlFor={id}>{label}</Label>
      <Textarea id={id} name={name} required={required} rows={5} />
    </div>
  );
}
