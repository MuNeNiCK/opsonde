import { useState, type FormEvent } from "react";
import { Save } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient } from "@/api/client";
import type { components } from "@/api/schema";
import { Button } from "@/components/ui/button";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";

type AuthoritySetting = components["schemas"]["AuthoritySetting"];

type Props = {
  setting: AuthoritySetting;
  canManage: boolean;
  onRefresh: () => Promise<void>;
  onError: (message: string) => void;
};

const modes = ["readonly", "ask", "auto", "full_access"] as const;

function integer(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? Number(value) : Number.NaN;
}

export function AuthoritySetup({ setting, canManage, onRefresh, onError }: Props) {
  const { t } = useTranslation();
  const [mode, setMode] = useState<AuthoritySetting["authority_mode"]>(setting.authority_mode);
  const [automation, setAutomation] = useState(setting.signal_automation_enabled);
  const [saving, setSaving] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const reason = form.get("reason");
    if (typeof reason !== "string") return;

    setSaving(true);
    onError("");
    try {
      await apiClient.PUT("/api/v1/authority-setting", {
        body: {
          authority_setting: {
            expected_setting_revision: setting.setting_revision,
            authority_mode: mode,
            signal_automation_enabled: automation,
            max_elapsed_seconds: integer(form, "max_elapsed_seconds"),
            max_resolver_turns: integer(form, "max_resolver_turns"),
            max_target_requests: integer(form, "max_target_requests"),
            max_effects: integer(form, "max_effects"),
            max_related_targets: integer(form, "max_related_targets"),
            max_ai_usage_units: integer(form, "max_ai_usage_units"),
            max_no_progress_turns: integer(form, "max_no_progress_turns"),
            reason,
          },
        },
      });
      await onRefresh();
    } catch {
      onError(t("setup.requestFailed"));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section id="authority" className="scroll-mt-6 space-y-4">
      <div>
        <h2 className="text-xl font-semibold">{t("setup.authorityTitle")}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("setup.authorityDescription")}</p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle>{t("setup.modeTitle")}</CardTitle>
          <CardDescription>{t("setup.policyAlwaysApplies")}</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-6" onSubmit={submit}>
            <fieldset
              disabled={!canManage || saving}
              className="grid gap-3 md:grid-cols-2 xl:grid-cols-4"
            >
              <legend className="sr-only">{t("setup.modeTitle")}</legend>
              {modes.map((candidate) => (
                <label
                  key={candidate}
                  className="flex cursor-pointer gap-3 rounded-lg border p-4 has-checked:border-primary has-checked:bg-primary/5"
                >
                  <input
                    type="radio"
                    name="authority_mode"
                    value={candidate}
                    checked={mode === candidate}
                    onChange={() => setMode(candidate)}
                    className="mt-1"
                  />
                  <span>
                    <span className="block font-medium">{t(`setup.modes.${candidate}.name`)}</span>
                    <span className="mt-1 block text-sm text-muted-foreground">
                      {t(`setup.modes.${candidate}.description`)}
                    </span>
                  </span>
                </label>
              ))}
            </fieldset>

            <div className="flex items-center justify-between gap-4 rounded-lg border p-4">
              <div>
                <Label htmlFor="signal-automation">{t("setup.automation")}</Label>
                <p className="mt-1 text-sm text-muted-foreground">
                  {t("setup.automationDescription")}
                </p>
              </div>
              <Switch
                id="signal-automation"
                checked={automation}
                onCheckedChange={setAutomation}
                disabled={!canManage || saving}
              />
            </div>

            <fieldset
              disabled={!canManage || saving}
              className="grid gap-4 md:grid-cols-2 xl:grid-cols-3"
            >
              <legend className="mb-3 font-medium">{t("setup.limits")}</legend>
              <NumberField
                name="max_elapsed_seconds"
                label={t("setup.maxElapsed")}
                value={setting.max_elapsed_seconds}
                min={60}
                max={2592000}
              />
              <NumberField
                name="max_resolver_turns"
                label={t("setup.maxTurns")}
                value={setting.max_resolver_turns}
                min={1}
                max={1000}
              />
              <NumberField
                name="max_target_requests"
                label={t("setup.maxRequests")}
                value={setting.max_target_requests}
                min={1}
                max={10000}
              />
              <NumberField
                name="max_effects"
                label={t("setup.maxEffects")}
                value={setting.max_effects}
                min={0}
                max={1000}
              />
              <NumberField
                name="max_related_targets"
                label={t("setup.maxRelated")}
                value={setting.max_related_targets}
                min={0}
                max={1000}
              />
              <NumberField
                name="max_ai_usage_units"
                label={t("setup.maxAIUsage")}
                value={setting.max_ai_usage_units}
                min={1}
                max={1000000000}
              />
              <NumberField
                name="max_no_progress_turns"
                label={t("setup.maxNoProgress")}
                value={setting.max_no_progress_turns}
                min={1}
                max={100}
              />
            </fieldset>

            <div className="space-y-2">
              <Label htmlFor="authority-reason">{t("setup.changeReason")}</Label>
              <Textarea
                id="authority-reason"
                name="reason"
                defaultValue={setting.reason}
                required
                minLength={1}
                maxLength={500}
                disabled={!canManage || saving}
              />
            </div>

            <Alert>
              <AlertDescription>
                {t(
                  automation
                    ? "setup.automationEnabledConsequence"
                    : "setup.automationDisabledConsequence",
                )}
              </AlertDescription>
            </Alert>

            {canManage && (
              <Button type="submit" disabled={saving}>
                {saving ? <Spinner /> : <Save />}
                {t("setup.saveAuthority")}
              </Button>
            )}
          </form>
        </CardContent>
      </Card>
    </section>
  );
}

function NumberField({
  name,
  label,
  value,
  min,
  max,
}: {
  name: string;
  label: string;
  value: number;
  min: number;
  max: number;
}) {
  return (
    <div className="space-y-2">
      <Label htmlFor={name}>{label}</Label>
      <Input
        id={name}
        name={name}
        type="number"
        defaultValue={value}
        min={min}
        max={max}
        required
      />
    </div>
  );
}
