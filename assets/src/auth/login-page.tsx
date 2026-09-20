import { useState, type FormEvent } from "react";
import { AlertCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Navigate, useLocation } from "react-router-dom";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";

export function LoginPage() {
  const { account, bootstrap, oidcEnabled, signIn, signInWithOIDC } = useAuthentication();
  const { t, i18n } = useTranslation();
  const location = useLocation();
  const [submitting, setSubmitting] = useState(false);
  const [failed, setFailed] = useState(false);
  const [oidcFailed, setOIDCFailed] = useState(false);
  const [firstUse, setFirstUse] = useState(false);
  const returnPath = (location.state as { from?: string } | null)?.from ?? "/";

  if (account) return <Navigate to={returnPath} replace />;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setFailed(false);
    setOIDCFailed(false);
    const form = new FormData(event.currentTarget);
    const email = form.get("email");
    const password = form.get("password");
    const confirmation = form.get("password_confirmation");

    if (
      typeof email !== "string" ||
      typeof password !== "string" ||
      (firstUse && typeof confirmation !== "string")
    ) {
      setFailed(true);
      setSubmitting(false);
      return;
    }

    try {
      if (firstUse) {
        await bootstrap(email, password, confirmation as string);
      } else {
        await signIn(email, password);
      }
    } catch {
      setFailed(true);
    } finally {
      setSubmitting(false);
    }
  }

  async function oidcSignIn() {
    setSubmitting(true);
    setFailed(false);
    setOIDCFailed(false);
    try {
      await signInWithOIDC();
    } catch {
      setOIDCFailed(true);
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <main className="grid min-h-svh place-items-center bg-muted/40 p-4">
      <div className="w-full max-w-sm space-y-4">
        <div className="flex justify-end">
          <Button
            size="sm"
            variant="ghost"
            onClick={() => void i18n.changeLanguage(i18n.resolvedLanguage === "ja" ? "en" : "ja")}
          >
            {i18n.resolvedLanguage === "ja" ? "English" : "日本語"}
          </Button>
        </div>
        <Card>
          <CardHeader>
            <CardTitle>{t(firstUse ? "login.bootstrapTitle" : "login.title")}</CardTitle>
            <CardDescription>
              {t(firstUse ? "login.bootstrapDescription" : "login.description")}
            </CardDescription>
          </CardHeader>
          <CardContent>
            <form className="space-y-4" onSubmit={submit}>
              {(failed || oidcFailed) && (
                <Alert variant="destructive">
                  <AlertCircle />
                  <AlertDescription>
                    {t(
                      oidcFailed
                        ? "login.oidcFailed"
                        : firstUse
                          ? "login.bootstrapFailed"
                          : "login.failed",
                    )}
                  </AlertDescription>
                </Alert>
              )}
              <div className="space-y-2">
                <Label htmlFor="email">{t("login.email")}</Label>
                <Input id="email" name="email" type="email" autoComplete="username" required />
              </div>
              <div className="space-y-2">
                <Label htmlFor="password">{t("login.password")}</Label>
                <Input
                  id="password"
                  name="password"
                  type="password"
                  autoComplete="current-password"
                  required
                />
              </div>
              {firstUse && (
                <div className="space-y-2">
                  <Label htmlFor="password_confirmation">{t("login.confirmPassword")}</Label>
                  <Input
                    id="password_confirmation"
                    name="password_confirmation"
                    type="password"
                    autoComplete="new-password"
                    required
                  />
                </div>
              )}
              <Button className="w-full" type="submit" disabled={submitting}>
                {submitting && <Spinner />}
                {t(firstUse ? "login.bootstrapSubmit" : "login.submit")}
              </Button>
              {!firstUse && oidcEnabled && (
                <Button
                  className="w-full"
                  type="button"
                  variant="outline"
                  disabled={submitting}
                  onClick={() => void oidcSignIn()}
                >
                  {t("login.oidcSubmit")}
                </Button>
              )}
              <Button
                className="w-full"
                type="button"
                variant="ghost"
                onClick={() => {
                  setFailed(false);
                  setOIDCFailed(false);
                  setFirstUse((value) => !value);
                }}
              >
                {t(firstUse ? "login.useExisting" : "login.firstUse")}
              </Button>
            </form>
          </CardContent>
        </Card>
      </div>
    </main>
  );
}
