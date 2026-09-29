import { useState, type FormEvent } from "react";
import { Check, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import { FormSelect } from "@/components/form-select";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
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
  const allowedTypes =
    catalog.types.find((item) => item.id === target.type_id)?.access_method_types ?? [];
  const availableProviders = providers.filter(
    (provider) =>
      provider.kind === "target" &&
      provider.enabled &&
      provider.check.status === "passed" &&
      provider.check.checked_revision === provider.revision &&
      provider.access_method_profile &&
      allowedTypes.includes(provider.adapter_type),
  );
  const provider = availableProviders.find((item) => item.id === providerId);
  const isBMC = provider?.adapter_type.startsWith("bmc-") ?? false;
  const fixedEndpoint = isBMC || provider?.adapter_type === "http-api";
  const currentEndpoint =
    fixedEndpoint && typeof provider?.configuration.endpoint === "string"
      ? provider.configuration.endpoint
      : endpoint;
  const fieldId = `target-access-${method?.id ?? "new"}`;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!provider?.access_method_profile) return onError(t("targets.connectionRequired"));
    const form = new FormData(event.currentTarget);
    const name = form.get("name");
    setPending(true);
    onError("");
    try {
      const response = apiData(
        await apiClient.POST("/api/v1/providers/{id}/target-capabilities", {
          params: { path: { id: provider.id } },
          body: { provider: { expected_revision: provider.revision } },
        }),
      );
      const advertisedCapabilities = Array.from(
        new Set(
          [...response.data.observations, ...response.data.effects].map(
            (operation) => operation.capability,
          ),
        ),
      );
      const powerAllowed = isBMC && form.has("power");
      const capabilities = method
        ? method.capabilities.filter(
            (capability) =>
              advertisedCapabilities.includes(capability) &&
              (capability !== "effect.power" || powerAllowed),
          )
        : advertisedCapabilities.filter(
            (capability) => capability !== "effect.power" || powerAllowed,
          );
      if (
        method &&
        powerAllowed &&
        advertisedCapabilities.includes("effect.power") &&
        !capabilities.includes("effect.power")
      ) {
        capabilities.push("effect.power");
      }
      const values = {
        name: typeof name === "string" ? name : "",
        endpoint: currentEndpoint,
        provider_revision: provider.revision,
        priority: Number(form.get("priority")),
        capabilities,
      };
      if (method) {
        apiData(
          await apiClient.PATCH("/api/v1/access-methods/{id}", {
            params: { path: { id: method.id } },
            body: { access_method: { ...values, expected_revision: method.revision } },
          }),
        );
      } else {
        apiData(
          await apiClient.POST("/api/v1/access-methods", {
            body: {
              access_method: {
                ...values,
                target_id: target.id,
                provider_id: provider.id,
                platform: provider.access_method_profile.platform,
                method: provider.access_method_profile.method,
              },
            },
          }),
        );
      }
      await onSaved();
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
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
              const selected = availableProviders.find((item) => item.id === id);
              setEndpoint(
                typeof selected?.configuration.endpoint === "string"
                  ? selected.configuration.endpoint
                  : "",
              );
            }}
            options={availableProviders.map((item) => ({
              value: item.id,
              label: `${item.name} · ${item.adapter_type}`,
            }))}
          />
        </div>
      )}
      <div className="space-y-2">
        <Label htmlFor={`${fieldId}-name`}>{t("targets.name")}</Label>
        <Input id={`${fieldId}-name`} name="name" defaultValue={method?.name} required />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${fieldId}-endpoint`}>{t("targets.endpoint")}</Label>
        <Input
          id={`${fieldId}-endpoint`}
          name="endpoint"
          value={currentEndpoint}
          onChange={(event) => setEndpoint(event.target.value)}
          readOnly={fixedEndpoint}
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
      {isBMC && (
        <label className="flex items-center gap-2 text-sm md:col-span-2">
          <input
            type="checkbox"
            name="power"
            className="size-4"
            defaultChecked={method?.capabilities.includes("effect.power")}
          />
          {t("targets.allowPowerControl")}
        </label>
      )}
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
