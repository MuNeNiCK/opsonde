import { createContext, useContext } from "react";

export type Account = {
  id: string;
  email: string;
  role: "admin" | "operator" | "viewer";
  role_version: number;
};

export type Authentication = {
  account: Account | null;
  loading: boolean;
  oidcEnabled: boolean;
  bootstrap: (email: string, password: string, confirmation: string) => Promise<void>;
  signIn: (email: string, password: string) => Promise<void>;
  signInWithOIDC: () => Promise<void>;
  linkOIDC: () => Promise<void>;
  signOut: () => Promise<void>;
};

export const AuthenticationContext = createContext<Authentication | null>(null);

export function useAuthentication() {
  const context = useContext(AuthenticationContext);
  if (!context) throw new Error("AuthenticationProvider is missing");
  return context;
}
