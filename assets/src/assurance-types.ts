export type AuditSchedule = {
  id: string;
  name: string;
  objective: string;
  timezone: string;
  cron_expression: string;
  report_language: "en" | "ja";
  target_ids: string[];
  management_boundary_id: string | null;
  active: boolean;
  next_run_at: string;
  revision: number;
  inserted_at: string;
  updated_at: string;
};

export type AuditRun = {
  id: string;
  audit_schedule_id: string;
  schedule_revision: number;
  target_key: string;
  target_id: string | null;
  target_revision: number | null;
  case_id: string | null;
  case_revision: number | null;
  scheduled_for: string;
  status: "queued" | "running" | "case_opened" | "skipped" | "cancelled" | "failed";
  reason: string | null;
  started_at: string | null;
  completed_at: string | null;
  revision: number;
};

export type Report = {
  id: string;
  case_id: string;
  case_revision: number;
  language: "en" | "ja";
  outcome: "resolved" | "needs_attention" | "cancelled";
  content: Record<string, unknown>;
  content_digest: string;
  generated_at: string;
  revision: number;
};

export type Delivery = {
  id: string;
  report_id: string;
  report_revision: number;
  provider_id: string;
  provider_revision: number;
  destination_id: string;
  destination_revision: number;
  status: "queued" | "dispatching" | "accepted" | "delivered" | "failed" | "unknown";
  reference: string | null;
  details: Record<string, unknown>;
  enqueued_at: string;
  dispatch_started_at: string | null;
  completed_at: string | null;
  revision: number;
};
