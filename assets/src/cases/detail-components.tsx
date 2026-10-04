import { useEffect, useState, type FormEvent } from "react";
import { CircleAlert, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { apiClient, apiData } from "@/api/client";
import type { LogEntry } from "@/cases/workflow-log";
import { summarizeValue, translatedToken } from "@/cases/detail-utils";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type Proposal = components["schemas"]["Proposal"];

export function ProposalCard({
  proposal,
  conditions,
  target,
  method,
  provider,
  canOperate,
  pending,
  decide,
}: {
  proposal: Proposal;
  conditions: CaseSnapshot["conditions"];
  target: string;
  method: string;
  provider: string;
  canOperate: boolean;
  pending: string | null;
  decide: (decision: "approved" | "rejected", reason: string) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [reason, setReason] = useState("");
  const [confirmApproval, setConfirmApproval] = useState(false);
  const [confirmRejection, setConfirmRejection] = useState(false);
  return (
    <Card id={"proposal-" + proposal.id}>
      <CardHeader>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <CardTitle>
            {proposal.capability} / {proposal.operation}
          </CardTitle>
          <Badge
            variant={
              proposal.status === "blocked" || proposal.status === "rejected"
                ? "destructive"
                : "secondary"
            }
          >
            {translatedToken(t, "proposalStatus", proposal.status)}
          </Badge>
        </div>
        <CardDescription>
          {proposal.purpose && (
            <Badge variant="outline" className="mr-2">
              {t(`cases.purpose.${proposal.purpose}`)}
            </Badge>
          )}
          {target} · {method} · {provider} · {t(`setup.modes.${proposal.authority_mode}.name`)}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <p className="text-sm">{proposal.reason}</p>
        {proposal.delay_seconds > 0 && (
          <p className="text-sm text-muted-foreground">
            {t("cases.requestDelay", { seconds: proposal.delay_seconds })}
          </p>
        )}
        {proposal.affected_conditions.length > 0 && (
          <div className="space-y-2">
            <p className="text-sm font-medium">{t("cases.conditionsTitle")}</p>
            {proposal.affected_conditions.map((claim) => {
              const condition = conditions.find((item) => item.id === claim.condition_id);
              return (
                <div key={claim.condition_id} className="flex flex-wrap items-center gap-2 text-sm">
                  <span>{condition?.predicate ?? claim.condition_id}</span>
                  <Badge variant={condition?.state === "firing" ? "destructive" : "outline"}>
                    {condition ? t(`cases.alert.${condition.state}`) : claim.condition_id}
                  </Badge>
                  <span className="font-mono text-xs text-muted-foreground">
                    {claim.condition_id} · r{claim.revision}
                  </span>
                </div>
              );
            })}
          </div>
        )}
        <div
          className={
            proposal.purpose === "remediation" ? "grid gap-4 lg:grid-cols-3" : "grid gap-4"
          }
        >
          <DataBlock
            title={t("cases.effectRequest")}
            value={{ selectors: proposal.selectors, parameters: proposal.parameters }}
          />
          {proposal.purpose === "remediation" && (
            <>
              <DataBlock title={t("cases.expectedResult")} value={proposal.expected_result} />
              <DataBlock
                title={t("cases.verification")}
                value={{ intent: proposal.verification_intent, tool: proposal.verification_tool }}
              />
            </>
          )}
        </div>
        {proposal.preflight_reason && (
          <Alert variant="destructive">
            <AlertDescription>
              <p>{t("cases.situation.preflightBlocked")}</p>
              <details className="mt-2 text-xs">
                <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                <p className="mt-1">{proposal.preflight_reason}</p>
              </details>
            </AlertDescription>
          </Alert>
        )}
        {proposal.status === "awaiting_human" && canOperate && (
          <div className="space-y-3 rounded-md border p-4">
            <Label htmlFor={`reason-${proposal.id}`}>{t("cases.decisionReason")}</Label>
            <Textarea
              id={`reason-${proposal.id}`}
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              required
            />
            {!confirmApproval && !confirmRejection ? (
              <div className="flex flex-wrap gap-2">
                <Button
                  size="sm"
                  disabled={!reason || pending !== null}
                  onClick={() => setConfirmApproval(true)}
                >
                  {pending === `proposal-${proposal.id}` && <Spinner />}
                  {t("cases.approve")}
                </Button>
                <Button
                  size="sm"
                  variant="destructive"
                  disabled={!reason || pending !== null}
                  onClick={() => setConfirmRejection(true)}
                >
                  {t("cases.reject")}
                </Button>
              </div>
            ) : confirmApproval ? (
              <Alert>
                <ShieldCheck />
                <AlertDescription>
                  <p>{t("cases.approveConfirmation")}</p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      disabled={pending !== null}
                      onClick={() => void decide("approved", reason)}
                    >
                      {pending === "proposal-" + proposal.id && <Spinner />}
                      {t("cases.confirmApprove")}
                    </Button>
                    <Button size="sm" variant="outline" onClick={() => setConfirmApproval(false)}>
                      {t("common.cancel")}
                    </Button>
                  </div>
                </AlertDescription>
              </Alert>
            ) : (
              <Alert variant="destructive">
                <CircleAlert />
                <AlertDescription>
                  <p>{t("cases.rejectConfirmation")}</p>
                  <div className="mt-2 flex flex-wrap gap-2">
                    <Button
                      size="sm"
                      variant="destructive"
                      disabled={pending !== null}
                      onClick={() => void decide("rejected", reason)}
                    >
                      {pending === "proposal-" + proposal.id && <Spinner />}
                      {t("cases.confirmReject")}
                    </Button>
                    <Button size="sm" variant="outline" onClick={() => setConfirmRejection(false)}>
                      {t("common.cancel")}
                    </Button>
                  </div>
                </AlertDescription>
              </Alert>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

export function ResumeCard({
  incident,
  run,
  pending,
  onSubmit,
}: {
  incident: CaseSnapshot["case"];
  run: CaseSnapshot["resolution_runs"][number];
  pending: boolean;
  onSubmit: (event: FormEvent<HTMLFormElement>) => Promise<void>;
}) {
  const { t } = useTranslation();
  return (
    <Card id="resume-resolution" className="border-destructive/40">
      <CardHeader>
        <CardTitle>{t("cases.resumeTitle")}</CardTitle>
        <CardDescription>{t("cases.resumeSafeDefaults")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="space-y-4" onSubmit={(event) => void onSubmit(event)}>
          <div className="space-y-2">
            <Label htmlFor="resume-reason">{t("cases.resumeReason")}</Label>
            <Textarea id="resume-reason" name="reason" required maxLength={500} />
          </div>
          <details className="rounded-lg border p-4">
            <summary className="cursor-pointer text-sm font-medium">
              {t("cases.advancedLimits")}
            </summary>
            <p className="mt-2 text-sm text-muted-foreground">
              {t("cases.advancedLimitsDescription")}
            </p>
            <div className="mt-4 grid gap-4 md:grid-cols-2 xl:grid-cols-4">
              <div className="space-y-2">
                <Label htmlFor="resume-mode">{t("cases.authority")}</Label>
                <FormSelect
                  id="resume-mode"
                  name="authority_mode"
                  defaultValue={incident.authority_mode}
                  options={["readonly", "ask", "auto", "full_access"].map((mode) => ({
                    value: mode,
                    label: t("setup.modes." + mode + ".name"),
                  }))}
                />
              </div>
              {Object.entries(run.limits).map(([name, value]) => (
                <NumberField
                  key={name}
                  name={name}
                  label={t("cases.limit." + name)}
                  value={value}
                />
              ))}
            </div>
          </details>
          <Button type="submit" disabled={pending}>
            {pending && <Spinner />}
            {t("cases.resume")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function NumberField({
  name,
  label,
  value,
}: {
  name: string;
  label: string;
  value: number;
}) {
  const min =
    name === "max_elapsed_seconds"
      ? 60
      : name === "max_effects" || name === "max_related_targets"
        ? 0
        : 1;
  return (
    <div className="space-y-2">
      <Label htmlFor={`resume-${name}`}>{label}</Label>
      <Input
        id={`resume-${name}`}
        name={name}
        type="number"
        min={min}
        defaultValue={value}
        required
      />
    </div>
  );
}
type Receipt = NonNullable<LogEntry["receipt"]>;

export function ReceiptDetails({ kind, id, revision }: Receipt) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);

  return (
    <details className="mt-2" onToggle={(event) => setOpen(event.currentTarget.open)}>
      <summary className="cursor-pointer text-xs font-medium text-muted-foreground">
        {t("cases.workflow.technicalDetails")}
      </summary>
      {open && <ReceiptContent key={`${kind}:${id}:${revision}`} kind={kind} id={id} />}
    </details>
  );
}

async function loadReceipt(
  kind: Receipt["kind"],
  id: string,
  signal: AbortSignal,
): Promise<unknown> {
  const options = { params: { path: { id } }, signal };
  switch (kind) {
    case "evidence":
      return apiClient
        .GET("/api/v1/evidence/{id}", options)
        .then(apiData)
        .then((response) => response.data.content);
    case "operation":
      return apiClient
        .GET("/api/v1/operations/{id}", options)
        .then(apiData)
        .then((response) => response.data);
    case "verification":
      return apiClient
        .GET("/api/v1/verification-attempts/{id}", options)
        .then(apiData)
        .then((response) => response.data);
  }
}

function ReceiptContent({ kind, id }: Pick<Receipt, "kind" | "id">) {
  const { t } = useTranslation();
  const [content, setContent] = useState<unknown>();
  const [error, setError] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    loadReceipt(kind, id, controller.signal)
      .then((response) => {
        if (!controller.signal.aborted) setContent(response);
      })
      .catch((reason: unknown) => {
        if (!controller.signal.aborted)
          setError(reason instanceof Error ? reason.message : t("cases.requestFailed"));
      });
    return () => controller.abort();
  }, [kind, id, t]);

  if (error)
    return (
      <p role="alert" className="mt-2 text-sm text-destructive">
        {error}
      </p>
    );
  if (content === undefined) return <p role="status">{t("common.loading")}</p>;
  return (
    <pre className="mt-2 max-h-52 overflow-auto rounded-md bg-muted/45 p-3 font-mono text-[10px] leading-relaxed text-muted-foreground">
      {JSON.stringify(content, null, 2)}
    </pre>
  );
}

export function DataBlock({ title, value }: { title?: string; value: unknown }) {
  const { t } = useTranslation();
  return (
    <div className="min-w-0">
      {title && <p className="mb-2 text-xs font-medium text-muted-foreground">{title}</p>}
      <p className="break-words text-sm">{summarizeValue(value, t("cases.evidenceRecorded"))}</p>
      <details className="mt-2">
        <summary className="cursor-pointer text-xs font-medium text-muted-foreground">
          {t("cases.technicalDetails")}
        </summary>
        <pre className="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 font-mono text-xs">
          {JSON.stringify(value, null, 2)}
        </pre>
      </details>
    </div>
  );
}
