import { Children, useState, type FormEvent, type ReactNode } from "react";
import { CircleAlert, RefreshCw, ShieldCheck } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { summarizeValue, translatedToken } from "@/cases/detail-utils";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";

type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type Proposal = components["schemas"]["Proposal"];

export function PrimaryAction({
  incident,
  awaitingProposal,
  canOperate,
  pending,
  claim,
}: {
  incident: CaseSnapshot["case"];
  awaitingProposal?: Proposal;
  canOperate: boolean;
  pending: string | null;
  claim: () => void;
}) {
  const { t } = useTranslation();

  if (!canOperate || ["resolved", "cancelled"].includes(incident.status)) return null;

  if (awaitingProposal) {
    return (
      <Button asChild size="sm">
        <a href={"#proposal-" + awaitingProposal.id}>{t("cases.reviewProposal")}</a>
      </Button>
    );
  }

  if (incident.status === "needs_attention") {
    return (
      <Button asChild size="sm">
        <a href="#resume-resolution">{t("cases.resume")}</a>
      </Button>
    );
  }

  if (incident.alert_state === "firing" && incident.current_owner_id === null) {
    return (
      <Button size="sm" disabled={pending !== null} onClick={claim}>
        {pending === "claim" && <Spinner />}
        {t("cases.claim")}
      </Button>
    );
  }

  return null;
}

export function ContextCard({
  title,
  icon,
  children,
}: {
  title: string;
  icon: ReactNode;
  children: ReactNode;
}) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="flex items-center gap-2 text-sm text-muted-foreground">
          <span className="[&_svg]:size-4">{icon}</span>
          {title}
        </CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

export function StateIcon({ state }: { state: CaseSnapshot["case"]["status"] }) {
  if (state === "resolved") {
    return <ShieldCheck className="mt-1 size-6 shrink-0 text-emerald-600" aria-hidden="true" />;
  }

  if (state === "needs_attention" || state === "cancelled") {
    return <CircleAlert className="mt-1 size-6 shrink-0 text-destructive" aria-hidden="true" />;
  }

  return <RefreshCw className="mt-1 size-6 shrink-0 text-primary" aria-hidden="true" />;
}

export function ProposalCard({
  proposal,
  target,
  method,
  provider,
  canOperate,
  pending,
  decide,
}: {
  proposal: Proposal;
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
          {target} · {method} · {provider} · {t(`setup.modes.${proposal.authority_mode}.name`)}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-5">
        <p className="text-sm">{proposal.reason}</p>
        <div className="grid gap-4 lg:grid-cols-3">
          <DataBlock
            title={t("cases.effectRequest")}
            value={{ selectors: proposal.selectors, parameters: proposal.parameters }}
          />
          <DataBlock title={t("cases.expectedResult")} value={proposal.expected_result} />
          <DataBlock
            title={t("cases.verification")}
            value={{ intent: proposal.verification_intent, tool: proposal.verification_tool }}
          />
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
export function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words">{value}</dd>
    </div>
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
export function Empty({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-lg border bg-card p-6 text-center text-sm text-muted-foreground">
      {children}
    </div>
  );
}
export function RecordCard({
  title,
  empty,
  children,
}: {
  title: string;
  empty: string;
  children: ReactNode;
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        {Children.count(children) > 0 ? (
          children
        ) : (
          <p className="text-sm text-muted-foreground">{empty}</p>
        )}
      </CardContent>
    </Card>
  );
}
export function HistoryRow({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children?: ReactNode;
}) {
  return (
    <div className="space-y-2">
      <div>
        <p className="font-medium">{title}</p>
        {subtitle && <p className="break-words text-sm text-muted-foreground">{subtitle}</p>}
      </div>
      {children}
      <Separator />
    </div>
  );
}
