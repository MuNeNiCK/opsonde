import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  apiRequest,
  authenticationExpiredEvent,
  clearStoredToken,
  storeToken,
  storedToken,
} from "@/api";
import { AuthenticationContext, type Account } from "@/auth-context";

type SessionResponse = { data: { account: Account } };
type SignInResponse = { data: { token: string; account: Account } };

export function AuthenticationProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [loading, setLoading] = useState(Boolean(storedToken()));

  useEffect(() => {
    const expire = () => {
      setAccount(null);
      setLoading(false);
    };

    window.addEventListener(authenticationExpiredEvent, expire);
    return () => window.removeEventListener(authenticationExpiredEvent, expire);
  }, []);

  useEffect(() => {
    if (!storedToken()) return;

    let active = true;
    apiRequest<SessionResponse>("/session")
      .then(({ data }) => {
        if (active) setAccount(data.account);
      })
      .catch(() => {
        if (active) setAccount(null);
      })
      .finally(() => {
        if (active) setLoading(false);
      });

    return () => {
      active = false;
    };
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    const { data } = await apiRequest<SignInResponse>("/sessions", {
      method: "POST",
      body: JSON.stringify({ session: { email, password } }),
    });
    storeToken(data.token);
    setAccount(data.account);
  }, []);

  const bootstrap = useCallback(
    async (email: string, password: string, confirmation: string) => {
      await apiRequest("/accounts/bootstrap", {
        method: "POST",
        body: JSON.stringify({
          account: { email, password, password_confirmation: confirmation },
        }),
      });
      await signIn(email, password);
    },
    [signIn],
  );

  const signOut = useCallback(async () => {
    try {
      await apiRequest<void>("/session", { method: "DELETE" });
    } finally {
      clearStoredToken();
      setAccount(null);
    }
  }, []);

  const value = useMemo(
    () => ({ account, loading, bootstrap, signIn, signOut }),
    [account, bootstrap, loading, signIn, signOut],
  );

  return <AuthenticationContext.Provider value={value}>{children}</AuthenticationContext.Provider>;
}
