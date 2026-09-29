import { useState, type FormEvent } from "react";
import { Cable, Fingerprint, Link2, Plus, FileText, X } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient } from "@/api/client";
import { FormSelect, type FormSelectOption } from "@/components/form-select";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import { AccessMethodForm } from "@/targets/access-method-form";
import type { Provider, Target, TargetTypeCatalog } from "@/targets/data";

type Action = "identity" | "access" | "relationship" | "instructions";

export function TargetDetailActions({
  target,
  targets,
  providers,
  catalog,
  initialAction,
  onComplete,
  onError,
}: {
  target: Target;
  targets: Target[];
  providers: Provider[];
  catalog: TargetTypeCatalog;
  initialAction?: Action;
  onComplete: (message: string) => Promise<void>;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [action, setAction] = useState<Action | null>(initialAction ?? null);
  const [pending, setPending] = useState(false);

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
        <Button size="sm" variant="outline" onClick={() => setAction("instructions")}>
          <FileText />
          {t("targets.editInstructions")}
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
          <AccessMethodForm
            target={target}
            providers={providers}
            catalog={catalog}
            onSaved={async () => {
              await onComplete(t("targets.changeSaved"));
              setAction(null);
            }}
            onError={onError}
          />
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
            <LabeledSelect
              label={t("targets.destinationTarget")}
              name="destination_target_id"
              required
              placeholder={t("targets.chooseTarget")}
              options={targets
                .filter((item) => item.active && item.id !== target.id)
                .map((item) => ({ value: item.id, label: item.name }))}
            />
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
        {action === "instructions" && (
          <form
            className="space-y-4"
            onSubmit={(event) =>
              void submit(event, (form) =>
                apiClient.PATCH("/api/v1/targets/{id}", {
                  params: { path: { id: target.id } },
                  body: {
                    target: {
                      expected_revision: target.revision,
                      operating_instructions: value(form, "operating_instructions"),
                    },
                  },
                }),
              )
            }
          >
            <p className="text-sm text-muted-foreground">{t("targets.instructionsDescription")}</p>
            <div className="space-y-2">
              <Label htmlFor="operating_instructions">{t("targets.operatingInstructions")}</Label>
              <Textarea
                id="operating_instructions"
                name="operating_instructions"
                rows={6}
                maxLength={4000}
                defaultValue={target.operating_instructions}
              />
            </div>
            <Submit pending={pending} label={t("targets.saveInstructions")} />
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

function LabeledSelect({
  label,
  name,
  options,
  placeholder,
  defaultValue,
  required,
}: {
  label: string;
  name: string;
  options: FormSelectOption[];
  placeholder?: string;
  defaultValue?: string;
  required?: boolean;
}) {
  const id = "target-action-" + name;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <FormSelect
        id={id}
        name={name}
        options={options}
        placeholder={placeholder}
        defaultValue={defaultValue}
        required={required}
      />
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
