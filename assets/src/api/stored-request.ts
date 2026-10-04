export function readStoredRequest<T>(key: string, decode: (value: unknown) => T) {
  try {
    const stored = sessionStorage.getItem(key);
    return { intent: stored ? decode(JSON.parse(stored)) : null, unreadable: false };
  } catch {
    return { intent: null as T | null, unreadable: true };
  }
}

export function clearStoredRequest(key: string, intent: unknown) {
  if (sessionStorage.getItem(key) !== JSON.stringify(intent)) return false;
  sessionStorage.removeItem(key);
  return true;
}
