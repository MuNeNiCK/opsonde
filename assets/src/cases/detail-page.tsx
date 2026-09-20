import { useCallback, useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, CircleAlert, RefreshCw, ShieldCheck, Wrench } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import type { Account } from "@/auth/context";
import { useAuthentication } from "@/auth/context";
import {
  ContextCard,
  DataBlock,
  Empty,
  HistoryRow,
  Metric,
  PrimaryAction,
  ProposalCard,
  RecordCard,
  ResumeCard,
  StateIcon,
} from "@/cases/detail-components";
import {
  describeSituation,
  formatDate,
  formValue,
  parseAuthorityMode,
  translatedToken,
} from "@/cases/detail-utils";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { FormSelect } from "@/components/form-select";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
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
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const [confirmCancellation, setConfirmCancellation] = useState(false);
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const caseStatus = detail?.snapshot.case.status;

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
    if (!caseStatus || ["resolved", "cancelled"].includes(caseStatus)) return;
    const timer = window.setInterval(() => void refresh().catch(() => undefined), 5_000);
    return () => window.clearInterval(timer);
  }, [caseStatus, refresh]);

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
  const accessMethods = detail.methods
    .filter((method) => method.target_id === incident.selected_target_id && method.active)
    .sort((left, right) => left.priority - right.priority);
  const situation = describeSituation(incident, awaitingProposal, t);
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

      <Card className="overflow-hidden">
        <CardContent className="grid gap-6 p-5 lg:grid-cols-[minmax(0,1fr)_18rem] lg:p-6">
          <div className="space-y-5">
            <div className="flex items-start gap-3">
              <StateIcon state={incident.status} />
              <div>
                <p className="text-sm font-medium text-muted-foreground">
                  {t("cases.whatHappened")}
                </p>
                <p className="mt-1 text-lg font-semibold">{situation.happened}</p>
                <p className="mt-2 text-sm text-muted-foreground">{situation.doing}</p>
              </div>
            </div>
            {situation.blocker && (
              <Alert variant={incident.status === "needs_attention" ? "destructive" : "default"}>
                <CircleAlert />
                <AlertDescription>
                  <p>{situation.blocker}</p>
                  {situation.blockerDiagnostic && (
                    <details className="mt-2 text-xs">
                      <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                      <p className="mt-1">{situation.blockerDiagnostic}</p>
                    </details>
                  )}
                </AlertDescription>
              </Alert>
            )}
          </div>
          <div className="space-y-3 rounded-lg border bg-muted/35 p-4">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
              {t("cases.nextAction")}
            </p>
            <p className="text-sm font-medium">{situation.action}</p>
            <PrimaryAction
              incident={incident}
              awaitingProposal={awaitingProposal}
              canOperate={canOperate}
              pending={pending}
              claim={() => void lifecycle("claim")}
            />
          </div>
        </CardContent>
      </Card>

      <section className="grid gap-4 lg:grid-cols-3">
        <ContextCard title={t("cases.affectedTarget")} icon={<Wrench />}>
          <p className="font-medium">{selectedTarget?.name ?? t("cases.unresolved")}</p>
          {selectedTarget ? (
            <p className="mt-1 text-sm text-muted-foreground">
              {selectedTarget.kind} · {selectedTarget.platform}
            </p>
          ) : (
            <p className="mt-1 text-sm text-muted-foreground">{t("cases.targetPending")}</p>
          )}
        </ContextCard>
        <ContextCard title={t("cases.accessPaths")} icon={<ShieldCheck />}>
          {accessMethods.length > 0 ? (
            <div className="space-y-2">
              {accessMethods.map((method, index) => (
                <div key={method.id} className="text-sm">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{method.name}</span>
                    {index === 0 && <Badge variant="outline">{t("cases.preferred")}</Badge>}
                  </div>
                  <p className="break-all text-muted-foreground">
                    {method.method} · {method.endpoint}
                  </p>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">{t("cases.noAccessPaths")}</p>
          )}
        </ContextCard>
        <ContextCard title={t("cases.caseControl")} icon={<ShieldCheck />}>
          <dl className="grid grid-cols-2 gap-3 text-sm">
            <Metric
              label={t("cases.owner")}
              value={
                detail.accounts.find((item) => item.id === incident.current_owner_id)?.email ??
                (incident.current_owner_id === null
                  ? t("cases.unclaimed")
                  : incident.current_owner_id === account?.id
                    ? t("cases.ownerYou")
                    : t("cases.ownerAssigned"))
              }
            />
            <Metric
              label={t("cases.alertState")}
              value={t("cases.alert." + incident.alert_state)}
            />
            <Metric
              label={t("cases.authority")}
              value={t("setup.modes." + incident.authority_mode + ".name")}
            />
            <Metric
              label={t("cases.generation")}
              value={latestRun ? String(latestRun.generation) : t("cases.notStarted")}
            />
          </dl>
        </ContextCard>
      </section>

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
                  apiClient.POST("/api/v1/proposals/{id}/decision", {
                    params: { path: { id: proposal.id } },
                    body: {
                      proposal: {
                        expected_revision: proposal.revision,
                        proposal_digest: proposal.proposal_digest,
                        decision,
                        reason,
                      },
                    },
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
                    <Badge variant="secondary">
                      {translatedToken(t, "operationStatus", operation.status)}
                    </Badge>
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
          {[...detail.turns].reverse().map((turn) => (
            <HistoryRow
              key={turn.id}
              title={t("cases.turnTitle", { ordinal: turn.ordinal })}
              subtitle={translatedToken(t, "progress", turn.progress_kind ?? turn.status)}
            >
              {turn.failure_message && (
                <p className="text-sm text-destructive">
                  {translatedToken(t, "failure", turn.failure_category ?? "failed")}
                </p>
              )}
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
          {[...detail.evidence].reverse().map((item) => (
            <HistoryRow
              key={item.id}
              title={translatedToken(t, "evidenceKind", item.kind) + " · " + item.source}
              subtitle={`${item.source_ref} · ${formatDate(item.observed_at, i18n.resolvedLanguage)}`}
            >
              <DataBlock value={item.content} />
            </HistoryRow>
          ))}
        </RecordCard>
        <RecordCard title={t("cases.authorityOutcomes")} empty={t("cases.noAuthorityOutcomes")}>
          {[...detail.approvals].reverse().map((item) => (
            <HistoryRow
              key={item.id}
              title={
                translatedToken(t, "decisionSource", item.source) +
                " · " +
                translatedToken(t, "decision", item.decision)
              }
              subtitle={item.reason}
            />
          ))}
          {[...detail.reviews].reverse().map((item) => (
            <HistoryRow
              key={item.id}
              title={t("cases.reviewer") + " · " + translatedToken(t, "decision", item.verdict)}
              subtitle={`${item.selection_source} · ${item.reason}`}
            />
          ))}
        </RecordCard>
        <RecordCard title={t("cases.timeline")} empty={t("cases.noTimeline")}>
          {[...detail.timeline].reverse().map((item) => (
            <HistoryRow
              key={item.id}
              title={translatedToken(t, "event", item.type)}
              subtitle={formatDate(item.inserted_at, i18n.resolvedLanguage)}
            />
          ))}
        </RecordCard>
      </section>

      {canOperate && !["resolved", "cancelled"].includes(incident.status) && (
        <details className="rounded-lg border bg-card p-4">
          <summary className="cursor-pointer font-medium">{t("cases.caseControls")}</summary>
          <div className="mt-4 space-y-5">
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

      <details className="rounded-lg border bg-card p-4">
        <summary className="cursor-pointer text-sm font-medium">
          {t("cases.caseDiagnostics")}
        </summary>
        <p className="mt-3 font-mono text-xs text-muted-foreground">{incident.id}</p>
        <pre className="mt-3 max-h-80 overflow-auto whitespace-pre-wrap break-words rounded-md bg-muted p-3 font-mono text-xs">
          {JSON.stringify(detail.snapshot, null, 2)}
        </pre>
      </details>
    </div>
  );
}
