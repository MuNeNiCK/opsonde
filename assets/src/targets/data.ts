import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";

export type Provider = components["schemas"]["Provider"];
export type ManagementBoundary = components["schemas"]["ManagementBoundary"];
export type Target = components["schemas"]["Target"];
export type ExternalIdentity = components["schemas"]["ExternalIdentity"];
export type AccessMethod = components["schemas"]["AccessMethod"];
export type TargetRelationship = components["schemas"]["TargetRelationship"];
export type TargetPolicy = components["schemas"]["TargetPolicy"];
export type InventoryImport = components["schemas"]["InventoryImport"];

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

export async function loadTargetSnapshot(): Promise<TargetSnapshot> {
  const [providers, boundaries, targets, identities, methods, relationships, policies, imports] =
    await Promise.all([
      collectPages((after) =>
        apiClient
          .GET("/api/v1/providers", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/management-boundaries", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/external-identities", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
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
          .GET("/api/v1/target-relationships", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/target-policies", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
      collectPages((after) =>
        apiClient
          .GET("/api/v1/inventory-imports", {
            params: { query: { limit: 100, after: after ?? undefined } },
          })
          .then(apiData),
      ),
    ]);
  return { providers, boundaries, targets, identities, methods, relationships, policies, imports };
}
