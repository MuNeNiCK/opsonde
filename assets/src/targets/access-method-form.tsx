import { useState, type FormEvent } from "react";
import { Check, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import { FormSelect } from "@/components/form-select";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { TargetConnectionForm } from "@/targets/connection-form";
import type { AccessMethod, Provider, Target, TargetTypeCatalog } from "@/targets/data";

export function AccessMethodForm({
  target,
  providers,
  catalog,
  method,
  onSaved,
  onCancel,
  onError,
}: {
  target: Target;
  providers: Provider[];
  catalog: TargetTypeCatalog;
  method?: AccessMethod;
  onSaved: () => Promise<void>;
  onCancel?: () => void;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [pending, setPending] = useState(false);
  const [providerId, setProviderId] = useState(method?.provider_id ?? "");
  const [endpoint, setEndpoint] = useState(method?.endpoint ?? "");
  const [createdProvider, setCreatedProvider] = useState<Provider | null>(null);
  const [registeredMethod, setRegisteredMethod] = useState<AccessMethod | null>(null);
  const allowedTypes =
    catalog.types.find((item) => item.id === target.type_id)?.access_method_types ?? [];
  const availableProviders = [...providers, ...(createdProvider ? [createdProvider] : [])].filter(
    (provider) =>
      provider.kind === "target" &&
      provider.enabled &&
      provider.access_method_profile &&
      allowedTypes.includes(provider.adapter_type),
  );
  const [creatingConnection, setCreatingConnection] = useState(
    !method && availableProviders.length === 0,
  );
  const provider = availableProviders.find((item) => item.id === providerId);
  const currentEndpoint = endpoint;
  const fieldId = `target-access-${method?.id ?? "new"}`;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!provider?.access_method_profile) return onError(t("targets.connectionRequired"));
    const form = new FormData(event.currentTarget);
    const name = form.get("name");
    setPending(true);
    onError("");
    try {
      const capabilities = method
        ? form.getAll("capability").filter((entry): entry is string => typeof entry === "string")
        : [];
      const values = {
        name: typeof name === "string" ? name : "",
        endpoint: currentEndpoint,
        provider_revision: provider.revision,
        priority: Number(form.get("priority")),
        capabilities,
      };
      const registered = method
        ? apiData(
            await apiClient.PATCH("/api/v1/access-methods/{id}", {
              params: { path: { id: method.id } },
              body: { access_method: { ...values, expected_revision: method.revision } },
            }),
          ).data
        : apiData(
            await apiClient.POST("/api/v1/access-methods", {
              body: {
                access_method: {
                  ...values,
                  target_id: target.id,
                  provider_id: provider.id,
                  method: provider.access_method_profile.method,
                },
              },
            }),
          ).data;
      if (!method) setRegisteredMethod(registered);
      try {
        const checked = apiData(
          await apiClient.POST("/api/v1/access-methods/{id}/check", {
            params: { path: { id: registered.id } },
            body: { access_method: { expected_revision: registered.revision } },
          }),
        ).data;
        if (!method) {
          setRegisteredMethod(checked);
          return;
        }
      } catch {
        if (method) await finish(true);
        else onError(t("targets.requestFailed"));
        return;
      }
      await finish();
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  async function finish(failed = false) {
    try {
      await onSaved();
    } catch {
      failed = true;
    }
    if (failed) onError(t("targets.requestFailed"));
  }

  async function checkRegisteredMethod() {
    if (!registeredMethod) return;
    setPending(true);
    onError("");
    try {
      const current = (
        await apiClient
          .GET("/api/v1/access-methods/{id}", {
            params: { path: { id: registeredMethod.id } },
          })
          .then(apiData)
      ).data;
      setRegisteredMethod(current);
      if (!current.check.current) {
        const checked = apiData(
          await apiClient.POST("/api/v1/access-methods/{id}/check", {
            params: { path: { id: current.id } },
            body: { access_method: { expected_revision: current.revision } },
          }),
        ).data;
        setRegisteredMethod(checked);
      }
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  async function saveGrants(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!registeredMethod?.check.current) return;
    const form = new FormData(event.currentTarget);
    setPending(true);
    onError("");
    let failed = false;
    try {
      const saved = apiData(
        await apiClient.PATCH("/api/v1/access-methods/{id}", {
          params: { path: { id: registeredMethod.id } },
          body: {
            access_method: {
              expected_revision: registeredMethod.revision,
              capabilities: form
                .getAll("capability")
                .filter((entry): entry is string => typeof entry === "string"),
            },
          },
        }),
      ).data;
      setRegisteredMethod(saved);
    } catch {
      failed = true;
    }
    await finish(failed);
    setPending(false);
  }

  if (registeredMethod)
    return (
      <form className="space-y-4" onSubmit={(event) => void saveGrants(event)}>
        <p className="text-sm">
          {registeredMethod.name} · {registeredMethod.endpoint}
        </p>
        <p className="text-sm text-muted-foreground">
          {t(
            registeredMethod.check.current
              ? "targets.chooseMethodGrants"
              : "targets.methodCheckRequired",
          )}
        </p>
        {registeredMethod.check.current && <CapabilityFields method={registeredMethod} />}
        <div className="flex gap-2">
          {registeredMethod.check.current ? (
            <Button type="submit" disabled={pending}>
              {pending ? <Spinner /> : <Check />}
              {t("targets.saveAccessMethod")}
            </Button>
          ) : (
            <Button type="button" disabled={pending} onClick={() => void checkRegisteredMethod()}>
              {pending ? <Spinner /> : <Check />}
              {t("targets.check")}
            </Button>
          )}
          <Button type="button" variant="ghost" disabled={pending} onClick={() => void finish()}>
            {t("common.cancel")}
          </Button>
        </div>
      </form>
    );

  if (creatingConnection) {
    const choice = catalog.types.find((item) => item.id === target.type_id);
    return (
      choice && (
        <div className="space-y-3">
          {availableProviders.length > 0 && (
            <Button variant="ghost" onClick={() => setCreatingConnection(false)}>
              {t("targets.useExistingConnection")}
            </Button>
          )}
          <TargetConnectionForm
            choice={choice}
            catalog={catalog}
            onError={onError}
            onCreated={({ provider, endpoint }) => {
              setCreatedProvider(provider);
              setProviderId(provider.id);
              setEndpoint(endpoint ?? "");
              setCreatingConnection(false);
            }}
          />
        </div>
      )
    );
  }

  return (
    <form className="grid gap-4 md:grid-cols-2" onSubmit={(event) => void submit(event)}>
      {method ? (
        <div className="space-y-2">
          <Label>{t("targets.connection")}</Label>
          <p className="text-sm">{provider?.name ?? t("targets.connectionMissing")}</p>
        </div>
      ) : (
        <div className="space-y-2">
          <Label htmlFor={`${fieldId}-provider`}>{t("targets.connection")}</Label>
          <FormSelect
            id={`${fieldId}-provider`}
            name="provider_id"
            required
            placeholder={t("targets.chooseConnection")}
            value={providerId}
            onValueChange={(id) => {
              setProviderId(id ?? "");
              setEndpoint("");
            }}
            options={availableProviders.map((item) => ({
              value: item.id,
              label: `${item.name} · ${item.adapter_type}`,
            }))}
          />
          <Button
            type="button"
            variant="ghost"
            size="sm"
            onClick={() => setCreatingConnection(true)}
          >
            <Plus />
            {t("targets.newConnection")}
          </Button>
        </div>
      )}
      <div className="space-y-2">
        <Label htmlFor={`${fieldId}-name`}>{t("targets.name")}</Label>
        <Input
          id={`${fieldId}-name`}
          name="name"
          defaultValue={method?.name ?? createdProvider?.name}
          required
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${fieldId}-endpoint`}>{t("targets.endpoint")}</Label>
        <Input
          id={`${fieldId}-endpoint`}
          name="endpoint"
          value={currentEndpoint}
          onChange={(event) => setEndpoint(event.target.value)}
          required
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${fieldId}-priority`}>{t("targets.priority")}</Label>
        <Input
          id={`${fieldId}-priority`}
          name="priority"
          type="number"
          min={0}
          max={10000}
          defaultValue={method?.priority ?? 100}
          required
        />
      </div>
      {method && <CapabilityFields method={method} />}
      <div className="flex gap-2 md:col-span-2">
        <Button type="submit" disabled={pending || !provider}>
          {pending ? <Spinner /> : method ? <Check /> : <Plus />}
          {t(method ? "targets.saveAccessMethod" : "targets.addAccessMethod")}
        </Button>
        {onCancel && (
          <Button type="button" variant="ghost" onClick={onCancel} disabled={pending}>
            {t("common.cancel")}
          </Button>
        )}
      </div>
    </form>
  );
}

function CapabilityFields({ method }: { method: AccessMethod }) {
  const { t } = useTranslation();
  return (
    <fieldset className="space-y-2 md:col-span-2">
      <legend className="text-sm font-medium">{t("targets.allowedCapabilities")}</legend>
      {Array.from(new Set([...method.check.observed_capabilities, ...method.capabilities])).map(
        (capability) => (
          <label key={capability} className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name="capability"
              value={capability}
              defaultChecked={method.capabilities.includes(capability)}
            />
            {capability}
          </label>
        ),
      )}
    </fieldset>
  );
}
