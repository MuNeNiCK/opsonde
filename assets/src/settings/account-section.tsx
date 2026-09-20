import { useCallback, useEffect, useState, type FormEvent } from "react";
import { CheckCircle2, Plus, Save, Users } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";

type Account = components["schemas"]["Account"];
type Role = Account["role"];

const roles: Role[] = ["admin", "operator", "viewer"];

function selectClassName() {
  return "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35 disabled:cursor-not-allowed disabled:opacity-50";
}

export function AccountSection({ currentAccountId }: { currentAccountId: string }) {
  const { t } = useTranslation();
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");

  const loadAccounts = useCallback(async () => {
    const records = await collectPages(async (after) =>
      apiData(
        await apiClient.GET("/api/v1/accounts", {
          params: { query: { limit: 100, after: after ?? undefined } },
        }),
      ),
    );
    setAccounts(records);
  }, []);

  useEffect(() => {
    let active = true;
    collectPages(async (after) =>
      apiData(
        await apiClient.GET("/api/v1/accounts", {
          params: { query: { limit: 100, after: after ?? undefined } },
        }),
      ),
    )
      .then((records) => {
        if (active) setAccounts(records);
      })
      .catch(() => {
        if (active) setError(t("setup.accounts.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  async function createAccount(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const email = form.get("email");
    const password = form.get("password");
    const role = form.get("role");

    if (typeof email !== "string" || typeof password !== "string" || !isRole(role)) {
      setError(t("setup.accounts.requestFailed"));
      return;
    }

    setPending("create");
    setError("");
    setSuccess("");
    try {
      await apiClient.POST("/api/v1/accounts", {
        body: { account: { email, password, role } },
      });
      await loadAccounts();
      formElement.reset();
      setSuccess(t("setup.accounts.created"));
    } catch {
      setError(t("setup.accounts.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  async function changeRole(account: Account, event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const role = new FormData(event.currentTarget).get("role");
    if (!isRole(role) || account.id === currentAccountId) return;

    setPending(account.id);
    setError("");
    setSuccess("");
    try {
      await apiClient.PATCH("/api/v1/accounts/{id}/role", {
        params: { path: { id: account.id } },
        body: { account: { role } },
      });
      await loadAccounts();
      setSuccess(t("setup.accounts.roleChanged", { email: account.email }));
    } catch {
      setError(t("setup.accounts.requestFailed"));
    } finally {
      setPending(null);
    }
  }

  return (
    <section id="accounts" className="scroll-mt-6 space-y-4">
      <div>
        <h2 className="flex items-center gap-2 text-xl font-semibold">
          <Users className="size-5 text-primary" />
          {t("setup.accounts.title")}
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">{t("setup.accounts.description")}</p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert>
          <CheckCircle2 />
          <AlertDescription>{success}</AlertDescription>
        </Alert>
      )}

      <Card>
        <CardHeader>
          <CardTitle>{t("setup.accounts.createTitle")}</CardTitle>
          <CardDescription>{t("setup.accounts.passwordDescription")}</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="grid gap-4 md:grid-cols-2" onSubmit={createAccount}>
            <div className="space-y-2">
              <Label htmlFor="account-email">{t("setup.accounts.email")}</Label>
              <Input id="account-email" name="email" type="email" autoComplete="off" required />
            </div>
            <div className="space-y-2">
              <Label htmlFor="account-password">{t("setup.accounts.password")}</Label>
              <Input
                id="account-password"
                name="password"
                type="password"
                autoComplete="new-password"
                minLength={12}
                required
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="account-role">{t("setup.accounts.role")}</Label>
              <select
                id="account-role"
                name="role"
                className={selectClassName()}
                defaultValue="operator"
              >
                {roles.map((role) => (
                  <option key={role} value={role}>
                    {t(`setup.accounts.roles.${role}`)}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex items-end">
              <Button type="submit" disabled={pending !== null}>
                {pending === "create" ? <Spinner /> : <Plus />}
                {t("setup.accounts.create")}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>{t("setup.accounts.listTitle")}</CardTitle>
          <CardDescription>{t("setup.accounts.roleDescription")}</CardDescription>
        </CardHeader>
        <CardContent className="space-y-3">
          {accounts === null ? (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Spinner />
              {t("common.loading")}
            </div>
          ) : (
            accounts.map((account) => {
              const current = account.id === currentAccountId;
              return (
                <form
                  key={`${account.id}-${account.role_version}`}
                  className="flex flex-col gap-3 rounded-lg border p-4 sm:flex-row sm:items-end sm:justify-between"
                  onSubmit={(event) => void changeRole(account, event)}
                >
                  <div className="min-w-0 space-y-1">
                    <p className="break-all font-medium">{account.email}</p>
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge variant="secondary">{t(`setup.accounts.roles.${account.role}`)}</Badge>
                      {current && (
                        <span className="text-xs text-muted-foreground">
                          {t("setup.accounts.current")}
                        </span>
                      )}
                    </div>
                  </div>
                  <div className="flex w-full flex-col gap-2 sm:w-auto sm:flex-row sm:items-end">
                    <div className="space-y-2 sm:w-40">
                      <Label htmlFor={`account-role-${account.id}`}>
                        {t("setup.accounts.role")}
                      </Label>
                      <select
                        id={`account-role-${account.id}`}
                        name="role"
                        className={selectClassName()}
                        defaultValue={account.role}
                        disabled={current || pending !== null}
                      >
                        {roles.map((role) => (
                          <option key={role} value={role}>
                            {t(`setup.accounts.roles.${role}`)}
                          </option>
                        ))}
                      </select>
                    </div>
                    <Button type="submit" variant="outline" disabled={current || pending !== null}>
                      {pending === account.id ? <Spinner /> : <Save />}
                      {t("setup.accounts.saveRole")}
                    </Button>
                  </div>
                </form>
              );
            })
          )}
        </CardContent>
      </Card>
    </section>
  );
}

function isRole(value: FormDataEntryValue | null): value is Role {
  return value === "admin" || value === "operator" || value === "viewer";
}
