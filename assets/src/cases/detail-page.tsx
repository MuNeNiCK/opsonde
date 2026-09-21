import { useCallback, useEffect, useState, type FormEvent } from "react";
import {
  ArrowLeft,
  CheckCircle2,
  CircleAlert,
  History,
  RefreshCw,
  Search,
  ShieldCheck,
  Wrench,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import type { Account } from "@/auth/context";
import { useAuthentication } from "@/auth/context";
import { ProposalCard, ResumeCard } from "@/cases/detail-components";
import { subscribeToCase } from "@/cases/realtime";
import {
  formatDate,
  formValue,
  parseAuthorityMode,
  summarizeValue,
  translatedToken,
} from "@/cases/detail-utils";
import { CaseWorkflowView } from "@/cases/workflow-view";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { FormSelect } from "@/components/form-select";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Separator } from "@/components/ui/separator";
import { Spinner } from "@/components/ui/spinner";

type Approval = components["schemas"]["Approval"];
type CaseEvent = components["schemas"]["CaseEvent"];
type CaseSnapshot = components["schemas"]["CaseSnapshot"];
type Evidence = components["schemas"]["Evidence"];
type ReviewDecision = components["schemas"]["ReviewDecision"];
type Turn = components["schemas"]["ResolverTurn"];
type Provider = components["schemas"]["Provider"];
type AccessMethod = components["schemas"]["AccessMethod"];
type Target = components["schemas"]["Target"];

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

type CaseState = Pick<
  Detail,
  "snapshot" | "timeline" | "turns" | "evidence" | "approvals" | "reviews"
>;
type References = Pick<Detail, "targets" | "methods" | "providers" | "accounts">;

async function loadCaseState(caseId: string): Promise<CaseState> {
  const [snapshotResponse, timeline, turns, evidence, approvals, reviews] = await Promise.all([
    apiClient.GET("/api/v1/cases/{id}", { params: { path: { id: caseId } } }).then(apiData),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases/{id}/timeline", {
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases/{id}/turns", {
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases/{id}/evidence", {
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases/{id}/approvals", {
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/cases/{id}/review-decisions", {
          params: { path: { id: caseId }, query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
  ]);
  return { snapshot: snapshotResponse.data, timeline, turns, evidence, approvals, reviews };
}

async function loadReferences(includeAccounts: boolean): Promise<References> {
  const [targets, methods, providers, accounts] = await Promise.all([
    collectPages((after) =>
      apiClient
        .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/access-methods", {
          params: { query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/providers", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    includeAccounts
      ? collectPages((after) =>
          apiClient
            .GET("/api/v1/accounts", {
              params: { query: { limit: 100, after: after ?? undefined } },
            })
            .then(apiData),
        )
      : Promise.resolve([]),
  ]);
  return { targets, methods, providers, accounts };
}

async function loadDetail(caseId: string, includeAccounts: boolean): Promise<Detail> {
  const [state, references] = await Promise.all([
    loadCaseState(caseId),
    loadReferences(includeAccounts),
  ]);
  return { ...state, ...references };
}

export function CaseDetailPage() {
  const { caseId = "" } = useParams();
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const [confirmCancellation, setConfirmCancellation] = useState(false);
  const [showProgress, setShowProgress] = useState(false);
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const refresh = useCallback(async () => {
    if (!caseId) return;
    const state = await loadCaseState(caseId);
    setDetail((current) => (current ? { ...current, ...state } : current));
  }, [caseId]);

  useEffect(() => {
    let active = true;
    loadDetail(caseId, account?.role === "admin")
      .then((next) => active && setDetail(next))
      .catch(() => {
        if (active) setError(t("cases.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [account?.role, caseId, t]);

  useEffect(() => {
    let active = true;
    let refreshing = false;
    let queued = false;

    const changed = () => {
      if (!active) return;
      if (refreshing) {
        queued = true;
        return;
      }

      refreshing = true;
      void (async () => {
        do {
          queued = false;
          await refresh().catch(() => undefined);
        } while (active && queued);
        refreshing = false;
      })();
    };

    const unsubscribe = subscribeToCase(caseId, changed);
    return () => {
      active = false;
      unsubscribe();
    };
  }, [caseId, refresh]);

  async function mutate(key: string, action: () => Promise<unknown>) {
    setPending(key);
    setError("");
    try {
      await action();
      await refresh();
    } catch {
      setError(t("cases.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  if (!detail) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  const incident = detail.snapshot.case;
  const latestRun = [...detail.snapshot.resolution_runs].sort(
    (a, b) => b.generation - a.generation,
  )[0];
  const awaitingProposal = detail.snapshot.proposals.find(
    (proposal) => proposal.status === "awaiting_human",
  );
  const selectedTarget = detail.targets.find((target) => target.id === incident.selected_target_id);
  const exactReport = detail.snapshot.reports.find(
    (report) => report.case_revision === incident.revision,
  );
  const complete = incident.status === "resolved" && exactReport !== undefined;
  const targetName = (id: string | null) =>
    id ? (detail.targets.find((target) => target.id === id)?.name ?? id) : t("cases.unresolved");
  const providerName = (id: string) => detail.providers.find((item) => item.id === id)?.name ?? id;
  const methodName = (id: string) => detail.methods.find((item) => item.id === id)?.name ?? id;

  async function lifecycle(action: "claim" | "cancel") {
    const request = { case: { expected_revision: incident.revision } };
    await mutate(action, () =>
      action === "claim"
        ? apiClient.POST("/api/v1/cases/{id}/claim", {
            params: { path: { id: incident.id } },
            body: request,
          })
        : apiClient.POST("/api/v1/cases/{id}/cancel", {
            params: { path: { id: incident.id } },
            body: request,
          }),
    );
    if (action === "cancel") setConfirmCancellation(false);
  }

  async function handoff(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const ownerId = formValue(new FormData(event.currentTarget), "owner_id");
    await mutate("handoff", () =>
      apiClient.POST("/api/v1/cases/{id}/handoff", {
        params: { path: { id: incident.id } },
        body: { case: { expected_revision: incident.revision, owner_id: ownerId } },
      }),
    );
  }

  async function resume(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!latestRun) return;
    const form = new FormData(event.currentTarget);
    const integer = (name: string) => Number(formValue(form, name));
    await mutate("resume", () =>
      apiClient.POST("/api/v1/cases/{id}/resume", {
        params: { path: { id: incident.id } },
        body: {
          case: {
            expected_case_revision: incident.revision,
            resolution_run_id: latestRun.id,
            expected_run_revision: latestRun.revision,
            authority_mode: parseAuthorityMode(formValue(form, "authority_mode")),
            max_elapsed_seconds: integer("max_elapsed_seconds"),
            max_resolver_turns: integer("max_resolver_turns"),
            max_target_requests: integer("max_target_requests"),
            max_effects: integer("max_effects"),
            max_related_targets: integer("max_related_targets"),
            max_ai_usage_units: integer("max_ai_usage_units"),
            max_no_progress_turns: integer("max_no_progress_turns"),
            reason: formValue(form, "reason"),
          },
        },
      }),
    );
  }

  const workflow = (
    <CaseWorkflowView
      snapshot={detail.snapshot}
      timeline={detail.timeline}
      turns={detail.turns}
      evidence={detail.evidence}
      approvals={detail.approvals}
      reviews={detail.reviews}
      reports={detail.snapshot.reports}
    />
  );

  return (
    <div className="space-y-8 p-6 lg:p-8">
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
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canOperate && (
        <Alert>
          <AlertDescription>{t("cases.readOnly")}</AlertDescription>
        </Alert>
      )}

      {complete ? (
        <>
          <CompletedCaseSummary
            incident={incident}
            report={exactReport}
            targetName={selectedTarget?.name ?? t("cases.unresolved")}
            verificationCount={detail.snapshot.verification_attempts.length}
            progressVisible={showProgress}
            onToggleProgress={() => setShowProgress((visible) => !visible)}
          />
          {showProgress && workflow}
        </>
      ) : (
        <>
          {workflow}

          {awaitingProposal && (
            <section className="space-y-3" aria-labelledby="case-required-decision">
              <h2 id="case-required-decision" className="text-xl font-semibold">
                {t("cases.requiredDecision")}
              </h2>
              <ProposalCard
                proposal={awaitingProposal}
                target={targetName(awaitingProposal.target_id)}
                method={methodName(awaitingProposal.access_method_id)}
                provider={providerName(awaitingProposal.provider_id)}
                canOperate={canOperate}
                pending={pending}
                decide={(decision, reason) =>
                  mutate(`proposal-${awaitingProposal.id}`, () =>
                    apiClient.POST("/api/v1/proposals/{id}/decision", {
                      params: { path: { id: awaitingProposal.id } },
                      body: {
                        proposal: {
                          expected_revision: awaitingProposal.revision,
                          proposal_digest: awaitingProposal.proposal_digest,
                          decision,
                          reason,
                        },
                      },
                    }),
                  )
                }
              />
            </section>
          )}

          {incident.status === "needs_attention" && latestRun && canOperate && (
            <ResumeCard
              incident={incident}
              run={latestRun}
              pending={pending === "resume"}
              onSubmit={resume}
            />
          )}

          {canOperate && !["resolved", "cancelled"].includes(incident.status) && (
            <details className="rounded-lg border p-4">
              <summary className="cursor-pointer font-medium">{t("cases.caseControls")}</summary>
              <div className="mt-4 space-y-5">
                {incident.current_owner_id === null && (
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={pending !== null}
                    onClick={() => void lifecycle("claim")}
                  >
                    {pending === "claim" && <Spinner />}
                    {t("cases.claim")}
                  </Button>
                )}
                {account?.role === "admin" && detail.accounts.length > 0 && (
                  <form className="flex flex-wrap items-end gap-3" onSubmit={handoff}>
                    <div className="min-w-64 space-y-2">
                      <Label htmlFor="handoff-owner">{t("cases.handoffTo")}</Label>
                      <FormSelect
                        id="handoff-owner"
                        name="owner_id"
                        defaultValue={incident.current_owner_id ?? account.id}
                        options={detail.accounts
                          .filter((item) => item.role !== "viewer")
                          .map((item) => ({ value: item.id, label: item.email }))}
                      />
                    </div>
                    <Button type="submit" size="sm" variant="outline" disabled={pending !== null}>
                      {pending === "handoff" && <Spinner />}
                      {t("cases.handoff")}
                    </Button>
                  </form>
                )}
                <Separator />
                {!confirmCancellation ? (
                  <Button
                    size="sm"
                    variant="destructive"
                    disabled={pending !== null || incident.cancel_requested}
                    onClick={() => setConfirmCancellation(true)}
                  >
                    {t("cases.cancel")}
                  </Button>
                ) : (
                  <Alert variant="destructive">
                    <CircleAlert />
                    <AlertDescription>
                      <p>{t("cases.cancelConfirmation")}</p>
                      <div className="mt-2 flex flex-wrap gap-2">
                        <Button
                          size="sm"
                          variant="destructive"
                          disabled={pending !== null}
                          onClick={() => void lifecycle("cancel")}
                        >
                          {pending === "cancel" && <Spinner />}
                          {t("cases.confirmCancel")}
                        </Button>
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() => setConfirmCancellation(false)}
                        >
                          {t("common.cancel")}
                        </Button>
                      </div>
                    </AlertDescription>
                  </Alert>
                )}
              </div>
            </details>
          )}
        </>
      )}
    </div>
  );
}

type Report = CaseSnapshot["reports"][number];

function CompletedCaseSummary({
  incident,
  report,
  targetName,
  verificationCount,
  progressVisible,
  onToggleProgress,
}: {
  incident: CaseSnapshot["case"];
  report: Report;
  targetName: string;
  verificationCount: number;
  progressVisible: boolean;
  onToggleProgress: () => void;
}) {
  const { t, i18n } = useTranslation();
  const narrative = completedNarrative(report.content);

  return (
    <Card>
      <CardContent className="space-y-6 p-5 lg:p-6">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <span className="flex size-10 shrink-0 items-center justify-center rounded-full bg-emerald-500/12 text-emerald-600 dark:text-emerald-400">
              <CheckCircle2 className="size-5" aria-hidden="true" />
            </span>
            <div>
              <h2 className="text-xl font-semibold">{t("cases.completionSummary.title")}</h2>
              <p className="mt-1 text-sm text-muted-foreground">
                {t("cases.completionSummary.description")}
              </p>
            </div>
          </div>
          <Button variant="outline" size="sm" onClick={onToggleProgress}>
            <History />
            {t(
              progressVisible
                ? "cases.completionSummary.hideProgress"
                : "cases.completionSummary.showProgress",
            )}
          </Button>
        </div>

        <div className="grid overflow-hidden rounded-lg border lg:grid-cols-3 lg:divide-x">
          <section className="space-y-3 p-4">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Search className="size-4 text-muted-foreground" aria-hidden="true" />
              <h3>{t("cases.completionSummary.cause")}</h3>
            </div>
            <p className="text-sm leading-relaxed">
              {narrative.cause ?? t("cases.completionSummary.causeUnavailable")}
            </p>
          </section>

          <section className="space-y-3 border-t p-4 lg:border-t-0">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Wrench className="size-4 text-muted-foreground" aria-hidden="true" />
              <h3>{t("cases.completionSummary.actions")}</h3>
            </div>
            {narrative.operations.length > 0 ? (
              <ul className="space-y-3">
                {narrative.operations.map((operation, index) => (
                  <li key={`${operation.capability}-${operation.operation}-${index}`}>
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-sm font-medium">
                        {operation.capability} / {operation.operation}
                      </p>
                      {operation.status && (
                        <Badge variant="secondary">
                          {translatedToken(t, "operationStatus", operation.status)}
                        </Badge>
                      )}
                    </div>
                    {operation.input && (
                      <p className="mt-1 text-xs leading-relaxed text-muted-foreground">
                        {operation.input}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-muted-foreground">
                {t("cases.completionSummary.noRemediation")}
              </p>
            )}
          </section>

          <section className="space-y-3 border-t p-4 lg:border-t-0">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <ShieldCheck className="size-4 text-muted-foreground" aria-hidden="true" />
              <h3>{t("cases.completionSummary.recoveryEvidence")}</h3>
            </div>
            <p className="text-sm leading-relaxed">
              {narrative.conclusion ?? t("cases.completionSummary.conclusionUnavailable")}
            </p>
            {narrative.verifications.length > 0 && (
              <ul className="space-y-1 text-xs text-muted-foreground">
                {narrative.verifications.map((verification, index) => (
                  <li key={`${verification.status}-${index}`}>
                    {verification.status
                      ? translatedToken(t, "verificationStatus", verification.status)
                      : t("cases.completionSummary.verified")}
                    {verification.facts ? ` · ${verification.facts}` : ""}
                  </li>
                ))}
              </ul>
            )}
            <p className="text-xs font-medium text-emerald-700 dark:text-emerald-400">
              {t("cases.completionSummary.monitoringState", {
                state: t(`cases.alert.${incident.alert_state}`),
              })}
            </p>
          </section>
        </div>

        <dl className="grid gap-5 border-t pt-5 sm:grid-cols-3">
          <SummaryField label={t("cases.completionSummary.target")} value={targetName} />
          <SummaryField
            label={t("cases.completionSummary.verification")}
            value={t("cases.completionSummary.verificationCount", { count: verificationCount })}
          />
          <SummaryField
            label={t("cases.completionSummary.completedAt")}
            value={formatDate(report.generated_at, i18n.resolvedLanguage)}
            detail={t("cases.completionSummary.report")}
          />
        </dl>
      </CardContent>
    </Card>
  );
}

type SummaryRecord = Record<string, unknown>;

function completedNarrative(content: SummaryRecord) {
  const proposals = recordList(content.proposals);
  const operations = recordList(content.operations).map((operation) => ({
    capability: stringField(operation.capability) ?? "Operation",
    operation: stringField(operation.operation) ?? "unknown",
    status: stringField(operation.status),
    input: summarizeOperationInput(operation),
  }));
  const verifications = recordList(content.verifications).map((verification) => ({
    status: stringField(verification.status),
    facts: summarizeVerificationFacts(verification.facts),
  }));
  const recoveryTurn = recordList(content.resolver_turns)
    .map((turn) => objectField(turn.decision))
    .findLast((decision) => decision?.type === "recovery_conclusion");

  return {
    cause: proposals.map((proposal) => stringField(proposal.reason)).findLast(Boolean) ?? null,
    operations,
    verifications,
    conclusion: recoveryTurn ? stringField(recoveryTurn.reason) : null,
  };
}

function recordList(value: unknown): SummaryRecord[] {
  return Array.isArray(value)
    ? value.filter((item): item is SummaryRecord => typeof item === "object" && item !== null)
    : [];
}

function objectField(value: unknown): SummaryRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as SummaryRecord)
    : null;
}

function stringField(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function summarizeOperationInput(operation: SummaryRecord) {
  const selectors = objectField(operation.selectors);
  const parameters = objectField(operation.parameters);
  const input = {
    ...(selectors && Object.keys(selectors).length > 0 ? { selectors } : {}),
    ...(parameters && Object.keys(parameters).length > 0 ? { parameters } : {}),
  };

  return Object.keys(input).length > 0 ? summarizeValue(input, "") : null;
}

function summarizeVerificationFacts(value: unknown) {
  const facts = objectField(value);
  if (!facts) return null;
  const preferred = ["active_state", "sub_state", "status", "state", "health", "ready", "phase"];
  const selected = Object.fromEntries(
    preferred.filter((key) => facts[key] !== undefined).map((key) => [key, facts[key]]),
  );
  return summarizeValue(Object.keys(selected).length > 0 ? selected : facts, "");
}

function SummaryField({ label, value, detail }: { label: string; value: string; detail?: string }) {
  return (
    <div>
      <dt className="text-xs font-medium text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words text-sm font-medium">{value}</dd>
      {detail && <dd className="mt-1 text-xs text-muted-foreground">{detail}</dd>}
    </div>
  );
}
