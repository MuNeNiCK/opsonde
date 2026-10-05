import { apiClient, apiData } from "@/api/client";
import type { components } from "@/api/schema";

export type SetupReadiness = components["schemas"]["SetupReadiness"];

export function loadSetupReadiness(signal?: AbortSignal) {
  return apiClient
    .GET("/api/v1/authority-setting/readiness", { signal })
    .then(apiData)
    .then((response) => response.data);
}
