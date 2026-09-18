import { Children, useCallback, useEffect, useState, type FormEvent, type ReactNode } from "react";
import { ArrowLeft, RefreshCw } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useParams } from "react-router-dom";
import { apiCollection, apiRequest, type DataResponse } from "@/api";
import type { Account } from "@/auth-context";
import { useAuthentication } from "@/auth-context";
import type {
  Approval,
  CaseEvent,
  CaseSnapshot,
  Evidence,
  Proposal,
  ReviewDecision,
  Turn,
} from "@/case-types";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import type { Provider } from "@/setup-types";
import type { AccessMethod, Target } from "@/target-types";

type Detail = {
  snapshot: CaseSnapshot;
  timeline: CaseEvent[];
  turns: Turn[];
  evidence: Evidence[];
  approvals: Approval[];
  reviews: ReviewDecision[];
  targets: Target[];
  methods: AccessMethod[];
  providers: Provider[];
  accounts: Account[];
};

async function loadDetail(caseId: string, includeAccounts: boolean): Promise<Detail> {
  const [
    snapshotResponse,
    timeline,
    turns,
    evidence,
    approvals,
    reviews,
    targets,
    methods,
    providers,
    accounts,
  ] = await Promise.all([
    apiRequest<DataResponse<CaseSnapshot>>(`/cases/${caseId}`),
    apiCollection<CaseEvent>(`/cases/${caseId}/timeline`),
    apiCollection<Turn>(`/cases/${caseId}/turns`),
    apiCollection<Evidence>(`/cases/${caseId}/evidence`),
    apiCollection<Approval>(`/cases/${caseId}/approvals`),
    apiCollection<ReviewDecision>(`/cases/${caseId}/review-decisions`),
    apiCollection<Target>("/targets"),
    apiCollection<AccessMethod>("/access-methods"),
    apiCollection<Provider>("/providers"),
    includeAccounts ? apiCollection<Account>("/accounts") : Promise.resolve([]),
  ]);
  return {
    snapshot: snapshotResponse.data,
    timeline,
    turns,
    evidence,
    approvals,
    reviews,
    targets,
    methods,
    providers,
    accounts,
  };
}

export function CaseDetailPage() {
  const { caseId = "" } = useParams();
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const canOperate = account?.role === "admin" || account?.role === "operator";

  const refresh = useCallback(async () => {
    if (!caseId) return;
    setDetail(await loadDetail(caseId, account?.role === "admin"));
  }, [account?.role, caseId]);

  useEffect(() => {
    let active = true;
    loadDetail(caseId, account?.role === "admin")
      .then((next) => active && setDetail(next))
      .catch((failure: unknown) => {
        if (active) setError(failure instanceof Error ? failure.message : t("cases.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [account?.role, caseId, t]);

  useEffect(() => {
    if (detail?.snapshot.case.status !== "running") return;
    const timer = window.setInterval(() => void refresh().catch(() => undefined), 4_000);
    return () => window.clearInterval(timer);
  }, [detail?.snapshot.case.status, refresh]);

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    setError("");
    try {
      await action();
      await refresh();
    } catch (failure) {
      setError(failure instanceof Error ? failure.message : t("cases.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  if (!detail) {
    return (
      <main className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </main>
    );
  }

  const incident = detail.snapshot.case;
  const latestRun = [...detail.snapshot.resolution_runs].sort(
    (a, b) => b.generation - a.generation,
  )[0];
  const targetName = (id: string | null) =>
    id ? (detail.targets.find((target) => target.id === id)?.name ?? id) : t("cases.unresolved");
  const providerName = (id: string) => detail.providers.find((item) => item.id === id)?.name ?? id;
  const methodName = (id: string) => detail.methods.find((item) => item.id === id)?.name ?? id;

  async function lifecycle(action: "claim" | "cancel") {
    await mutate(action, () =>
      apiRequest(`/cases/${incident.id}/${action}`, {
        method: "POST",
        body: JSON.stringify({ case: { expected_revision: incident.revision } }),
      }),
    );
  }

  async function handoff(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const ownerId = formValue(new FormData(event.currentTarget), "owner_id");
    await mutate("handoff", () =>
      apiRequest(`/cases/${incident.id}/handoff`, {
        method: "POST",
        body: JSON.stringify({ case: { expected_revision: incident.revision, owner_id: ownerId } }),
      }),
    );
  }

  async function resume(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!latestRun) return;
    const form = new FormData(event.currentTarget);
    const integer = (name: string) => Number(formValue(form, name));
    await mutate("resume", () =>
      apiRequest(`/cases/${incident.id}/resume`, {
        method: "POST",
        body: JSON.stringify({
          case: {
            expected_case_revision: incident.revision,
            resolution_run_id: latestRun.id,
            expected_run_revision: latestRun.revision,
            authority_mode: formValue(form, "authority_mode"),
            max_elapsed_seconds: integer("max_elapsed_seconds"),
            max_resolver_turns: integer("max_resolver_turns"),
            max_target_requests: integer("max_target_requests"),
            max_effects: integer("max_effects"),
            max_related_targets: integer("max_related_targets"),
            max_ai_usage_units: integer("max_ai_usage_units"),
            max_no_progress_turns: integer("max_no_progress_turns"),
            reason: formValue(form, "reason"),
          },
        }),
      }),
    );
  }

  return (
    <main className="mx-auto w-full max-w-7xl space-y-8 p-6 lg:p-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
            <Link to="/cases">
              <ArrowLeft />
              {t("cases.back")}
            </Link>
          </Button>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-2xl font-semibold tracking-tight">{incident.title}</h1>
            <Badge variant={incident.status === "needs_attention" ? "destructive" : "secondary"}>
              {t(`cases.status.${incident.status}`)}
            </Badge>
            <Badge variant="outline">{t(`cases.severity.${incident.severity}`)}</Badge>
          </div>
          <p className="mt-2 font-mono text-xs text-muted-foreground">{incident.id}</p>
        </div>
        <Button variant="outline" disabled={pending !== null} onClick={() => void refresh()}>
          <RefreshCw />
          {t("cases.refresh")}
        </Button>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canOperate && (
        <Alert>
          <AlertDescription>{t("cases.readOnly")}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>{t("cases.currentState")}</CardTitle>
          <CardDescription>
            {incident.source} · {incident.source_ref}
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-5">
          <dl className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <Metric label={t("cases.target")} value={targetName(incident.selected_target_id)} />
            <Metric
              label={t("cases.alertState")}
              value={t(`cases.alert.${incident.alert_state}`)}
            />
            <Metric
              label={t("cases.authority")}
              value={t(`setup.modes.${incident.authority_mode}.name`)}
            />
            <Metric
              label={t("cases.owner")}
              value={
                detail.accounts.find((item) => item.id === incident.current_owner_id)?.email ??
                incident.current_owner_id ??
                t("cases.unclaimed")
              }
            />
          </dl>
          {incident.selected_target_id === null && (
            <Alert>
              <AlertDescription>{t("cases.targetPending")}</AlertDescription>
            </Alert>
          )}
          {incident.required_human_input && (
            <Alert variant="destructive">
              <AlertDescription>{incident.required_human_input}</AlertDescription>
            </Alert>
          )}
          {incident.stop_reason && (
            <p className="text-sm text-muted-foreground">{incident.stop_reason}</p>
          )}
          {canOperate && incident.status !== "resolved" && incident.status !== "cancelled" && (
            <div className="flex flex-wrap gap-2">
              <Button size="sm" disabled={pending !== null} onClick={() => void lifecycle("claim")}>
                {pending === "claim" && <Spinner />}
                {t("cases.claim")}
              </Button>
              <Button
                size="sm"
                variant="destructive"
                disabled={pending !== null || incident.cancel_requested}
                onClick={() => void lifecycle("cancel")}
              >
                {pending === "cancel" && <Spinner />}
                {t("cases.cancel")}
              </Button>
            </div>
          )}
          {account?.role === "admin" && detail.accounts.length > 0 && (
            <form className="flex flex-wrap items-end gap-3" onSubmit={handoff}>
              <div className="min-w-64 space-y-2">
                <Label htmlFor="handoff-owner">{t("cases.handoffTo")}</Label>
                <select
                  id="handoff-owner"
                  name="owner_id"
                  className={selectClass}
                  defaultValue={incident.current_owner_id ?? account.id}
                >
                  {detail.accounts
                    .filter((item) => item.role !== "viewer")
                    .map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.email}
                      </option>
                    ))}
                </select>
              </div>
              <Button type="submit" size="sm" disabled={pending !== null}>
                {t("cases.handoff")}
              </Button>
            </form>
          )}
        </CardContent>
      </Card>

      {incident.status === "needs_attention" && latestRun && canOperate && (
        <ResumeCard
          incident={incident}
          run={latestRun}
          pending={pending === "resume"}
          onSubmit={resume}
        />
      )}

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">{t("cases.resolution")}</h2>
        <div className="grid gap-4 xl:grid-cols-2">
          {detail.snapshot.resolution_runs.map((run) => (
            <Card key={run.id}>
              <CardHeader>
                <div className="flex items-center justify-between gap-2">
                  <CardTitle>{t("cases.runGeneration", { generation: run.generation })}</CardTitle>
                  <Badge variant={run.active ? "default" : "secondary"}>
                    {t(`cases.runStatus.${run.status}`)}
                  </Badge>
                </div>
                <CardDescription>
                  {formatDate(run.started_at, i18n.resolvedLanguage)} ·{" "}
                  {t(`setup.modes.${run.authority_mode}.name`)}
                </CardDescription>
              </CardHeader>
              <CardContent>
                <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
                  {Object.entries(run.counters).map(([key, value]) => (
                    <Metric key={key} label={t(`cases.counters.${key}`)} value={String(value)} />
                  ))}
                </dl>
              </CardContent>
            </Card>
          ))}
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">{t("cases.proposals")}</h2>
        <div className="space-y-4">
          {detail.snapshot.proposals.map((proposal) => (
            <ProposalCard
              key={proposal.id}
              proposal={proposal}
              target={targetName(proposal.target_id)}
              method={methodName(proposal.access_method_id)}
              provider={providerName(proposal.provider_id)}
              canOperate={canOperate}
              pending={pending}
              decide={(decision, reason) =>
                mutate(`proposal-${proposal.id}`, () =>
                  apiRequest(`/proposals/${proposal.id}/decision`, {
                    method: "POST",
                    body: JSON.stringify({
                      proposal: {
                        expected_revision: proposal.revision,
                        proposal_digest: proposal.proposal_digest,
                        decision,
                        reason,
                      },
                    }),
                  }),
                )
              }
            />
          ))}
          {detail.snapshot.proposals.length === 0 && <Empty>{t("cases.noProposals")}</Empty>}
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-xl font-semibold">{t("cases.effectsAndVerification")}</h2>
        <div className="space-y-4">
          {detail.snapshot.operations.map((operation) => {
            const attempt = detail.snapshot.verification_attempts.find(
              (item) => item.operation_id === operation.id,
            );
            return (
              <Card key={operation.id}>
                <CardHeader>
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <CardTitle>
                      {operation.capability} / {operation.operation}
                    </CardTitle>
                    <Badge variant="secondary">{operation.status}</Badge>
                  </div>
                  <CardDescription>
                    {targetName(operation.target_id)} · {methodName(operation.access_method_id)}
                  </CardDescription>
                </CardHeader>
                <CardContent className="grid gap-5 lg:grid-cols-2">
                  <DataBlock
                    title={t("cases.effectRequest")}
                    value={{ selectors: operation.selectors, parameters: operation.parameters }}
                  />
                  <DataBlock
                    title={t("cases.effectResult")}
                    value={{
                      category: operation.outcome_category,
                      reference: operation.reference,
                      details: operation.result_details,
                    }}
                  />
                  {attempt && (
                    <>
                      <DataBlock
                        title={`${t("cases.verification")} · ${attempt.status}`}
                        value={{
                          capability: attempt.capability,
                          operation: attempt.operation,
                          selectors: attempt.selectors,
                          parameters: attempt.parameters,
                          expected: attempt.expected,
                        }}
                      />
                      <DataBlock
                        title={t("cases.verificationResult")}
                        value={{
                          category: attempt.outcome_category,
                          facts: attempt.facts,
                          evidence: attempt.provider_evidence,
                          observed_at: attempt.observed_at,
                        }}
                      />
                    </>
                  )}
                </CardContent>
              </Card>
            );
          })}
          {detail.snapshot.operations.length === 0 && <Empty>{t("cases.noEffects")}</Empty>}
        </div>
      </section>

      <section className="grid gap-6 xl:grid-cols-2">
        <RecordCard title={t("cases.turns")} empty={t("cases.noTurns")}>
          {detail.turns.map((turn) => (
            <HistoryRow
              key={turn.id}
              title={`#${turn.ordinal} · ${turn.status}`}
              subtitle={turn.progress_kind ?? undefined}
            >
              <DataBlock
                value={{
                  intent: turn.intent,
                  outcome: turn.outcome,
                  decision: turn.decision,
                  failure_category: turn.failure_category,
                  failure_message: turn.failure_message,
                }}
              />
            </HistoryRow>
          ))}
        </RecordCard>
        <RecordCard title={t("cases.evidence")} empty={t("cases.noEvidence")}>
          {detail.evidence.map((item) => (
            <HistoryRow
              key={item.id}
              title={`${item.kind} · ${item.source}`}
              subtitle={`${item.source_ref} · ${formatDate(item.observed_at, i18n.resolvedLanguage)}`}
            >
              <DataBlock value={item.content} />
            </HistoryRow>
          ))}
        </RecordCard>
        <RecordCard title={t("cases.authorityOutcomes")} empty={t("cases.noAuthorityOutcomes")}>
          {detail.approvals.map((item) => (
            <HistoryRow
              key={item.id}
              title={`${item.source} · ${item.decision}`}
              subtitle={item.reason}
            />
          ))}
          {detail.reviews.map((item) => (
            <HistoryRow
              key={item.id}
              title={`Reviewer · ${item.verdict}`}
              subtitle={`${item.selection_source} · ${item.reason}`}
            />
          ))}
        </RecordCard>
        <RecordCard title={t("cases.timeline")} empty={t("cases.noTimeline")}>
          {detail.timeline.map((item) => (
            <HistoryRow
              key={item.id}
              title={item.type}
              subtitle={formatDate(item.inserted_at, i18n.resolvedLanguage)}
            />
          ))}
        </RecordCard>
      </section>
    </main>
  );
}

const selectClass =
  "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";

function formValue(form: FormData, name: string) {
  const value = form.get(name);
  return typeof value === "string" ? value : "";
}

function ProposalCard({
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
  return (
    <Card>
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
            {proposal.status}
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
            <AlertDescription>{proposal.preflight_reason}</AlertDescription>
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
            <div className="flex gap-2">
              <Button
                size="sm"
                disabled={!reason || pending !== null}
                onClick={() => void decide("approved", reason)}
              >
                {pending === `proposal-${proposal.id}` && <Spinner />}
                {t("cases.approve")}
              </Button>
              <Button
                size="sm"
                variant="destructive"
                disabled={!reason || pending !== null}
                onClick={() => void decide("rejected", reason)}
              >
                {t("cases.reject")}
              </Button>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function ResumeCard({
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
    <Card>
      <CardHeader>
        <CardTitle>{t("cases.resumeTitle")}</CardTitle>
        <CardDescription>{t("cases.resumeDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="space-y-4" onSubmit={(event) => void onSubmit(event)}>
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <div className="space-y-2">
              <Label htmlFor="resume-mode">{t("cases.authority")}</Label>
              <select
                id="resume-mode"
                name="authority_mode"
                className={selectClass}
                defaultValue={incident.authority_mode}
              >
                {["readonly", "ask", "auto", "full_access"].map((mode) => (
                  <option key={mode} value={mode}>
                    {t(`setup.modes.${mode}.name`)}
                  </option>
                ))}
              </select>
            </div>
            {Object.entries(run.limits).map(([name, value]) => (
              <NumberField key={name} name={name} label={t(`cases.limit.${name}`)} value={value} />
            ))}
          </div>
          <div className="space-y-2">
            <Label htmlFor="resume-reason">{t("cases.resumeReason")}</Label>
            <Textarea id="resume-reason" name="reason" required maxLength={1000} />
          </div>
          <Button type="submit" disabled={pending}>
            {pending && <Spinner />}
            {t("cases.resume")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

function NumberField({ name, label, value }: { name: string; label: string; value: number }) {
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
function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words">{value}</dd>
    </div>
  );
}
function DataBlock({ title, value }: { title?: string; value: unknown }) {
  return (
    <div className="min-w-0">
      {title && <p className="mb-2 text-xs font-medium text-muted-foreground">{title}</p>}
      <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 font-mono text-xs">
        {JSON.stringify(value, null, 2)}
      </pre>
    </div>
  );
}
function Empty({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-lg border bg-card p-6 text-center text-sm text-muted-foreground">
      {children}
    </div>
  );
}
function RecordCard({
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
function HistoryRow({
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
function formatDate(value: string, locale = "en") {
  return new Intl.DateTimeFormat(locale, { dateStyle: "medium", timeStyle: "short" }).format(
    new Date(value),
  );
}
