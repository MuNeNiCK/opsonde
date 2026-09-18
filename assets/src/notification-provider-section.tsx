import { useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { apiRequest } from "@/api";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import type { Provider } from "@/setup-types";

type Props = {
  providers: Provider[];
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

export function NotificationProviderSection({ providers, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [pending, setPending] = useState<string | null>(null);
  const notificationProviders = providers.filter((provider) => provider.kind === "notification");

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    onError("");
    try {
      await action();
      await onRefresh();
      return true;
    } catch (failure) {
      onError(failure instanceof Error ? failure.message : t("reports.requestFailed"));
      return false;
    } finally {
      setPending(null);
    }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const configuration: Record<string, string> = { url: formValue(form, "url") };
    const caCertificate = formValue(form, "ca_certificate");
    if (caCertificate) configuration.ca_certificate = caCertificate;

    const created = await mutate("create", () =>
      apiRequest("/providers", {
        method: "POST",
        body: JSON.stringify({
          provider: {
            name: formValue(form, "name"),
            kind: "notification",
            adapter_type: "http-webhook",
            configuration,
            credentials: { signing_secret: formValue(form, "signing_secret") },
          },
        }),
      }),
    );
    if (created) formElement.reset();
  }

  async function providerAction(provider: Provider, action: "check" | "enable" | "disable") {
    await mutate(`${provider.id}-${action}`, () =>
      apiRequest(`/providers/${provider.id}/${action}`, {
        method: "POST",
        body: JSON.stringify({ provider: { expected_revision: provider.revision } }),
      }),
    );
  }

  return (
    <section className="space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("reports.connections")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("reports.connectionsDescription")}</p>
      </div>
      {canManage && (
        <Card>
          <CardHeader>
            <CardTitle>{t("reports.addConnection")}</CardTitle>
            <CardDescription>{t("reports.secretDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
              <Field id="notification-name" name="name" label={t("reports.name")} />
              <Field
                id="notification-url"
                name="url"
                label={t("reports.webhookUrl")}
                type="url"
                placeholder="https://…"
              />
              <Field
                id="notification-secret"
                name="signing_secret"
                label={t("reports.signingSecret")}
                type="password"
                minLength={32}
              />
              <div className="space-y-2 md:col-span-2">
                <Label htmlFor="notification-ca">{t("reports.caCertificate")}</Label>
                <Textarea id="notification-ca" name="ca_certificate" />
              </div>
              <div className="md:col-span-2">
                <Button type="submit" disabled={pending !== null}>
                  {pending === "create" && <Spinner />}
                  {t("reports.addConnection")}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      )}
      <div className="grid gap-4 xl:grid-cols-2">
        {notificationProviders.map((provider) => {
          const passed =
            provider.check.status === "passed" &&
            provider.check.checked_revision === provider.revision;
          return (
            <Card key={provider.id}>
              <CardHeader>
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <CardTitle>{provider.name}</CardTitle>
                    <CardDescription>
                      {typeof provider.configuration.url === "string"
                        ? provider.configuration.url
                        : ""}
                    </CardDescription>
                  </div>
                  <Badge variant={provider.enabled ? "default" : "outline"}>
                    {t(provider.enabled ? "reports.enabled" : "reports.disabled")}
                  </Badge>
                </div>
              </CardHeader>
              <CardContent className="space-y-3">
                <p className="text-sm text-muted-foreground">
                  {t(passed ? "reports.checkPassed" : "reports.checkRequired")}
                </p>
                {provider.check.status === "failed" && provider.check.message && (
                  <p className="text-sm text-destructive">{provider.check.message}</p>
                )}
                {canManage && (
                  <div className="flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={pending !== null}
                      onClick={() => void providerAction(provider, "check")}
                    >
                      {pending === `${provider.id}-check` && <Spinner />}
                      {t("reports.check")}
                    </Button>
                    {provider.enabled ? (
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending !== null}
                        onClick={() => void providerAction(provider, "disable")}
                      >
                        {t("reports.disable")}
                      </Button>
                    ) : (
                      <Button
                        size="sm"
                        disabled={!passed || pending !== null}
                        onClick={() => void providerAction(provider, "enable")}
                      >
                        {t("reports.enable")}
                      </Button>
                    )}
                  </div>
                )}
              </CardContent>
            </Card>
          );
        })}
        {notificationProviders.length === 0 && (
          <Card className="xl:col-span-2">
            <CardContent className="py-8 text-center text-sm text-muted-foreground">
              {t("reports.noConnections")}
            </CardContent>
          </Card>
        )}
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
  type = "text",
  placeholder,
  minLength,
}: {
  id: string;
  name: string;
  label: string;
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
        required
        autoComplete={type === "password" ? "off" : undefined}
      />
    </div>
  );
}
