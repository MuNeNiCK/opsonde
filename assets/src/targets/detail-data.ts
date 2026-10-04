import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";

export async function loadDetailHeader(id: string, signal: AbortSignal) {
  const [target, catalog] = await Promise.all([
    apiClient
      .GET("/api/v1/targets/{id}", { params: { path: { id } }, signal })
      .then(apiData)
      .then((result) => result.data),
    apiClient
      .GET("/api/v1/target-types", { signal })
      .then(apiData)
      .then((result) => result.data),
  ]);
  signal.throwIfAborted();
  const boundary = target.management_boundary_id
    ? await apiClient
        .GET("/api/v1/management-boundaries/{id}", {
          params: { path: { id: target.management_boundary_id } },
          signal,
        })
        .then(apiData)
        .then((result) => ({ id: result.data.id, name: result.data.name }))
    : null;
  return { target, catalog, boundary };
}

export async function loadDetailMethods(
  targetId: string,
  after: string | undefined,
  signal: AbortSignal,
) {
  const page = await apiClient
    .GET("/api/v1/access-methods", {
      params: { query: { target_id: targetId, active: true, limit: 50, after } },
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  const ids = [...new Set(page.data.map((item) => item.provider_id))];
  const providers = ids.length
    ? await apiClient
        .GET("/api/v1/providers/references", {
          params: { query: { ids, limit: 100 } },
          querySerializer: commaSeparatedQuery,
          signal,
        })
        .then(apiData)
        .then((result) => result.data)
    : [];
  return {
    ...page,
    data: page.data.map((method) => ({
      method,
      provider: providers.find((item) => item.id === method.provider_id),
    })),
  };
}

export async function loadDetailRelationships(
  targetId: string,
  after: string | undefined,
  signal: AbortSignal,
) {
  const page = await apiClient
    .GET("/api/v1/target-relationships", {
      params: { query: { target_id: targetId, active: true, limit: 50, after } },
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  const ids = [
    ...new Set(
      page.data.map((item) =>
        item.source_target_id === targetId ? item.destination_target_id : item.source_target_id,
      ),
    ),
  ];
  const targets = ids.length
    ? await apiClient
        .GET("/api/v1/targets/references", {
          params: { query: { ids, limit: 100 } },
          querySerializer: commaSeparatedQuery,
          signal,
        })
        .then(apiData)
        .then((result) => result.data)
    : [];
  return {
    ...page,
    data: page.data.map((relationship) => ({
      relationship,
      peer: targets.find(
        (item) =>
          item.id ===
          (relationship.source_target_id === targetId
            ? relationship.destination_target_id
            : relationship.source_target_id),
      ),
    })),
  };
}
