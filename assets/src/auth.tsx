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
type OIDCStatusResponse = { data: { enabled: boolean; authorization_url: string | null } };
type OIDCLinkResponse = { data: { authorization_url: string; expires_at: string } };

type OIDCMessage = {
  type: "opsonde:oidc-session" | "opsonde:oidc-linked" | "opsonde:oidc-error";
  token?: string;
  account?: Account;
};

function browserOIDC(path: string, successType: OIDCMessage["type"]) {
  return new Promise<{ token: string; account: Account }>((resolve, reject) => {
    const popup = window.open("about:blank", "opsonde-oidc", "popup,width=640,height=720");
    if (!popup) {
      reject(new Error("The browser blocked the OIDC sign-in window."));
      return;
    }

    let settled = false;

    const finish = (result: { token: string; account: Account } | Error) => {
      if (settled) return;
      settled = true;
      window.removeEventListener("message", receive);
      window.clearInterval(closed);
      window.clearTimeout(expired);
      popup.close();
      if (result instanceof Error) reject(result);
      else resolve(result);
    };

    const receive = (event: MessageEvent<unknown>) => {
      if (event.origin !== window.location.origin || event.source !== popup) return;
      const message = event.data as Partial<OIDCMessage>;

      if (message.type === successType && message.token && message.account) {
        finish({ token: message.token, account: message.account });
      } else if (message.type === "opsonde:oidc-error") {
        finish(new Error("OIDC authentication failed."));
      }
    };

    const closed = window.setInterval(() => {
      if (popup.closed) finish(new Error("The OIDC sign-in window was closed."));
    }, 500);
    const expired = window.setTimeout(
      () => finish(new Error("OIDC authentication timed out.")),
      10 * 60 * 1_000,
    );

    window.addEventListener("message", receive);
    popup.location.replace(path);
  });
}

export function AuthenticationProvider({ children }: { children: ReactNode }) {
  const [account, setAccount] = useState<Account | null>(null);
  const [loading, setLoading] = useState(Boolean(storedToken()));
  const [oidcStatus, setOIDCStatus] = useState<OIDCStatusResponse["data"]>({
    enabled: false,
    authorization_url: null,
  });

  useEffect(() => {
    const expire = () => {
      setAccount(null);
      setLoading(false);
    };

    window.addEventListener(authenticationExpiredEvent, expire);
    return () => window.removeEventListener(authenticationExpiredEvent, expire);
  }, []);

  useEffect(() => {
    apiRequest<OIDCStatusResponse>("/oidc")
      .then(({ data }) => setOIDCStatus(data))
      .catch(() => setOIDCStatus({ enabled: false, authorization_url: null }));
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

  const signInWithOIDC = useCallback(async () => {
    if (!oidcStatus.enabled || !oidcStatus.authorization_url) {
      throw new Error("OIDC authentication is not enabled.");
    }

    const result = await browserOIDC(oidcStatus.authorization_url, "opsonde:oidc-session");
    storeToken(result.token);
    setAccount(result.account);
  }, [oidcStatus]);

  const linkOIDC = useCallback(async () => {
    const { data } = await apiRequest<OIDCLinkResponse>("/oidc/link-requests", {
      method: "POST",
      body: JSON.stringify({}),
    });
    const result = await browserOIDC(data.authorization_url, "opsonde:oidc-linked");
    storeToken(result.token);
    setAccount(result.account);
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
    () => ({
      account,
      loading,
      oidcEnabled: oidcStatus.enabled,
      bootstrap,
      signIn,
      signInWithOIDC,
      linkOIDC,
      signOut,
    }),
    [account, bootstrap, linkOIDC, loading, oidcStatus.enabled, signIn, signInWithOIDC, signOut],
  );

  return <AuthenticationContext.Provider value={value}>{children}</AuthenticationContext.Provider>;
}
