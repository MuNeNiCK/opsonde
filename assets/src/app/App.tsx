import { lazy, Suspense, useEffect, useState, type ReactNode } from "react";
import { useTranslation } from "react-i18next";
import { BrowserRouter, Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppShell } from "@/app/app-shell";
import { AuthenticationProvider } from "@/auth/provider";
import { LoginPage } from "@/auth/login-page";
import { useAuthentication } from "@/auth/context";
import { Spinner } from "@/components/ui/spinner";
import { loadSettingsSnapshot, readiness } from "@/settings/data";

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
const AIProviderPage = lazy(() =>
  import("@/providers/pages").then((module) => ({ default: module.AIProviderPage })),
);
const AIProviderCreatePage = lazy(() =>
  import("@/providers/pages").then((module) => ({ default: module.AIProviderCreatePage })),
);
const SignalProviderPage = lazy(() =>
  import("@/providers/pages").then((module) => ({ default: module.SignalProviderPage })),
);
const SignalProviderCreatePage = lazy(() =>
  import("@/providers/pages").then((module) => ({ default: module.SignalProviderCreatePage })),
);
const OnboardingPage = lazy(() =>
  import("@/settings/onboarding-page").then((module) => ({ default: module.OnboardingPage })),
);
const TargetPage = lazy(() =>
  import("@/targets/page").then((module) => ({ default: module.TargetPage })),
);
const TargetDetailPage = lazy(() =>
  import("@/targets/detail-page").then((module) => ({ default: module.TargetDetailPage })),
);
const TargetCreatePage = lazy(() =>
  import("@/targets/create-page").then((module) => ({ default: module.TargetCreatePage })),
);
const TargetConnectionsPage = lazy(() =>
  import("@/targets/connections-page").then((module) => ({
    default: module.TargetConnectionsPage,
  })),
);
const TargetConnectionCreatePage = lazy(() =>
  import("@/targets/connection-create-page").then((module) => ({
    default: module.TargetConnectionCreatePage,
  })),
);
const TargetImportPage = lazy(() =>
  import("@/targets/import-page").then((module) => ({ default: module.TargetImportPage })),
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
    <div className="p-6 lg:p-8">
      <h1 className="text-2xl font-semibold tracking-tight">{t(title)}</h1>
      <p className="mt-2 text-muted-foreground">{t("pages.foundation")}</p>
    </div>
  );
}

function HomeRoute() {
  const { account } = useAuthentication();
  const [destination, setDestination] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    if (account?.role !== "admin") return;

    loadSettingsSnapshot()
      .then((snapshot) => {
        if (active) setDestination(readiness(snapshot).complete ? "/cases" : "/onboarding");
      })
      .catch(() => {
        if (active) setDestination("/settings");
      });
    return () => {
      active = false;
    };
  }, [account?.role]);

  if (account?.role !== "admin") return <Navigate to="/cases" replace />;
  return destination ? <Navigate to={destination} replace /> : <PageSpinner />;
}

function AppRoutes() {
  const location = useLocation();
  const { t } = useTranslation();

  useEffect(() => {
    const path = location.pathname;
    const key =
      path === "/login"
        ? "login.title"
        : path.startsWith("/cli-login/")
          ? "cliLogin.title"
          : path === "/onboarding"
            ? "onboarding.title"
            : path === "/cases/signals"
              ? "cases.signalDiagnostics"
              : path.startsWith("/cases/")
                ? "pages.case"
                : path === "/cases" || path === "/"
                  ? "pages.cases"
                  : path.startsWith("/ai")
                    ? "pages.ai"
                    : path.startsWith("/signals")
                      ? "pages.signals"
                      : path.startsWith("/targets")
                        ? "pages.targets"
                        : path === "/audits"
                          ? "pages.audits"
                          : path === "/reports"
                            ? "pages.reports"
                            : path === "/settings" || path === "/providers"
                              ? "pages.settings"
                              : "pages.notFound";
    document.title = `${t(key)} · Opsonde`;
  }, [location.pathname, t]);

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
          <Route index element={<HomeRoute />} />
          <Route path="onboarding" element={<OnboardingPage />} />
          <Route path="cases" element={<CaseListPage />} />
          <Route path="cases/signals" element={<SignalDiagnosticsPage />} />
          <Route path="cases/:caseId" element={<CaseDetailPage />} />
          <Route path="targets" element={<TargetPage />} />
          <Route path="targets/new" element={<TargetCreatePage />} />
          <Route path="targets/connections" element={<TargetConnectionsPage />} />
          <Route path="targets/connections/new" element={<TargetConnectionCreatePage />} />
          <Route path="targets/connections/new/:family" element={<TargetConnectionCreatePage />} />
          <Route path="targets/imports" element={<TargetImportPage />} />
          <Route path="targets/:targetId" element={<TargetDetailPage />} />
          <Route path="ai" element={<AIProviderPage />} />
          <Route path="ai/new" element={<AIProviderCreatePage />} />
          <Route path="ai/new/:providerType" element={<AIProviderCreatePage />} />
          <Route path="signals" element={<SignalProviderPage />} />
          <Route path="signals/new" element={<SignalProviderCreatePage />} />
          <Route path="signals/new/:providerType" element={<SignalProviderCreatePage />} />
          <Route path="providers" element={<Navigate to="/ai" replace />} />
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
