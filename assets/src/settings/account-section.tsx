import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { CheckCircle2, Plus, Save, Users } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import type { components } from "@/api/schema";
import { FormSelect } from "@/components/form-select";
import { PageControls } from "@/components/page-controls";
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
  const [showCreate, setShowCreate] = useState(false);
  const [draftRoles, setDraftRoles] = useState<Record<string, Role>>({});
  const [pending, setPending] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const page = usePagedData(
    useCallback(async (after: string | undefined, signal: AbortSignal) => {
      const result = apiData(
        await apiClient.GET("/api/v1/accounts", {
          params: { query: { limit: 50, after } },
          signal,
        }),
      );
      if (!signal.aborted) setDraftRoles({});
      return result;
    }, []),
  );
  const accounts = page.view?.data ?? [];
  async function refresh() {
    setError("");
    setSuccess("");
    await page.retry().catch(() => {});
  }

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
      apiData(
        await apiClient.POST("/api/v1/accounts", {
          body: { account: { email, password, role } },
        }),
      );
      if (!mounted.current) return;
      formElement.reset();
      setShowCreate(false);
      setSuccess(t("setup.accounts.created"));
      await page.retry().catch(() => {});
    } catch {
      if (mounted.current) setError(t("setup.accounts.requestFailed"));
    } finally {
      if (mounted.current) setPending(null);
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
      apiData(
        await apiClient.PATCH("/api/v1/accounts/{id}/role", {
          params: { path: { id: account.id } },
          body: { account: { role } },
        }),
      );
      if (!mounted.current) return;
      setSuccess(t("setup.accounts.roleChanged", { email: account.email }));
      await page.retry().catch(() => {});
    } catch {
      if (mounted.current) setError(t("setup.accounts.requestFailed"));
    } finally {
      if (mounted.current) setPending(null);
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
        <Button
          variant="outline"
          size="sm"
          disabled={pending !== null}
          onClick={() => setShowCreate((open) => !open)}
        >
          {showCreate ? null : <Plus />}
          {t(showCreate ? "common.close" : "setup.accounts.createTitle")}
        </Button>
      </div>

      {!!(error || page.error) && (
        <Alert variant="destructive">
          <AlertDescription>{error || t("setup.accounts.loadFailed")}</AlertDescription>
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
                <Input
                  id="account-email"
                  name="email"
                  type="email"
                  autoComplete="off"
                  disabled={pending !== null}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="account-password">{t("setup.accounts.password")}</Label>
                <Input
                  id="account-password"
                  name="password"
                  type="password"
                  autoComplete="new-password"
                  minLength={12}
                  disabled={pending !== null}
                  required
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="account-role">{t("setup.accounts.role")}</Label>
                <FormSelect
                  id="account-role"
                  name="role"
                  defaultValue="operator"
                  disabled={pending !== null}
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
          <CardTitle className="text-base">{t("setup.accounts.listTitle")}</CardTitle>
          <CardDescription>{t("setup.accounts.roleDescription")}</CardDescription>
          <div className="flex flex-wrap gap-2">
            <PageControls
              index={page.view?.index ?? 0}
              hasNext={!!page.view?.page.next}
              pending={page.pending || pending !== null}
              previous={page.previous}
              next={page.next}
            />
            <Button
              size="sm"
              variant="outline"
              disabled={page.pending || pending !== null}
              onClick={() => void refresh()}
            >
              {t("common.refresh")}
            </Button>
          </div>
        </CardHeader>
        <CardContent className="p-0">
          {page.pending && (
            <div className="flex items-center gap-2 px-5 py-6 text-sm text-muted-foreground">
              <Spinner />
              {t("common.loading")}
            </div>
          )}
          {accounts.map((account) => {
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
                      disabled={pending !== null || page.pending}
                      options={roles.map((role) => ({
                        value: role,
                        label: t(`setup.accounts.roles.${role}`),
                      }))}
                    />
                    <Button
                      type="submit"
                      size="sm"
                      variant="outline"
                      disabled={selectedRole === account.role || pending !== null || page.pending}
                    >
                      {pending === account.id ? <Spinner /> : <Save />}
                      {t("setup.accounts.saveRole")}
                    </Button>
                  </div>
                )}
              </form>
            );
          })}
        </CardContent>
      </Card>
    </section>
  );
}

function isRole(value: FormDataEntryValue | null): value is Role {
  return value === "admin" || value === "operator" || value === "viewer";
}
