import { useState, type FormEvent } from "react";
import { CheckCircle2, CircleAlert, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient } from "@/api/client";
import type { components } from "@/api/schema";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";

type Provider = components["schemas"]["Provider"];

type Props = {
  providers: Provider[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

const selectClass =
  "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";

export function SignalProviderSection({ providers, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const signalProviders = providers.filter((provider) => provider.kind === "signal");

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    try {
      await action();
      await onRefresh();
      return true;
    } catch {
      onError(t("cases.requestFailed"));
      return false;
    } finally {
      setPending(null);
    }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const name = formValue(form, "name");
    const adapterType = formValue(form, "adapter_type");
    const source = formValue(form, "source");
    const secret = formValue(form, "secret");
    const timezone = formValue(form, "timezone");
    const configuration: Record<string, string> = { source };
    if (adapterType === "zabbix-webhook" && timezone) configuration.timezone = timezone;

    const created = await mutate("create", () =>
      apiClient.POST("/api/v1/providers", {
        body: {
          provider: {
            name,
            kind: "signal",
            adapter_type: adapterType,
            configuration,
            credentials: { secret },
          },
        },
      }),
    );
    if (created) formElement.reset();
  }

  async function providerAction(provider: Provider, action: "check" | "enable" | "disable") {
    const body = { provider: { expected_revision: provider.revision } };
    await mutate(`${provider.id}-${action}`, () => {
      if (action === "check")
        return apiClient.POST("/api/v1/providers/{id}/check", {
          params: { path: { id: provider.id } },
          body,
        });
      if (action === "enable")
        return apiClient.POST("/api/v1/providers/{id}/enable", {
          params: { path: { id: provider.id } },
          body,
        });
      return apiClient.POST("/api/v1/providers/{id}/disable", {
        params: { path: { id: provider.id } },
        body,
      });
    });
  }

  return (
    <section id="signals" className="scroll-mt-6 space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("cases.signalConnections")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("cases.signalDescription")}</p>
      </div>

      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle>{t("cases.addSignal")}</CardTitle>
            <CardDescription>{t("cases.signalSecret")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
              <Field id="signal-name" name="name" label={t("cases.name")} />
              <div className="space-y-2">
                <Label htmlFor="signal-adapter">{t("cases.signalType")}</Label>
                <select id="signal-adapter" name="adapter_type" className={selectClass}>
                  <option value="alertmanager-webhook">Alertmanager Webhook</option>
                  <option value="zabbix-webhook">Zabbix Webhook</option>
                </select>
              </div>
              <Field id="signal-source" name="source" label={t("cases.source")} />
              <Field
                id="signal-timezone"
                name="timezone"
                label={t("cases.timezone")}
                required={false}
                placeholder="Asia/Tokyo"
              />
              <Field
                id="signal-secret"
                name="secret"
                type="password"
                label={t("cases.webhookSecret")}
                minLength={16}
              />
              <Button className="self-end md:w-fit" type="submit" disabled={pending !== null}>
                {pending === "create" ? <Spinner /> : <Plus />}
                {t("cases.addSignal")}
              </Button>
            </form>
          </CardContent>
        </Card>
      )}

      <div className="grid gap-4 xl:grid-cols-2">
        {signalProviders.map((provider) => {
          const passed =
            provider.check.status === "passed" &&
            provider.check.checked_revision === provider.revision;
          const endpointKind =
            provider.adapter_type === "alertmanager-webhook" ? "alertmanager" : "zabbix";
          const endpoint = `${window.location.origin}/api/v1/signals/${endpointKind}/${provider.id}`;
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <CardTitle>{provider.name}</CardTitle>
                  <Badge variant={provider.enabled ? "default" : "secondary"}>
                    {t(provider.enabled ? "cases.enabled" : "cases.disabled")}
                  </Badge>
                </div>
                <CardDescription>{provider.adapter_type}</CardDescription>
              </CardHeader>
              <CardContent className="space-y-4">
                <div className="rounded-md border bg-muted/40 p-3">
                  <p className="text-xs font-medium text-muted-foreground">
                    {t("cases.webhookUrl")}
                  </p>
                  <p className="mt-1 break-all font-mono text-xs">{endpoint}</p>
                </div>
                <div className="flex items-start gap-2 text-sm">
                  {passed ? (
                    <CheckCircle2 className="mt-0.5 size-4 text-success" />
                  ) : (
                    <CircleAlert className="mt-0.5 size-4 text-warning" />
                  )}
                  <span>{t(passed ? "cases.checkPassed" : "cases.checkRequired")}</span>
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
                      {t("cases.check")}
                    </Button>
                    {!provider.enabled ? (
                      <Button
                        size="sm"
                        disabled={!passed || pending !== null}
                        onClick={() => void providerAction(provider, "enable")}
                      >
                        {t("cases.enable")}
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending !== null}
                        onClick={() => void providerAction(provider, "disable")}
                      >
                        {t("cases.disable")}
                      </Button>
                    )}
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

function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

function Field({
  id,
  name,
  label,
  required = true,
  type = "text",
  placeholder,
  minLength,
}: {
  id: string;
  name: string;
  label: string;
  required?: boolean;
  type?: string;
  placeholder?: string;
  minLength?: number;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input
        id={id}
        name={name}
        type={type}
        placeholder={placeholder}
        minLength={minLength}
        required={required}
        autoComplete={type === "password" ? "off" : undefined}
      />
    </div>
  );
}
