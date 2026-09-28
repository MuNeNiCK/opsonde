import { useCallback, useEffect, useId, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import type { AccessMethod } from "@/targets/data";
import { BMCOperationForm } from "@/targets/bmc-operation-form";

type Operation = components["schemas"]["BMCOperation"];
type Secret = components["schemas"]["BMCSecret"];
type Editor<T> = T | "new" | null;

async function loadMethodSetup(methodId: string, canReadSecrets: boolean) {
  const [operations, secrets] = await Promise.all([
    collectPages((after) =>
      apiClient
        .GET("/api/v1/access-methods/{access_method_id}/bmc-operations", {
          params: {
            path: { access_method_id: methodId },
            query: { limit: 100, after: after ?? undefined },
          },
        })
        .then(apiData),
    ),
    canReadSecrets
      ? collectPages((after) =>
          apiClient
            .GET("/api/v1/access-methods/{access_method_id}/bmc-secrets", {
              params: {
                path: { access_method_id: methodId },
                query: { limit: 100, after: after ?? undefined },
              },
            })
            .then(apiData),
        )
      : Promise.resolve([]),
  ]);
  return { operations, secrets };
}

export function BMCMethodSetup({
  method,
  canManage,
  canReadSecrets,
}: {
  method: AccessMethod;
  canManage: boolean;
  canReadSecrets: boolean;
}) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  return (
    <details
      className="rounded-lg border p-4"
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary className="cursor-pointer font-medium">
        {method.name} · {method.method.toUpperCase()}
        <span className="ml-2 text-sm font-normal text-muted-foreground">
          {t("targets.bmc.manage")}
        </span>
      </summary>
      {open && (
        <BMCMethodContent method={method} canManage={canManage} canReadSecrets={canReadSecrets} />
      )}
    </details>
  );
}

function BMCMethodContent({
  method,
  canManage,
  canReadSecrets,
}: {
  method: AccessMethod;
  canManage: boolean;
  canReadSecrets: boolean;
}) {
  const { t } = useTranslation();
  const [operations, setOperations] = useState<Operation[]>([]);
  const [secrets, setSecrets] = useState<Secret[]>([]);
  const [operationEditor, setOperationEditor] = useState<Editor<Operation>>(null);
  const [secretEditor, setSecretEditor] = useState<Editor<Secret>>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const refresh = useCallback(async () => {
    const next = await loadMethodSetup(method.id, canReadSecrets);
    setOperations(next.operations);
    setSecrets(next.secrets);
    setLoading(false);
    setError("");
  }, [method.id, canReadSecrets]);

  useEffect(() => {
    let active = true;
    void loadMethodSetup(method.id, canReadSecrets)
      .then((next) => {
        if (!active) return;
        setOperations(next.operations);
        setSecrets(next.secrets);
        setLoading(false);
      })
      .catch(() => {
        if (!active) return;
        setError(t("targets.requestFailed"));
        setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [method.id, canReadSecrets, t]);

  async function afterSaved() {
    await refresh();
    setOperationEditor(null);
    setSecretEditor(null);
  }

  async function deactivate(kind: "operation" | "secret", id: string, revision: number) {
    if (!window.confirm(t("targets.bmc.confirmDeactivate"))) return;
    try {
      if (kind === "operation") {
        apiData(
          await apiClient.POST("/api/v1/bmc-operations/{id}/deactivate", {
            params: { path: { id } },
            body: { bmc_operation: { expected_revision: revision } },
          }),
        );
      } else {
        apiData(
          await apiClient.POST("/api/v1/bmc-secrets/{id}/deactivate", {
            params: { path: { id } },
            body: { bmc_secret: { expected_revision: revision } },
          }),
        );
      }
      await refresh();
    } catch {
      setError(t("targets.requestFailed"));
    }
  }

  return (
    <div className="mt-4 space-y-6">
      {loading && (
        <div className="flex items-center gap-2 text-sm text-muted-foreground">
          <Spinner />
          {t("common.loading")}
        </div>
      )}
      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      <Button
        size="sm"
        variant="outline"
        onClick={() => void refresh().catch(() => setError(t("targets.requestFailed")))}
      >
        {t("targets.bmc.refresh")}
      </Button>

      <section className="space-y-3">
        <div className="flex items-center justify-between gap-2">
          <h3 className="font-medium">{t("targets.bmc.operations")}</h3>
          {canManage && (
            <Button size="sm" variant="outline" onClick={() => setOperationEditor("new")}>
              {t("targets.bmc.addOperation")}
            </Button>
          )}
        </div>
        {!loading && operations.length === 0 && (
          <p className="text-sm text-muted-foreground">{t("targets.bmc.noOperations")}</p>
        )}
        {operations.map((operation) => (
          <div key={operation.id} className="rounded-md border p-3 text-sm">
            <div className="flex flex-wrap items-center gap-2">
              <strong>{operation.name}</strong>
              <Badge variant="outline">{t(`targets.bmc.${operation.request_kind}`)}</Badge>
              {!operation.active && <Badge variant="secondary">{t("targets.disabled")}</Badge>}
            </div>
            <p className="mt-1 text-muted-foreground">{operation.description}</p>
            <p className="mt-1 break-all font-mono text-xs">
              {JSON.stringify(operation.protocol_request)}
            </p>
            {canManage && operation.active && (
              <div className="mt-3 flex gap-2">
                <Button size="sm" variant="outline" onClick={() => setOperationEditor(operation)}>
                  {t("targets.bmc.edit")}
                </Button>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void deactivate("operation", operation.id, operation.revision)}
                >
                  {t("targets.disable")}
                </Button>
              </div>
            )}
          </div>
        ))}
        {operationEditor && (
          <BMCOperationForm
            key={operationEditor === "new" ? "new" : operationEditor.id}
            methodId={method.id}
            method={method.method as "redfish" | "ipmi"}
            operation={operationEditor === "new" ? undefined : operationEditor}
            onSaved={afterSaved}
            onCancel={() => setOperationEditor(null)}
          />
        )}
      </section>

      {canReadSecrets && (
        <section className="space-y-3">
          <div className="flex items-center justify-between gap-2">
            <h3 className="font-medium">{t("targets.bmc.secrets")}</h3>
            {canManage && (
              <Button size="sm" variant="outline" onClick={() => setSecretEditor("new")}>
                {t("targets.bmc.addSecret")}
              </Button>
            )}
          </div>
          {!loading && secrets.length === 0 && (
            <p className="text-sm text-muted-foreground">{t("targets.bmc.noSecrets")}</p>
          )}
          {secrets.map((secret) => (
            <div key={secret.id} className="rounded-md border p-3 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <strong>{secret.name}</strong>
                <Badge variant="outline">v{secret.revision}</Badge>
                {!secret.active && <Badge variant="secondary">{t("targets.disabled")}</Badge>}
              </div>
              <p className="mt-1 break-all font-mono text-xs text-muted-foreground">{secret.id}</p>
              {canManage && secret.active && (
                <div className="mt-3 flex gap-2">
                  <Button size="sm" variant="outline" onClick={() => setSecretEditor(secret)}>
                    {t("targets.bmc.rotate")}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => void deactivate("secret", secret.id, secret.revision)}
                  >
                    {t("targets.disable")}
                  </Button>
                </div>
              )}
            </div>
          ))}
          {secretEditor && (
            <BMCSecretForm
              key={secretEditor === "new" ? "new" : secretEditor.id}
              methodId={method.id}
              secret={secretEditor === "new" ? undefined : secretEditor}
              onSaved={afterSaved}
              onCancel={() => setSecretEditor(null)}
            />
          )}
        </section>
      )}
    </div>
  );
}

function BMCSecretForm({
  methodId,
  secret,
  onSaved,
  onCancel,
}: {
  methodId: string;
  secret?: Secret;
  onSaved: () => Promise<void>;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const idPrefix = useId();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const rawName = form.get("name");
    const rawValue = form.get("value");
    const name = typeof rawName === "string" ? rawName.trim() : "";
    const value = typeof rawValue === "string" ? rawValue : "";
    setPending(true);
    setError("");
    try {
      if (secret) {
        apiData(
          await apiClient.PATCH("/api/v1/bmc-secrets/{id}", {
            params: { path: { id: secret.id } },
            body: { bmc_secret: { expected_revision: secret.revision, name, value } },
          }),
        );
      } else {
        apiData(
          await apiClient.POST("/api/v1/access-methods/{access_method_id}/bmc-secrets", {
            params: { path: { access_method_id: methodId } },
            body: { bmc_secret: { name, value } },
          }),
        );
      }
      formElement.reset();
      await onSaved();
    } catch {
      setError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  return (
    <form
      className="grid gap-4 rounded-lg border p-4 md:grid-cols-2"
      onSubmit={(event) => void submit(event)}
    >
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-name`}>{t("targets.name")}</Label>
        <Input
          id={`${idPrefix}-name`}
          name="name"
          defaultValue={secret?.name}
          required
          maxLength={120}
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor={`${idPrefix}-value`}>{t("targets.bmc.secretValue")}</Label>
        <Input
          id={`${idPrefix}-value`}
          name="value"
          type="password"
          autoComplete="new-password"
          required
          maxLength={4096}
        />
      </div>
      <p className="text-sm text-muted-foreground md:col-span-2">{t("targets.bmc.secretHint")}</p>
      {error && (
        <Alert variant="destructive" className="md:col-span-2">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      <div className="flex gap-2 md:col-span-2">
        <Button type="submit" size="sm" disabled={pending}>
          {t("targets.bmc.save")}
        </Button>
        <Button type="button" size="sm" variant="outline" onClick={onCancel}>
          {t("common.cancel")}
        </Button>
      </div>
    </form>
  );
}
