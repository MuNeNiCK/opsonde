import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  ArrowLeft,
  Cable,
  CheckCircle2,
  CircleAlert,
  Fingerprint,
  Link2,
  FileText,
} from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useLocation, useParams, useSearchParams } from "react-router-dom";
import { ApiError, apiClient, apiData } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import { PageControls } from "@/components/page-controls";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import {
  loadDetailHeader,
  loadDetailMethods,
  loadDetailRelationships,
} from "@/targets/detail-data";
import { AccessMethodForm } from "@/targets/access-method-form";
import { TargetDetailActions } from "@/targets/detail-actions";
import { TargetFileSection } from "@/targets/file-section";

export function TargetDetailPage() {
  const { targetId = "" } = useParams();
  return <TargetDetail key={targetId} targetId={targetId} />;
}

function TargetDetail({ targetId }: { targetId: string }) {
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [header, setHeader] = useState<Awaited<ReturnType<typeof loadDetailHeader>> | null>(null);
  const [headerError, setHeaderError] = useState<unknown>(null);
  const [loadingHeader, setLoadingHeader] = useState(true);
  const owner = useRef<AbortController | null>(null);
  const mounted = useRef(false);
  const [error, setError] = useState("");
  const [checkingMethodId, setCheckingMethodId] = useState<string | null>(null);
  const [editingMethodId, setEditingMethodId] = useState<string | null>(null);
  const [success, setSuccess] = useState(
    (location.state as { created?: boolean } | null)?.created ? t("targets.targetCreated") : "",
  );
  const canManage = account?.role === "admin";

  const methodPage = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        loadDetailMethods(targetId, after, signal),
      [targetId],
    ),
  );
  const identityPage = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        apiClient
          .GET("/api/v1/external-identities", {
            params: { query: { target_id: targetId, active: true, limit: 50, after } },
            signal,
          })
          .then(apiData),
      [targetId],
    ),
  );
  const relationshipPage = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        loadDetailRelationships(targetId, after, signal),
      [targetId],
    ),
  );
  const readHeader = useCallback(async () => {
    if (!mounted.current) return;
    owner.current?.abort();
    const controller = new AbortController();
    owner.current = controller;
    return loadDetailHeader(targetId, controller.signal)
      .then((next) => {
        if (!controller.signal.aborted) {
          setHeader(next);
          setHeaderError(null);
        }
      })
      .catch((cause) => {
        if (!controller.signal.aborted) {
          setHeaderError(cause);
          throw cause;
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoadingHeader(false);
      });
  }, [targetId]);
  const refreshHeader = () => {
    if (!mounted.current) return Promise.resolve();
    setLoadingHeader(true);
    setHeaderError(null);
    return readHeader();
  };
  const refresh = async () => {
    await Promise.all([
      refreshHeader(),
      methodPage.reload(),
      identityPage.reload(),
      relationshipPage.reload(),
    ]);
  };

  useEffect(() => {
    mounted.current = true;
    void readHeader().catch(() => {});
    return () => {
      mounted.current = false;
      owner.current?.abort();
    };
  }, [readHeader]);

  if (!header) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        {headerError != null ? (
          <div className="space-y-3">
            <Alert variant="destructive">
              <AlertDescription>
                {t(
                  headerError instanceof ApiError && headerError.status === 404
                    ? "targets.targetNotFound"
                    : "targets.requestFailed",
                )}
              </AlertDescription>
            </Alert>
            <Button disabled={loadingHeader} onClick={() => void refreshHeader().catch(() => {})}>
              {t("common.refresh")}
            </Button>
          </div>
        ) : (
          <>
            <Spinner />
            <span>{t("common.loading")}</span>
          </>
        )}
      </div>
    );
  }

  const { target, catalog, boundary } = header;
  if (!target.active) {
    return (
      <div className="space-y-4 p-6 lg:p-8">
        <Button asChild variant="ghost">
          <Link to="/targets">
            <ArrowLeft />
            {t("targets.back")}
          </Link>
        </Button>
        <Alert variant="destructive">
          <AlertDescription>{t("targets.targetNotFound")}</AlertDescription>
        </Alert>
      </div>
    );
  }

  const identities = identityPage.view?.data ?? [];
  const methods = methodPage.view?.data ?? [];
  const relationships = relationshipPage.view?.data ?? [];

  async function complete(message: string) {
    await refresh();
    if (mounted.current) setSuccess(message);
  }

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button
          variant="outline"
          size="sm"
          disabled={
            loadingHeader || methodPage.pending || identityPage.pending || relationshipPage.pending
          }
          onClick={() => void refresh().catch(() => {})}
        >
          {t("common.refresh")}
        </Button>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to="/targets">
            <ArrowLeft />
            {t("targets.back")}
          </Link>
        </Button>
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="text-2xl font-semibold tracking-tight">{target.name}</h1>
          <Badge variant="outline">{target.type_id}</Badge>
        </div>
        <p className="mt-2 text-muted-foreground">
          {target.kind}
          {boundary ? " · " + boundary.name : ""}
        </p>
        {Object.keys(target.facts).length > 0 && (
          <dl className="mt-4 grid gap-x-6 gap-y-2 sm:grid-cols-2">
            {Object.entries(target.facts).map(([name, value]) => (
              <div key={name} className="grid grid-cols-[minmax(0,1fr)_minmax(0,2fr)] gap-3">
                <dt className="min-w-0 break-all text-muted-foreground">{name}</dt>
                <dd className="min-w-0 break-all">
                  {typeof value === "string" ? value : JSON.stringify(value)}
                </dd>
              </div>
            ))}
          </dl>
        )}
      </div>

      {(error || headerError != null) && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error || t("targets.requestFailed")}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert>
          <CheckCircle2 />
          <AlertDescription>{success}</AlertDescription>
        </Alert>
      )}
      {!canManage && (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      )}
      {canManage && (
        <TargetDetailActions
          target={target}
          catalog={catalog}
          initialAction={searchParams.get("action") === "relationship" ? "relationship" : undefined}
          onComplete={complete}
          onError={setError}
        />
      )}

      <TargetFileSection key={target.id} targetId={target.id} />
      <div className="grid gap-4 xl:grid-cols-2">
        <Section
          icon={<Cable />}
          title={t("targets.accessMethods")}
          empty={t("targets.noAccessMethods")}
          page={methodPage}
        >
          {methods.map(({ method, provider }, index) => {
            const available = method.check.current;
            return (
              <Record
                key={method.id}
                title={method.name}
                badge={
                  methodPage.view?.index === 0 && index === 0 ? t("targets.preferred") : undefined
                }
              >
                <p className="break-all text-sm text-muted-foreground">
                  {method.method} · {method.endpoint} · P{method.priority}
                </p>
                <div className="mt-2 flex items-start gap-2 text-sm">
                  {available ? (
                    <CheckCircle2 className="mt-0.5 size-4 text-success" />
                  ) : (
                    <CircleAlert className="mt-0.5 size-4 text-warning" />
                  )}
                  <span>
                    {provider
                      ? provider.name +
                        " · " +
                        t(available ? "targets.checkPassed" : "targets.methodCheckRequired")
                      : t("targets.connectionMissing")}
                  </span>
                </div>
                {method.check.message && (
                  <details className="mt-2 text-sm text-muted-foreground">
                    <summary className="cursor-pointer">{t("common.diagnostics")}</summary>
                    <p>{method.check.message}</p>
                  </details>
                )}
                <p className="mt-3 text-xs text-muted-foreground">
                  {t("targets.observedCapabilities")}
                </p>
                <div className="mt-1 flex flex-wrap gap-1">
                  {method.check.observed_capabilities.map((capability) => (
                    <Badge key={capability} variant="outline">
                      {capability}
                    </Badge>
                  ))}
                </div>
                <p className="mt-3 text-xs text-muted-foreground">
                  {t("targets.allowedCapabilities")}
                </p>
                {method.capabilities.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-1">
                    {method.capabilities.map((capability) => (
                      <Badge key={capability} variant="secondary">
                        {capability}
                      </Badge>
                    ))}
                  </div>
                )}
                {canManage && (
                  <div className="mt-3 space-y-3">
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={checkingMethodId !== null || !provider?.enabled}
                      onClick={async () => {
                        setCheckingMethodId(method.id);
                        setError("");
                        try {
                          apiData(
                            await apiClient.POST("/api/v1/access-methods/{id}/check", {
                              params: { path: { id: method.id } },
                              body: { access_method: { expected_revision: method.revision } },
                            }),
                          );
                        } catch {
                          if (mounted.current) setError(t("targets.requestFailed"));
                        } finally {
                          await refresh().catch(() => {
                            if (mounted.current) setError(t("targets.requestFailed"));
                          });
                          if (mounted.current) setCheckingMethodId(null);
                        }
                      }}
                    >
                      {checkingMethodId === method.id && <Spinner />}
                      {t("targets.check")}
                    </Button>
                    {editingMethodId === method.id ? (
                      <AccessMethodForm
                        target={target}
                        initialProvider={provider}
                        catalog={catalog}
                        method={method}
                        onSaved={async () => {
                          await complete(t("targets.accessMethodUpdated"));
                          setEditingMethodId(null);
                        }}
                        onCancel={() => setEditingMethodId(null)}
                        onError={setError}
                      />
                    ) : (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => setEditingMethodId(method.id)}
                      >
                        {t("targets.editAccessMethod")}
                      </Button>
                    )}
                  </div>
                )}
              </Record>
            );
          })}
        </Section>

        <Section
          icon={<Fingerprint />}
          title={t("targets.identities")}
          empty={t("targets.noIdentities")}
          page={identityPage}
        >
          {identities.map((identity) => (
            <Record key={identity.id} title={identity.source + " · " + identity.kind}>
              <p className="break-all text-sm text-muted-foreground">{identity.value}</p>
            </Record>
          ))}
        </Section>

        <Section
          icon={<Link2 />}
          title={t("targets.layerRelationships")}
          empty={t("targets.noLayerRelationships")}
          page={relationshipPage}
        >
          {relationships.map(({ relationship, peer: referencedPeer }) => {
            const outgoing = relationship.source_target_id === target.id;
            const peer = outgoing
              ? relationship.destination_target_id
              : relationship.source_target_id;
            return (
              <Record key={relationship.id} title={relationship.kind}>
                <p className="text-sm text-muted-foreground">
                  {outgoing ? t("targets.outgoing") : t("targets.incoming")} ·{" "}
                  {referencedPeer?.name ?? peer}
                </p>
              </Record>
            );
          })}
        </Section>

        <Section
          icon={<FileText />}
          title={t("targets.operatingInstructions")}
          empty={t("targets.noInstructions")}
        >
          {target.operating_instructions
            ? [
                <p key="instructions" className="whitespace-pre-wrap text-sm">
                  {target.operating_instructions}
                </p>,
              ]
            : []}
        </Section>
      </div>
    </div>
  );
}

function Section({
  icon,
  title,
  empty,
  children,
  page,
}: {
  icon: ReactNode;
  title: string;
  empty: string;
  children: ReactNode;
  page?: {
    view: { index: number; page: { next: string | null } } | null;
    pending: boolean;
    error: unknown;
    previous: () => void;
    next: () => void;
    retry: () => Promise<void>;
  };
}) {
  const { t } = useTranslation();
  const items = Array.isArray(children) ? children : [children];
  return (
    <Card role="region" aria-label={title}>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <span className="[&_svg]:size-4">{icon}</span>
          {title}
        </CardTitle>
        <CardDescription>
          {page ? t("targets.pageRecords", { count: items.length }) : `${items.length} ${title}`}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {page?.pending && <Spinner />}
        {page?.error != null && (
          <Alert variant="destructive">
            <AlertDescription>{t("targets.requestFailed")}</AlertDescription>
            <Button variant="outline" size="sm" onClick={() => void page.retry().catch(() => {})}>
              {t("common.refresh")}
            </Button>
          </Alert>
        )}
        {items.length ? (
          children
        ) : !page?.pending && page?.error == null ? (
          <p className="text-sm text-muted-foreground">{empty}</p>
        ) : null}
        {page && (
          <PageControls
            index={page.view?.index ?? 0}
            hasNext={!!page.view?.page.next}
            pending={page.pending}
            previous={page.previous}
            next={page.next}
          />
        )}
      </CardContent>
    </Card>
  );
}

function Record({
  title,
  badge,
  children,
}: {
  title: string;
  badge?: string;
  children: ReactNode;
}) {
  return (
    <div className="rounded-lg border p-4">
      <div className="flex flex-wrap items-center gap-2">
        <p className="font-medium">{title}</p>
        {badge && <Badge variant="outline">{badge}</Badge>}
      </div>
      <div className="mt-2">{children}</div>
    </div>
  );
}
