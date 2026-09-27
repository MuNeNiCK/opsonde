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
import { ApiError, apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import type { Account } from "@/auth/context";
import { useAuthentication } from "@/auth/context";
import { ProposalCard, ResumeCard } from "@/cases/detail-components";
import { subscribeToCase } from "@/cases/realtime";
import { formatDate, formValue, parseAuthorityMode, translatedToken } from "@/cases/detail-utils";
import { CaseWorkflowView } from "@/cases/workflow-view";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { FormSelect } from "@/components/form-select";
import { Input } from "@/components/ui/input";
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
  const { t, i18n } = useTranslation();
  const { account } = useAuthentication();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState<string | null>(null);
  const [confirmCancellation, setConfirmCancellation] = useState(false);
  const [showProgress, setShowProgress] = useState(false);
  const [selectedConditions, setSelectedConditions] = useState<string[]>([]);
  const [splitReason, setSplitReason] = useState("");
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
    } catch (failure) {
      setError(
        failure instanceof ApiError && failure.status === 409
          ? t("cases.stateChanged")
          : t("cases.requestFailed"),
      );
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
  const conditionName = (condition: CaseSnapshot["conditions"][number]) => {
    const first = detail.evidence.find(
      (entry) =>
        entry.kind === "signal_event" &&
        entry.content["condition_id"] === condition.id &&
        entry.content["state"] === "firing",
    );
    const attributes = first?.content["attributes"] as Record<string, unknown> | undefined;
    return typeof attributes?.title === "string" ? attributes.title : condition.predicate;
  };
  const currentConditionRevisions = JSON.stringify(
    detail.snapshot.conditions
      .map((condition) => ({ id: condition.id, revision: condition.revision }))
      .sort((a, b) => a.id.localeCompare(b.id)),
  );
  const latestGroupTurn = [...detail.turns]
    .filter(
      (turn) =>
        turn.condition_groups !== null &&
        turn.condition_revisions !== null &&
        JSON.stringify([...turn.condition_revisions].sort((a, b) => a.id.localeCompare(b.id))) ===
          currentConditionRevisions,
    )
    .sort((a, b) => (b.completed_at ?? "").localeCompare(a.completed_at ?? ""))[0];
  const conditionHypotheses =
    latestGroupTurn?.condition_groups?.filter((group) => group.assessment !== "unknown") ?? [];
  const latestAssessmentTurn = [...detail.turns]
    .filter(
      (turn) =>
        turn.condition_assessments !== null &&
        turn.condition_assessments.length > 0 &&
        turn.condition_revisions !== null &&
        JSON.stringify([...turn.condition_revisions].sort((a, b) => a.id.localeCompare(b.id))) ===
          currentConditionRevisions,
    )
    .sort((a, b) => (b.completed_at ?? "").localeCompare(a.completed_at ?? ""))[0];
  const selectedInCase = selectedConditions.filter((id) =>
    detail.snapshot.conditions.some((item) => item.id === id),
  );
  const detachedConditions = detail.snapshot.condition_history
    .filter((membership) => membership.detached_at !== null)
    .sort((a, b) => (b.detached_at ?? "").localeCompare(a.detached_at ?? ""));
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

  async function splitConditions(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!detail) return;
    const current = detail.snapshot.conditions;
    const selected = selectedConditions.filter((id) => current.some((item) => item.id === id));
    if (selected.length === 0 || selected.length >= current.length || !splitReason.trim()) return;

    await mutate("split", async () => {
      apiData(
        await apiClient.POST("/api/v1/cases/{id}/split", {
          params: { path: { id: incident.id } },
          body: {
            case: {
              expected_revision: incident.revision,
              condition_ids: selected,
              expected_conditions: current.map((item) => ({
                id: item.id,
                revision: item.revision,
              })),
              reason: splitReason.trim(),
            },
          },
        }),
      );
      setSelectedConditions([]);
      setSplitReason("");
    });
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
      targets={detail.targets}
      methods={detail.methods}
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
            <Badge
              variant={
                incident.operator_action === "intervention_required" ? "destructive" : "secondary"
              }
            >
              {incident.operator_action === "none"
                ? t(`cases.status.${incident.status}`)
                : t(`cases.operatorAction.${incident.operator_action}`)}
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

      {incident.case_symptom && (
        <Card>
          <CardContent className="space-y-4 p-5">
            <h2 className="text-lg font-semibold">{t("cases.manualRequest")}</h2>
            <div>
              <p className="text-xs text-muted-foreground">{t("cases.desiredOutcome")}</p>
              <p className="text-sm font-medium">{incident.case_symptom.desired_outcome}</p>
            </div>
            <div>
              <p className="text-xs text-muted-foreground">{t("cases.observedProblem")}</p>
              <p className="text-sm">{incident.case_symptom.text}</p>
            </div>
            <p className="font-mono text-xs text-muted-foreground">{incident.case_symptom.id}</p>
          </CardContent>
        </Card>
      )}

      {detail.timeline.some((event) => event.type === "recovery_review_decided") && (
        <Card>
          <CardContent className="space-y-3 p-5">
            <h2 className="text-lg font-semibold">{t("cases.recoveryReviews")}</h2>
            <ul className="space-y-3">
              {detail.timeline
                .filter((event) => event.type === "recovery_review_decided")
                .map((event) => (
                  <li key={event.id} className="rounded-lg border p-3">
                    <Badge
                      variant={event.review_verdict === "rejected" ? "destructive" : "outline"}
                    >
                      {t(`cases.recoveryReviewStatus.${event.review_verdict}`)}
                    </Badge>
                    <p className="mt-2 text-sm">{event.review_reason}</p>
                    {event.review_desired_outcome_assessment && (
                      <div className="mt-2 space-y-1 text-sm">
                        <Badge variant="outline">
                          {t(
                            `cases.desiredOutcomeReviewStatus.${event.review_desired_outcome_assessment.status}`,
                          )}
                        </Badge>
                        <p className="font-medium">
                          {event.review_desired_outcome_assessment.desired_outcome}
                        </p>
                        <p>{event.review_desired_outcome_assessment.reason}</p>
                        <p className="text-xs text-muted-foreground">
                          {t("cases.recoveryReviewEvidence")}:{" "}
                          {event.review_desired_outcome_assessment.evidence_ids.join(", ")}
                        </p>
                      </div>
                    )}
                    <p className="mt-2 text-xs text-muted-foreground">
                      {t("cases.recoveryReviewEvidence")}: {event.review_evidence_ids.join(", ")}
                    </p>
                    <p className="mt-1 font-mono text-xs text-muted-foreground">
                      {event.id} · {event.review_source_turn_id}
                    </p>
                  </li>
                ))}
            </ul>
          </CardContent>
        </Card>
      )}

      {incident.trigger_kind === "signal" && (
        <Card>
          <CardContent className="space-y-4 p-5">
            <div>
              <h2 className="text-lg font-semibold">{t("cases.conditionsTitle")}</h2>
              <p className="text-sm text-muted-foreground">
                {t("cases.conditionsDescription", { count: detail.snapshot.conditions.length })}
              </p>
            </div>
            {incident.split_parent_id && (
              <Link
                className="text-sm text-primary underline"
                to={`/cases/${incident.split_parent_id}`}
              >
                {t("cases.parentCase")}
              </Link>
            )}
            <div className="flex flex-wrap gap-2">
              {detail.timeline
                .filter(
                  (event) => event.type === "case_conditions_split_out" && event.related_case_id,
                )
                .map((event) => (
                  <Link
                    key={event.id}
                    className="text-sm text-primary underline"
                    to={`/cases/${event.related_case_id}`}
                  >
                    {t("cases.childCase")}
                  </Link>
                ))}
            </div>
            {latestGroupTurn && detail.snapshot.conditions.length > 1 && (
              <div className="space-y-2 rounded-lg border bg-muted/30 p-3">
                <h3 className="text-sm font-semibold">{t("cases.conditionHypotheses")}</h3>
                <p className="text-xs text-muted-foreground">
                  {t("cases.conditionHypothesesDescription")}
                </p>
                {conditionHypotheses.length === 0 ? (
                  <p className="text-sm">{t("cases.conditionHypothesesUnknown")}</p>
                ) : (
                  <ul className="space-y-2">
                    {conditionHypotheses.map((group, index) => (
                      <li key={`${group.condition_ids.join(":")}-${index}`} className="text-sm">
                        <Badge variant="outline">
                          {t(`cases.conditionGroupAssessment.${group.assessment}`)}
                        </Badge>{" "}
                        {group.condition_ids
                          .map((id) => {
                            const condition = detail.snapshot.conditions.find(
                              (item) => item.id === id,
                            );
                            return condition ? conditionName(condition) : id;
                          })
                          .join(", ")}
                        {group.reason && (
                          <p className="mt-1 text-xs text-muted-foreground">{group.reason}</p>
                        )}
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}
            <ul className="divide-y rounded-lg border">
              {detail.snapshot.conditions.map((item) => {
                const name = conditionName(item);
                const assessment = latestAssessmentTurn?.condition_assessments?.find(
                  (entry) => entry.condition_id === item.id && entry.revision === item.revision,
                );
                return (
                  <li key={item.id} className="flex flex-wrap items-start gap-3 p-3">
                    {canOperate &&
                      incident.status === "running" &&
                      detail.snapshot.conditions.length > 1 && (
                        <input
                          type="checkbox"
                          aria-label={t("cases.selectCondition", { name })}
                          checked={selectedConditions.includes(item.id)}
                          onChange={(event) =>
                            setSelectedConditions((current) =>
                              event.target.checked
                                ? [...current, item.id]
                                : current.filter((id) => id !== item.id),
                            )
                          }
                        />
                      )}
                    <div className="min-w-0 flex-1 space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="font-medium">{name}</span>
                        <Badge variant={item.state === "firing" ? "destructive" : "outline"}>
                          {t(`cases.alert.${item.state}`)}
                        </Badge>
                        <Badge variant="outline">
                          {t(`cases.conditionRecovery.${item.recovery_status}`)}
                        </Badge>
                      </div>
                      <p className="text-xs text-muted-foreground">{item.predicate}</p>
                      {assessment && (
                        <div className="space-y-1 text-xs">
                          <p className="flex flex-wrap items-center gap-2">
                            <Badge variant="outline">
                              {t(`cases.aiConditionAssessment.${assessment.status}`)}
                            </Badge>
                            <span>{assessment.reason}</span>
                          </p>
                          <p className="text-muted-foreground">
                            {t("cases.aiConditionAssessmentTurn", {
                              ordinal: latestAssessmentTurn.ordinal,
                            })}
                          </p>
                          {assessment.evidence_ids.length > 0 && (
                            <details className="text-muted-foreground">
                              <summary>{t("cases.aiConditionAssessmentEvidence")}</summary>
                              <ul className="mt-1 space-y-1 font-mono">
                                {assessment.evidence_ids.map((id) => (
                                  <li key={id}>{id}</li>
                                ))}
                              </ul>
                            </details>
                          )}
                        </div>
                      )}
                      <p className="font-mono text-xs text-muted-foreground">{item.id}</p>
                    </div>
                  </li>
                );
              })}
            </ul>
            {detachedConditions.length > 0 && (
              <div className="space-y-2">
                <h3 className="text-sm font-semibold">{t("cases.pastConditionsTitle")}</h3>
                <ul className="divide-y rounded-lg border">
                  {detachedConditions.map((membership) => (
                    <li key={membership.id} className="space-y-1 p-3">
                      <p className="font-mono text-xs">{membership.condition_id}</p>
                      <p className="text-xs text-muted-foreground">
                        {t("cases.pastConditionDetachedAt")}:{" "}
                        {membership.detached_at &&
                          formatDate(membership.detached_at, i18n.resolvedLanguage)}
                      </p>
                    </li>
                  ))}
                </ul>
              </div>
            )}
            {canOperate &&
              incident.status === "running" &&
              detail.snapshot.conditions.length > 1 && (
                <form
                  className="flex flex-wrap items-end gap-3"
                  onSubmit={(event) => void splitConditions(event)}
                >
                  <div className="min-w-56 flex-1 space-y-1">
                    <Label htmlFor="case-split-reason">{t("cases.splitReason")}</Label>
                    <Input
                      id="case-split-reason"
                      value={splitReason}
                      maxLength={500}
                      onChange={(event) => setSplitReason(event.target.value)}
                    />
                  </div>
                  <Button
                    type="submit"
                    variant="outline"
                    disabled={
                      pending !== null ||
                      selectedInCase.length === 0 ||
                      selectedInCase.length >= detail.snapshot.conditions.length ||
                      !splitReason.trim()
                    }
                  >
                    {t("cases.splitConditions")}
                  </Button>
                </form>
              )}
          </CardContent>
        </Card>
      )}

      {complete ? (
        <>
          <CompletedCaseSummary
            conditions={detail.snapshot.conditions}
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
                conditions={detail.snapshot.conditions}
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
  conditions,
  report,
  targetName,
  verificationCount,
  progressVisible,
  onToggleProgress,
}: {
  conditions: CaseSnapshot["conditions"];
  report: Report;
  targetName: string;
  verificationCount: number;
  progressVisible: boolean;
  onToggleProgress: () => void;
}) {
  const { t, i18n } = useTranslation();
  const document = report.document;
  const appliedActions = document.actions.filter((action) => action.status === "applied");
  const visibleOperations = appliedActions.slice(0, 3);
  const additionalOperations = appliedActions.slice(3);

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
            {document.conditions.length > 0 ? (
              <ul className="space-y-2">
                {document.conditions.map((condition) => (
                  <li key={condition.id} className="text-sm leading-relaxed">
                    <span className="font-medium">{condition.symptom}</span>
                    <span className="ml-2 text-xs text-muted-foreground">
                      {t(`cases.alert.${condition.source_state}`)}
                    </span>
                    {condition.assessment && (
                      <p className="text-xs text-muted-foreground">{condition.assessment}</p>
                    )}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm leading-relaxed text-muted-foreground">
                {t("cases.completionSummary.causeUnavailable")}
              </p>
            )}
          </section>

          <section className="space-y-3 border-t p-4 lg:border-t-0">
            <div className="flex items-center gap-2 text-sm font-semibold">
              <Wrench className="size-4 text-muted-foreground" aria-hidden="true" />
              <h3>{t("cases.completionSummary.actions")}</h3>
            </div>
            {appliedActions.length > 0 ? (
              <div className="space-y-3">
                <ul className="space-y-3">
                  {visibleOperations.map((operation) => (
                    <RemediationItem key={operation.id} operation={operation} />
                  ))}
                </ul>
                {additionalOperations.length > 0 && (
                  <details>
                    <summary className="cursor-pointer text-xs font-medium text-muted-foreground hover:text-foreground">
                      {t("cases.completionSummary.moreActions", {
                        count: additionalOperations.length,
                      })}
                    </summary>
                    <ul className="mt-3 space-y-3 border-l pl-3">
                      {additionalOperations.map((operation) => (
                        <RemediationItem key={operation.id} operation={operation} />
                      ))}
                    </ul>
                  </details>
                )}
              </div>
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
            <p className="text-xs font-medium text-muted-foreground">
              {t("cases.completionSummary.resolverAssessment")}
            </p>
            <p className="text-sm leading-relaxed">
              {document.conclusion ?? t("cases.completionSummary.conclusionUnavailable")}
            </p>
            {document.verifications.length > 0 && (
              <ul className="space-y-1 text-xs text-muted-foreground">
                {document.verifications.map((verification) => (
                  <li key={verification.id}>
                    {verification.status
                      ? translatedToken(t, "verificationStatus", verification.status)
                      : t("cases.completionSummary.verified")}
                    {verification.facts ? ` · ${verification.facts}` : ""}
                  </li>
                ))}
              </ul>
            )}
            {document.cited_evidence.length > 0 && (
              <ul className="space-y-1 text-xs text-muted-foreground">
                {document.cited_evidence.map((item) => (
                  <li key={item.id}>
                    {item.facts ?? item.kind} · {item.id}
                  </li>
                ))}
              </ul>
            )}
            {conditions.length > 0 && (
              <p className="text-xs font-medium text-emerald-700 dark:text-emerald-400">
                {t("cases.completionSummary.monitoringState", {
                  state: conditions
                    .map((condition) => t(`cases.alert.${condition.state}`))
                    .join(", "),
                })}
              </p>
            )}
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

function RemediationItem({ operation }: { operation: Report["document"]["actions"][number] }) {
  const { t } = useTranslation();
  return (
    <li>
      <div className="flex flex-wrap items-center gap-2">
        <p className="text-sm font-medium">{operation.name}</p>
        {operation.status && (
          <Badge variant="secondary">
            {translatedToken(t, "operationStatus", operation.status)}
          </Badge>
        )}
      </div>
    </li>
  );
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
