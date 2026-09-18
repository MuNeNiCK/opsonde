import { useState, type FormEvent, type ReactNode } from "react";
import { AlertCircle } from "lucide-react";
import { useTranslation } from "react-i18next";
import { BrowserRouter, Navigate, Route, Routes, useLocation, useParams } from "react-router-dom";
import { AppShell } from "@/app-shell";
import { AuthenticationProvider } from "@/auth";
import { useAuthentication } from "@/auth-context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { SetupPage } from "@/setup-page";
import { TargetPage } from "@/target-page";

function AuthenticationGate({ children }: { children: ReactNode }) {
  const { account, loading } = useAuthentication();
  const location = useLocation();
  const { t } = useTranslation();

  if (loading) {
    return (
      <div className="flex min-h-svh items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span className="sr-only">{t("common.loading")}</span>
      </div>
    );
  }

  if (!account) {
    return (
      <Navigate
        to="/login"
        replace
        state={{ from: location.pathname + location.search + location.hash }}
      />
    );
  }
  return children;
}

function LoginPage() {
  const { account, bootstrap, signIn } = useAuthentication();
  const { t, i18n } = useTranslation();
  const location = useLocation();
  const [submitting, setSubmitting] = useState(false);
  const [failed, setFailed] = useState(false);
  const [firstUse, setFirstUse] = useState(false);
  const returnPath = (location.state as { from?: string } | null)?.from ?? "/cases";

  if (account) return <Navigate to={returnPath} replace />;

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setFailed(false);
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
              {failed && (
                <Alert variant="destructive">
                  <AlertCircle />
                  <AlertDescription>
                    {t(firstUse ? "login.bootstrapFailed" : "login.failed")}
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
              <Button
                className="w-full"
                type="button"
                variant="ghost"
                onClick={() => {
                  setFailed(false);
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

function FoundationPage({ title }: { title: string }) {
  const { t } = useTranslation();
  return (
    <main className="p-6 lg:p-8">
      <h1 className="text-2xl font-semibold tracking-tight">{t(title)}</h1>
      <p className="mt-2 text-muted-foreground">{t("pages.foundation")}</p>
    </main>
  );
}

function CasePage() {
  const { caseId } = useParams();
  const { t } = useTranslation();
  return (
    <main className="p-6 lg:p-8">
      <h1 className="text-2xl font-semibold tracking-tight">{t("pages.case")}</h1>
      <p className="mt-2 font-mono text-sm text-muted-foreground">{caseId}</p>
    </main>
  );
}

function AppRoutes() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />
      <Route
        element={
          <AuthenticationGate>
            <AppShell />
          </AuthenticationGate>
        }
      >
        <Route index element={<Navigate to="/cases" replace />} />
        <Route path="cases" element={<FoundationPage title="pages.cases" />} />
        <Route path="cases/:caseId" element={<CasePage />} />
        <Route path="targets" element={<TargetPage />} />
        <Route path="providers" element={<Navigate to="/settings#providers" replace />} />
        <Route path="audits" element={<FoundationPage title="pages.audits" />} />
        <Route path="reports" element={<FoundationPage title="pages.reports" />} />
        <Route path="settings" element={<SetupPage />} />
        <Route path="*" element={<FoundationPage title="pages.notFound" />} />
      </Route>
    </Routes>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <AuthenticationProvider>
        <AppRoutes />
      </AuthenticationProvider>
    </BrowserRouter>
  );
}
