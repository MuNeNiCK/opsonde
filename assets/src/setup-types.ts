export type Provider = {
  id: string;
  name: string;
  kind: "ai" | "signal" | "target" | "inventory" | "notification";
  adapter_type: string;
  configuration: Record<string, unknown>;
  revision: number;
  enabled: boolean;
  check: {
    status: "passed" | "failed" | null;
    category: string | null;
    message: string | null;
    checked_revision: number | null;
    checked_at: string | null;
  };
};

export type AIUsageRoleAssignment = {
  id: string;
  provider_id: string;
  role: "resolver" | "reviewer";
  priority: number;
  enabled: boolean;
  revision: number;
};

export type AuthoritySetting = {
  id: string;
  authority_mode: "readonly" | "ask" | "auto" | "full_access";
  signal_automation_enabled: boolean;
  max_elapsed_seconds: number;
  max_resolver_turns: number;
  max_target_requests: number;
  max_effects: number;
  max_related_targets: number;
  max_ai_usage_units: number;
  max_no_progress_turns: number;
  setting_revision: number;
  reason: string;
};
