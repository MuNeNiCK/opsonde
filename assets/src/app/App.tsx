import { lazy, Suspense, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "@/app/app-shell";
import { AuthenticationProvider } from "@/auth/provider";
import { LoginPage } from "@/auth/login-page";
import { useAuthentication } from "@/auth/context";
import { Spinner } from "@/components/ui/spinner";

const CaseListPage = lazy(() =>
  import("@/cases/list-page").then((module) => ({ default: module.CaseListPage })),
);
const CaseDetailPage = lazy(() =>
  import("@/cases/detail-page").then((module) => ({ default: module.CaseDetailPage })),
);
const SignalDiagnosticsPage = lazy(() =>
  import("@/cases/signal-diagnostics-page").then((module) => ({
    default: module.SignalDiagnosticsPage,
  })),
);
const SetupPage = lazy(() =>
  import("@/settings/page").then((module) => ({ default: module.SetupPage })),
);
const TargetPage = lazy(() =>
  import("@/targets/page").then((module) => ({ default: module.TargetPage })),
);
const AuditPage = lazy(() =>
  import("@/audits/page").then((module) => ({ default: module.AuditPage })),
);
const ReportPage = lazy(() =>
  import("@/reports/page").then((module) => ({ default: module.ReportPage })),
);
const CLILoginPage = lazy(() =>
  import("@/auth/cli-login-page").then((module) => ({ default: module.CLILoginPage })),
);

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

function FoundationPage({ title }: { title: string }) {
  const { t } = useTranslation();
  return (
    <main className="p-6 lg:p-8">
      <h1 className="text-2xl font-semibold tracking-tight">{t(title)}</h1>
      <p className="mt-2 text-muted-foreground">{t("pages.foundation")}</p>
    </main>
  );
}

function AppRoutes() {
  return (
    <Suspense fallback={<PageSpinner />}>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route
          path="/cli-login/:requestId"
          element={
            <AuthenticationGate>
              <CLILoginPage />
            </AuthenticationGate>
          }
        />
        <Route
          element={
            <AuthenticationGate>
              <AppShell />
            </AuthenticationGate>
          }
        >
          <Route index element={<Navigate to="/cases" replace />} />
          <Route path="cases" element={<CaseListPage />} />
          <Route path="cases/signals" element={<SignalDiagnosticsPage />} />
          <Route path="cases/:caseId" element={<CaseDetailPage />} />
          <Route path="targets" element={<TargetPage />} />
          <Route path="providers" element={<Navigate to="/settings#providers" replace />} />
          <Route path="audits" element={<AuditPage />} />
          <Route path="reports" element={<ReportPage />} />
          <Route path="settings" element={<SetupPage />} />
          <Route path="*" element={<FoundationPage title="pages.notFound" />} />
        </Route>
      </Routes>
    </Suspense>
  );
}

function PageSpinner() {
  const { t } = useTranslation();
  return (
    <div className="flex min-h-svh items-center justify-center gap-2 text-muted-foreground">
      <Spinner />
      <span className="sr-only">{t("common.loading")}</span>
    </div>
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
