import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";

export type AIUsageRoleAssignment = components["schemas"]["AIUsageRoleAssignment"];
export type AuthoritySetting = components["schemas"]["AuthoritySetting"];
export type Provider = components["schemas"]["Provider"];
export type Target = components["schemas"]["Target"];
export type AccessMethod = components["schemas"]["AccessMethod"];

export type SettingsSnapshot = {
  providers: Provider[];
  assignments: AIUsageRoleAssignment[];
  authority: AuthoritySetting;
  targets: Target[];
  methods: AccessMethod[];
};

export async function loadSettingsSnapshot(): Promise<SettingsSnapshot> {
  const [providers, assignments, authority, targets, methods] = await Promise.all([
    collectPages((after) =>
      apiClient
        .GET("/api/v1/providers", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    ),
    collectPages((after) =>
      apiClient
        .GET("/api/v1/ai-usage-role-assignments", {
          params: { query: { limit: 100, after: after ?? undefined } },
        })
        .then(apiData),
    ),
    apiClient.GET("/api/v1/authority-setting").then(apiData),
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
  ]);
  return { providers, assignments, authority: authority.data, targets, methods };
}

export type Readiness = {
  ai: boolean;
  resolver: boolean;
  reviewer: boolean;
  authority: boolean;
  signal: boolean;
  target: boolean;
  complete: boolean;
};

export function readiness(snapshot: SettingsSnapshot): Readiness {
  const checkedProviders = new Set(
    snapshot.providers
      .filter(
        (provider) =>
          provider.enabled &&
          provider.check.status === "passed" &&
          provider.check.checked_revision === provider.revision,
      )
      .map((provider) => provider.id),
  );
  const aiIds = new Set(
    snapshot.providers
      .filter((provider) => provider.kind === "ai" && checkedProviders.has(provider.id))
      .map((provider) => provider.id),
  );
  const activeTargetIds = new Set(
    snapshot.targets.filter((target) => target.active).map((target) => target.id),
  );
  const ai = aiIds.size > 0;
  const resolver = snapshot.assignments.some(
    (assignment) =>
      assignment.role === "resolver" && assignment.enabled && aiIds.has(assignment.provider_id),
  );
  const reviewer = snapshot.assignments.some(
    (assignment) =>
      assignment.role === "reviewer" && assignment.enabled && aiIds.has(assignment.provider_id),
  );
  const authority =
    snapshot.authority.changed_by_id !== null &&
    (snapshot.authority.authority_mode !== "auto" || reviewer);
  const signal = snapshot.providers.some(
    (provider) => provider.kind === "signal" && checkedProviders.has(provider.id),
  );
  const target = snapshot.methods.some(
    (method) =>
      method.active &&
      activeTargetIds.has(method.target_id) &&
      checkedProviders.has(method.provider_id),
  );
  return {
    ai,
    resolver,
    reviewer,
    authority,
    signal,
    target,
    complete: ai && resolver && authority && signal && target,
  };
}
