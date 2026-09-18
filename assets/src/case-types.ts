export type AuthorityMode = "readonly" | "ask" | "auto" | "full_access";

export type ResolutionLimits = {
  max_elapsed_seconds: number;
  max_resolver_turns: number;
  max_target_requests: number;
  max_effects: number;
  max_related_targets: number;
  max_ai_usage_units: number;
  max_no_progress_turns: number;
};

export type CaseRecord = {
  id: string;
  trigger_kind: "manual" | "signal" | "audit";
  source: string;
  source_ref: string;
  title: string;
  severity: "info" | "warning" | "error" | "critical";
  alert_state: "firing" | "recovered" | "not_applicable";
  report_language: "en" | "ja";
  status: "running" | "needs_attention" | "resolved" | "cancelled";
  initial_context: Record<string, unknown>;
  authority_mode: AuthorityMode;
  limits: ResolutionLimits;
  cancel_requested: boolean;
  stop_reason: string | null;
  required_human_input: string | null;
  source_recovered_at: string | null;
  initial_target_id: string | null;
  selected_target_id: string | null;
  selected_target_revision: number | null;
  current_owner_id: string | null;
  revision: number;
  inserted_at: string;
  updated_at: string;
};

export type ResolutionRun = {
  id: string;
  case_id: string;
  generation: number;
  active: boolean;
  status: "running" | "needs_attention" | "completed" | "cancelled" | "superseded";
  authority_mode: AuthorityMode;
  limits: ResolutionLimits;
  counters: {
    resolver_turns: number;
    target_requests: number;
    effects: number;
    related_targets: number;
    ai_usage_units: number;
    no_progress_turns: number;
  };
  started_at: string;
  deadline_at: string;
  ended_at: string | null;
  resume_reason: string | null;
  resumed_by_id: string | null;
  revision: number;
};

export type Proposal = {
  id: string;
  case_id: string;
  resolution_run_id: string;
  source_turn_id: string;
  target_id: string;
  access_method_id: string;
  provider_id: string;
  status:
    | "proposed"
    | "blocked"
    | "recommended"
    | "awaiting_human"
    | "reviewing"
    | "authorized"
    | "rejected"
    | "invalidated";
  authority_mode: AuthorityMode;
  case_generation: number;
  tool_id: string;
  capability: string;
  operation: string;
  selectors: Record<string, unknown>;
  parameters: Record<string, unknown>;
  reason: string;
  evidence_ids: string[];
  expected_result: Record<string, unknown>;
  verification_intent: Record<string, unknown>;
  verification_tool: Record<string, unknown>;
  preflight_status: "cleared" | "blocked" | null;
  preflight_reason: string | null;
  proposal_digest: string;
  expires_at: string;
  revision: number;
  inserted_at: string;
  updated_at: string;
};

export type Operation = {
  id: string;
  proposal_id: string;
  target_id: string;
  access_method_id: string;
  provider_id: string;
  status: "queued" | "dispatching" | "applied" | "failed" | "partial" | "unknown";
  authority_mode: Exclude<AuthorityMode, "readonly">;
  capability: string;
  operation: string;
  selectors: Record<string, unknown>;
  parameters: Record<string, unknown>;
  dispatch_started_at: string | null;
  outcome_category: string | null;
  reference: string | null;
  result_details: Record<string, unknown>;
  accepted_at: string;
  completed_at: string | null;
  revision: number;
};

export type VerificationAttempt = {
  id: string;
  operation_id: string;
  proposal_id: string;
  target_id: string;
  access_method_id: string;
  provider_id: string;
  status: "queued" | "dispatching" | "verified" | "not_verified" | "unknown";
  authority_mode: Exclude<AuthorityMode, "readonly">;
  tool_id: string;
  capability: string;
  operation: string;
  selectors: Record<string, unknown>;
  parameters: Record<string, unknown>;
  expected: Record<string, unknown>;
  operation_reference: string | null;
  outcome_category: string | null;
  facts: Record<string, unknown>;
  provider_evidence: Record<string, unknown>;
  observed_at: string | null;
  completed_at: string | null;
  revision: number;
};

export type CaseSnapshot = {
  case: CaseRecord;
  resolution_runs: ResolutionRun[];
  proposals: Proposal[];
  operations: Operation[];
  verification_attempts: VerificationAttempt[];
};

export type CaseEvent = {
  id: string;
  resolution_run_id: string | null;
  actor_id: string | null;
  type: string;
  inserted_at: string;
};

export type Turn = {
  id: string;
  resolution_run_id: string;
  ordinal: number;
  status: "started" | "completed";
  intent: Record<string, unknown>;
  outcome: unknown;
  decision: unknown;
  failure_category: string | null;
  failure_message: string | null;
  progress_kind: string | null;
  started_at: string;
  completed_at: string | null;
};

export type Evidence = {
  id: string;
  resolution_run_id: string;
  turn_id: string | null;
  kind: string;
  source: string;
  source_ref: string;
  content: Record<string, unknown>;
  observed_at: string;
};

export type Approval = {
  id: string;
  proposal_id: string;
  actor_id: string | null;
  decision: "approved" | "rejected";
  source: "human" | "full_access" | "reviewer";
  reason: string;
  decided_at: string;
};

export type ReviewDecision = {
  id: string;
  proposal_id: string;
  provider_id: string;
  outcome: "decision" | "delivery_failed";
  verdict: "approved" | "rejected" | "needs_human";
  category: string;
  reason: string;
  selection_source: "assignment" | "resolver_fallback";
  decided_at: string;
};

export type SignalReceipt = {
  id: string;
  provider_id: string;
  provider_revision: number;
  receipt_id: string;
  source: string;
  received_at: string;
  event_count: number;
};

export type SignalEvent = {
  id: string;
  signal_receipt_id: string;
  event_key: string;
  state: "firing" | "recovered";
  source_sequence: string | null;
  occurred_at: string;
  target_ref: Record<string, unknown> | null;
  case_id: string | null;
  target_id: string | null;
};
