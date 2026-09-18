import type { Provider } from "@/setup-types";

export type ManagementBoundary = {
  id: string;
  name: string;
  kind: string;
  facts: Record<string, unknown>;
  active: boolean;
  revision: number;
};

export type Target = {
  id: string;
  name: string;
  kind: string;
  platform: string;
  facts: Record<string, unknown>;
  management_boundary_id: string | null;
  active: boolean;
  revision: number;
};

export type ExternalIdentity = {
  id: string;
  target_id: string;
  source: string;
  kind: string;
  value: string;
  active: boolean;
  revision: number;
};

export type AccessMethod = {
  id: string;
  target_id: string;
  provider_id: string;
  name: string;
  platform: string;
  method: string;
  endpoint: string;
  provider_revision: number;
  priority: number;
  capabilities: string[];
  active: boolean;
  revision: number;
};

export type TargetRelationship = {
  id: string;
  source_target_id: string;
  destination_target_id: string;
  kind: string;
  facts: Record<string, unknown>;
  valid_until: string | null;
  active: boolean;
  revision: number;
};

export type TargetPolicy = {
  id: string;
  target_id: string;
  name: string;
  request_kinds: Array<"observation" | "effect">;
  capabilities: string[];
  operations: string[];
  selector_match: Record<string, unknown>;
  parameter_match: Record<string, unknown>;
  reason: string;
  enabled: boolean;
  revision: number;
};

export type InventoryImport = {
  id: string;
  source_type: "manual" | "inventory";
  source: string;
  status: "previewed" | "applied" | "rejected";
  snapshot_status: string | null;
  source_version: string | null;
  content_digest: string;
  row_count: number;
  error_count: number;
  provider_id: string | null;
  revision: number;
  applied_at: string | null;
};

export type InventoryImportRow = {
  id: string;
  position: number;
  disposition: string;
  identity_value: string;
  candidate: Record<string, unknown>;
  errors: string[];
  target_id: string | null;
};

export type TargetOperation = {
  capability: string;
  operation: string;
  description: string;
  input_schema: Record<string, unknown>;
};

export type TargetCapabilities = {
  observations: TargetOperation[];
  effects: TargetOperation[];
};

export type TargetSnapshot = {
  providers: Provider[];
  boundaries: ManagementBoundary[];
  targets: Target[];
  identities: ExternalIdentity[];
  methods: AccessMethod[];
  relationships: TargetRelationship[];
  policies: TargetPolicy[];
  imports: InventoryImport[];
};
