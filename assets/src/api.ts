const tokenKey = "opsonde.session";
export const authenticationExpiredEvent = "opsonde:authentication-expired";

type ErrorBody = {
  error?: { code?: string; message?: string; request_id?: string };
};

export type DataResponse<T> = { data: T };
export type PageResponse<T> = { data: T[]; page: { next: string | null } };

export class ApiError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly requestId?: string;

  constructor(status: number, body: ErrorBody) {
    super(body.error?.message ?? `Request failed (${status})`);
    this.name = "ApiError";
    this.status = status;
    this.code = body.error?.code;
    this.requestId = body.error?.request_id;
  }
}

export function storedToken() {
  return sessionStorage.getItem(tokenKey);
}

export function storeToken(token: string) {
  sessionStorage.setItem(tokenKey, token);
}

export function clearStoredToken() {
  sessionStorage.removeItem(tokenKey);
}

export async function apiRequest<T>(path: string, init: RequestInit = {}) {
  const token = storedToken();
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");

  if (init.body) headers.set("Content-Type", "application/json");
  if (token) headers.set("Authorization", `Bearer ${token}`);

  const response = await fetch(`/api/v1${path}`, { ...init, headers });

  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as ErrorBody;

    if (response.status === 401 && token) {
      clearStoredToken();
      window.dispatchEvent(new Event(authenticationExpiredEvent));
    }

    throw new ApiError(response.status, body);
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export async function apiCollection<T>(path: string) {
  const records: T[] = [];
  let cursor: string | null = null;

  do {
    const separator = path.includes("?") ? "&" : "?";
    const suffix = cursor ? `&after=${encodeURIComponent(cursor)}` : "";
    const response: PageResponse<T> = await apiRequest(`${path}${separator}limit=100${suffix}`);
    records.push(...response.data);
    cursor = response.page.next;
  } while (cursor);

  return records;
}
