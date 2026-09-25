import type { components } from "@/api/schema";
import "@/reports/report.css";

type Report = components["schemas"]["Report"];

const copy = {
  ja: {
    kind: "CASE 対応レポート",
    result: "対応結果",
    resolved: "解決済み",
    needs_attention: "対応が必要",
    cancelled: "中止済み",
    opened: "受付",
    finished: "終了",
    issued: "発行",
    target: "対象 ID",
    source: "検知元",
    severity: "重要度",
    condition: "確認された状態",
    actions: "実施した操作",
    verification: "復旧確認",
    assessment: "Resolver の判断",
    outstanding: "残る事項",
    evidence: "証拠",
    observed: "観測",
    record: "記録",
    noCondition: "確認された状態の記録はありません。",
    noActions: "実施した操作の記録はありません。",
    noVerification: "復旧確認の記録はありません。",
    noAssessment: "判断の記録はありません。",
    noOutstanding: "未解決事項の記録はありません。確認範囲は上記の証拠を参照してください。",
    noDetail: "詳細の記録なし",
    provenance: "記録の出典",
    revision: "Case revision",
    digest: "内容の SHA-256",
    status: "状態",
    outcome: "結果分類",
    statuses: {
      queued: "待機中",
      dispatching: "実行中",
      applied: "適用済み",
      failed: "失敗",
      partial: "一部適用",
      unknown: "結果不明",
      verified: "確認済み",
      not_verified: "未確認",
    },
  },
  en: {
    kind: "CASE RESPONSE REPORT",
    result: "Outcome",
    resolved: "Resolved",
    needs_attention: "Needs attention",
    cancelled: "Cancelled",
    opened: "Opened",
    finished: "Finished",
    issued: "Issued",
    target: "Target ID",
    source: "Source",
    severity: "Severity",
    condition: "Observed condition",
    actions: "Actions taken",
    verification: "Recovery checks",
    assessment: "Resolver assessment",
    outstanding: "Outstanding items",
    evidence: "Evidence",
    observed: "Observed",
    record: "Record",
    noCondition: "No confirmed condition was recorded.",
    noActions: "No actions were recorded.",
    noVerification: "No recovery check was recorded.",
    noAssessment: "No assessment was recorded.",
    noOutstanding:
      "No outstanding items were recorded. See the evidence above for the scope of verification.",
    noDetail: "No detail recorded",
    provenance: "Record provenance",
    revision: "Case revision",
    digest: "Content SHA-256",
    status: "Status",
    outcome: "Outcome category",
    statuses: {
      queued: "Queued",
      dispatching: "In progress",
      applied: "Applied",
      failed: "Failed",
      partial: "Partial",
      unknown: "Unknown",
      verified: "Verified",
      not_verified: "Not verified",
    },
  },
} as const;

function date(value: string | null, locale: "ja" | "en") {
  if (!value) return "—";
  return new Intl.DateTimeFormat(locale === "ja" ? "ja-JP" : "en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "UTC",
    timeZoneName: "short",
  }).format(new Date(value));
}

function status(value: string, locale: "ja" | "en") {
  const labels: Record<string, string> = copy[locale].statuses;
  return labels[value] ?? value;
}

export function CaseReportDocument({ report }: { report: Report }) {
  const document = report.document;
  const locale = report.language;
  const c = copy[locale];
  const outcome = report.outcome;
  const accent =
    outcome === "resolved"
      ? "report-outcome-resolved"
      : outcome === "needs_attention"
        ? "report-outcome-attention"
        : "report-outcome-cancelled";

  return (
    <article className="report-sheet" lang={locale} aria-label={c.kind}>
      <header className="report-masthead">
        <div className="report-brand">
          <span className="report-brand-mark" /> OPSONDE{" "}
          <span className="report-kind">/ {c.kind}</span>
        </div>
        <div className="report-issued">
          {c.issued} · {date(report.generated_at, locale)}
        </div>
      </header>

      <div className="report-heading">
        <p className="report-eyebrow">{c.result}</p>
        <h1>{document.title}</h1>
        <div className={`report-outcome ${accent}`}>
          <strong>{c[outcome]}</strong>
          <span>
            {c.opened} {date(document.opened_at, locale)} → {c.finished}{" "}
            {date(document.finished_at, locale)}
          </span>
        </div>
      </div>

      <dl className="report-facts">
        <div>
          <dt>{c.target}</dt>
          <dd>{document.target_id ?? "—"}</dd>
        </div>
        <div>
          <dt>{c.source}</dt>
          <dd>
            {document.source}
            {document.source_ref ? ` / ${document.source_ref}` : ""}
          </dd>
        </div>
        <div>
          <dt>{c.severity}</dt>
          <dd>{document.severity}</dd>
        </div>
        <div>
          <dt>{c.revision}</dt>
          <dd>{document.case_revision}</dd>
        </div>
      </dl>

      <div className="report-body">
        <section className="report-section">
          <h2>
            <span>01</span>
            {c.condition}
          </h2>
          <p className="report-prose">{document.condition?.text ?? c.noCondition}</p>
          {document.condition && (
            <p className="report-ref">
              {c.evidence} · {document.condition.evidence_id}
            </p>
          )}
        </section>

        <section className="report-section">
          <h2>
            <span>02</span>
            {c.actions}
          </h2>
          {document.actions.length ? (
            <ol className="report-list">
              {document.actions.map((action) => (
                <li key={action.id}>
                  <div className="report-list-head">
                    <strong>{action.name}</strong>
                    <span>{date(action.completed_at, locale)}</span>
                  </div>
                  <p>
                    {c.status}: {status(action.status, locale)}
                  </p>
                  {action.detail && <p>{action.detail}</p>}
                  {action.outcome_category && (
                    <small>
                      {c.outcome} · {action.outcome_category}
                    </small>
                  )}
                  <small>
                    {c.record} · {action.id}
                  </small>
                </li>
              ))}
            </ol>
          ) : (
            <p className="report-prose">{c.noActions}</p>
          )}
        </section>

        <section className="report-section">
          <h2>
            <span>03</span>
            {c.verification}
          </h2>
          {document.verifications.length ? (
            <ol className="report-list">
              {document.verifications.map((item) => (
                <li key={item.id}>
                  <div className="report-list-head">
                    <strong>{status(item.status, locale)}</strong>
                    <span>{date(item.observed_at, locale)}</span>
                  </div>
                  <p>{item.facts ?? c.noDetail}</p>
                  {item.outcome_category && (
                    <small>
                      {c.outcome} · {item.outcome_category}
                    </small>
                  )}
                  <small>
                    {c.record} · {item.id}
                  </small>
                </li>
              ))}
            </ol>
          ) : (
            <p className="report-prose">{c.noVerification}</p>
          )}
          {document.recovery_observation && (
            <div className="report-observation">
              <strong>
                {c.observed} · {date(document.recovery_observation.observed_at, locale)}
              </strong>
              <p>{document.recovery_observation.facts}</p>
              <small>
                {c.evidence} · {document.recovery_observation.evidence_id}
              </small>
            </div>
          )}
        </section>

        <section className="report-section">
          <h2>
            <span>04</span>
            {c.assessment}
          </h2>
          <p className="report-prose">{document.conclusion ?? c.noAssessment}</p>
          {document.conclusion_turn_id && (
            <p className="report-ref">
              {c.record} · {document.conclusion_turn_id}
            </p>
          )}
        </section>

        <section className={`report-section ${outcome === "resolved" ? "" : "report-outstanding"}`}>
          <h2>
            <span>05</span>
            {c.outstanding}
          </h2>
          <p className="report-prose">
            {document.required_human_input ?? document.stop_reason ?? c.noOutstanding}
          </p>
          {document.required_human_input &&
            document.stop_reason &&
            document.required_human_input !== document.stop_reason && (
              <p className="report-prose">{document.stop_reason}</p>
            )}
        </section>
      </div>

      <footer className="report-footer">
        <strong>{c.provenance}</strong>
        <span>
          Case {document.case_id} · r{document.case_revision}
        </span>
        <span>
          {c.digest}: {report.content_digest}
        </span>
      </footer>
    </article>
  );
}
