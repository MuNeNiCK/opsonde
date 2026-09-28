import { useId, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";

type Operation = components["schemas"]["BMCOperation"];
type Method = "redfish" | "ipmi";

const emptyInputSchema = {
  type: "object",
  properties: {
    selectors: { type: "object", additionalProperties: false },
    parameters: { type: "object", additionalProperties: false },
  },
  required: ["selectors", "parameters"],
  additionalProperties: false,
};
const emptyOutputSchema = { type: "object", additionalProperties: false };

function field(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function object(text: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("invalid JSON object");
  return parsed as Record<string, unknown>;
}

function JsonField({
  idPrefix,
  label,
  name,
  value,
  required = true,
}: {
  idPrefix: string;
  label: string;
  name: string;
  value: unknown;
  required?: boolean;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={`${idPrefix}-${name}`}>{label}</Label>
      <Textarea
        id={`${idPrefix}-${name}`}
        name={name}
        defaultValue={value === null ? "" : JSON.stringify(value, null, 2)}
        className="min-h-28 font-mono text-xs"
        spellCheck={false}
        required={required}
      />
    </div>
  );
}

export function BMCOperationForm({
  methodId,
  method,
  operation,
  onSaved,
  onCancel,
}: {
  methodId: string;
  method: Method;
  operation?: Operation;
  onSaved: () => Promise<void>;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const idPrefix = useId();
  const [kind, setKind] = useState<"observation" | "effect">(
    operation?.request_kind ?? "observation",
  );
  const [httpMethod, setHttpMethod] = useState(
    typeof operation?.protocol_request.method === "string"
      ? operation.protocol_request.method
      : "GET",
  );
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const verbs = kind === "observation" ? ["GET", "HEAD"] : ["POST", "PATCH", "PUT", "DELETE"];

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError("");

    try {
      const protocol_request =
        method === "redfish"
          ? { method: httpMethod, uri: field(form, "uri") }
          : { netfn: Number(field(form, "netfn")), command: Number(field(form, "command")) };
      const content = {
        name: field(form, "name"),
        description: field(form, "description"),
        request_kind: kind,
        protocol_request,
        input_schema: object(field(form, "input_schema")),
        output_schema: object(field(form, "output_schema")),
        verification_schema: field(form, "verification_schema")
          ? object(field(form, "verification_schema"))
          : null,
        secret_bindings: object(field(form, "secret_bindings")),
        parameter_classes: object(field(form, "parameter_classes")),
      };

      if (operation) {
        apiData(
          await apiClient.PATCH("/api/v1/bmc-operations/{id}", {
            params: { path: { id: operation.id } },
            body: { bmc_operation: { expected_revision: operation.revision, ...content } },
          }),
        );
      } else {
        apiData(
          await apiClient.POST("/api/v1/access-methods/{access_method_id}/bmc-operations", {
            params: { path: { access_method_id: methodId } },
            body: { bmc_operation: content },
          }),
        );
      }
      await onSaved();
    } catch (cause) {
      setError(
        cause instanceof SyntaxError ||
          (cause instanceof Error && cause.message === "invalid JSON object")
          ? t("targets.bmc.invalidJson")
          : t("targets.requestFailed"),
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <form className="space-y-4 rounded-lg border p-4" onSubmit={(event) => void submit(event)}>
      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor={`${idPrefix}-name`}>{t("targets.name")}</Label>
          <Input
            id={`${idPrefix}-name`}
            name="name"
            defaultValue={operation?.name}
            required
            maxLength={120}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`${idPrefix}-description`}>{t("targets.bmc.description")}</Label>
          <Input
            id={`${idPrefix}-description`}
            name="description"
            defaultValue={operation?.description}
            required
            maxLength={500}
          />
        </div>
        <div className="space-y-2">
          <Label htmlFor={`${idPrefix}-kind`}>{t("targets.bmc.requestKind")}</Label>
          <FormSelect
            id={`${idPrefix}-kind`}
            value={kind}
            onValueChange={(next) => {
              const selected = next === "effect" ? "effect" : "observation";
              setKind(selected);
              setHttpMethod(selected === "effect" ? "POST" : "GET");
            }}
            options={[
              { value: "observation", label: t("targets.bmc.observation") },
              { value: "effect", label: t("targets.bmc.effect") },
            ]}
          />
        </div>
        {method === "redfish" ? (
          <>
            <div className="space-y-2">
              <Label htmlFor={`${idPrefix}-verb`}>HTTP method</Label>
              <FormSelect
                id={`${idPrefix}-verb`}
                value={httpMethod}
                onValueChange={(next) => setHttpMethod(next ?? "GET")}
                options={verbs.map((verb) => ({ value: verb, label: verb }))}
              />
            </div>
            <div className="space-y-2 md:col-span-2">
              <Label htmlFor={`${idPrefix}-uri`}>{t("targets.bmc.uri")}</Label>
              <Input
                id={`${idPrefix}-uri`}
                name="uri"
                defaultValue={
                  typeof operation?.protocol_request.uri === "string"
                    ? operation.protocol_request.uri
                    : ""
                }
                placeholder="/redfish/v1/Systems/1"
                required
              />
            </div>
          </>
        ) : (
          <>
            <div className="space-y-2">
              <Label htmlFor={`${idPrefix}-netfn`}>NetFn</Label>
              <Input
                id={`${idPrefix}-netfn`}
                name="netfn"
                type="number"
                min={0}
                max={62}
                step={2}
                defaultValue={Number(operation?.protocol_request.netfn ?? 6)}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor={`${idPrefix}-command`}>Command</Label>
              <Input
                id={`${idPrefix}-command`}
                name="command"
                type="number"
                min={0}
                max={255}
                defaultValue={Number(operation?.protocol_request.command ?? 1)}
                required
              />
            </div>
          </>
        )}
      </div>

      <details>
        <summary className="cursor-pointer text-sm font-medium">
          {t("targets.bmc.advanced")}
        </summary>
        <p className="mt-2 text-sm text-muted-foreground">{t("targets.bmc.advancedHint")}</p>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <JsonField
            idPrefix={idPrefix}
            label={t("targets.bmc.inputSchema")}
            name="input_schema"
            value={operation?.input_schema ?? emptyInputSchema}
          />
          <JsonField
            idPrefix={idPrefix}
            label={t("targets.bmc.outputSchema")}
            name="output_schema"
            value={operation?.output_schema ?? emptyOutputSchema}
          />
          <JsonField
            idPrefix={idPrefix}
            label={t("targets.bmc.verificationSchema")}
            name="verification_schema"
            value={operation?.verification_schema ?? null}
            required={false}
          />
          <JsonField
            idPrefix={idPrefix}
            label={t("targets.bmc.secretBindings")}
            name="secret_bindings"
            value={operation?.secret_bindings ?? {}}
          />
          <JsonField
            idPrefix={idPrefix}
            label={t("targets.bmc.parameterClasses")}
            name="parameter_classes"
            value={operation?.parameter_classes ?? {}}
          />
        </div>
      </details>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      <div className="flex gap-2">
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
