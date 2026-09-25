import { useCallback, useEffect, useState, type FormEvent } from "react";
import { CheckCircle2, Plus, Save, Users } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
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

export function AccountSection({ currentAccountId }: { currentAccountId: string }) {
  const { t } = useTranslation();
  const [accounts, setAccounts] = useState<Account[] | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [draftRoles, setDraftRoles] = useState<Record<string, Role>>({});
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
    setDraftRoles({});
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
      setShowCreate(false);
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
    <section id="accounts" className="scroll-mt-20 space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="flex items-center gap-2 text-xl font-semibold">
            <Users className="size-5 text-primary" />
            {t("setup.accounts.title")}
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">{t("setup.accounts.description")}</p>
        </div>
        <Button variant="outline" size="sm" onClick={() => setShowCreate((open) => !open)}>
          {showCreate ? null : <Plus />}
          {t(showCreate ? "common.close" : "setup.accounts.createTitle")}
        </Button>
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

      {showCreate && (
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
                <FormSelect
                  id="account-role"
                  name="role"
                  defaultValue="operator"
                  options={roles.map((role) => ({
                    value: role,
                    label: t(`setup.accounts.roles.${role}`),
                  }))}
                />
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
      )}

      <Card>
        <CardHeader className="border-b">
          <CardTitle className="text-base">
            {t("setup.accounts.listTitle")}
            {accounts && <span className="ml-2 text-muted-foreground">{accounts.length}</span>}
          </CardTitle>
          <CardDescription>{t("setup.accounts.roleDescription")}</CardDescription>
        </CardHeader>
        <CardContent className="p-0">
          {accounts === null ? (
            <div className="flex items-center gap-2 px-5 py-6 text-sm text-muted-foreground">
              <Spinner />
              {t("common.loading")}
            </div>
          ) : (
            accounts.map((account) => {
              const current = account.id === currentAccountId;
              const selectedRole = draftRoles[account.id] ?? account.role;
              return (
                <form
                  key={`${account.id}-${account.role_version}`}
                  className="flex flex-col gap-3 border-b px-5 py-4 last:border-b-0 sm:flex-row sm:items-center sm:justify-between"
                  onSubmit={(event) => void changeRole(account, event)}
                >
                  <div className="min-w-0 space-y-1.5">
                    <p className="break-all text-sm font-medium">{account.email}</p>
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge variant="secondary">{t(`setup.accounts.roles.${account.role}`)}</Badge>
                      {current && (
                        <span className="text-xs text-muted-foreground">
                          {t("setup.accounts.current")}
                        </span>
                      )}
                    </div>
                  </div>
                  {!current && (
                    <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
                      <FormSelect
                        id={`account-role-${account.id}`}
                        name="role"
                        ariaLabel={`${account.email}: ${t("setup.accounts.role")}`}
                        className="sm:w-36"
                        value={selectedRole}
                        onValueChange={(value) => {
                          if (isRole(value)) {
                            setDraftRoles((roles) => ({ ...roles, [account.id]: value }));
                          }
                        }}
                        disabled={pending !== null}
                        options={roles.map((role) => ({
                          value: role,
                          label: t(`setup.accounts.roles.${role}`),
                        }))}
                      />
                      <Button
                        type="submit"
                        size="sm"
                        variant="outline"
                        disabled={selectedRole === account.role || pending !== null}
                      >
                        {pending === account.id ? <Spinner /> : <Save />}
                        {t("setup.accounts.saveRole")}
                      </Button>
                    </div>
                  )}
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
