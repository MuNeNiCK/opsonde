import { useCallback, useEffect, useState, type ReactNode } from "react";
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
import { apiClient, apiData } from "@/api/client";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Spinner } from "@/components/ui/spinner";
import { loadTargetSnapshot, type TargetSnapshot } from "@/targets/data";
import { AccessMethodForm } from "@/targets/access-method-form";
import { TargetDetailActions } from "@/targets/detail-actions";
import { TargetFileSection } from "@/targets/file-section";

export function TargetDetailPage() {
  const { targetId = "" } = useParams();
  const location = useLocation();
  const [searchParams] = useSearchParams();
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [snapshot, setSnapshot] = useState<TargetSnapshot | null>(null);
  const [error, setError] = useState("");
  const [checkingMethodId, setCheckingMethodId] = useState<string | null>(null);
  const [editingMethodId, setEditingMethodId] = useState<string | null>(null);
  const [success, setSuccess] = useState(
    (location.state as { created?: boolean } | null)?.created ? t("targets.targetCreated") : "",
  );
  const canManage = account?.role === "admin";

  const refresh = useCallback(async () => setSnapshot(await loadTargetSnapshot()), []);

  useEffect(() => {
    let active = true;
    loadTargetSnapshot()
      .then((next) => active && setSnapshot(next))
      .catch(() => {
        if (active) setError(t("targets.requestFailed"));
      });
    return () => {
      active = false;
    };
  }, [t]);

  if (!snapshot) {
    return (
      <div className="flex flex-1 items-center justify-center gap-2 text-muted-foreground">
        <Spinner />
        <span>{t("common.loading")}</span>
      </div>
    );
  }

  const target = snapshot.targets.find((item) => item.id === targetId && item.active);
  if (!target) {
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

  const identities = snapshot.identities.filter(
    (item) => item.target_id === target.id && item.active,
  );
  const methods = snapshot.methods
    .filter((item) => item.target_id === target.id && item.active)
    .sort((left, right) => left.priority - right.priority);
  const relationships = snapshot.relationships.filter(
    (item) =>
      item.active &&
      (item.source_target_id === target.id || item.destination_target_id === target.id),
  );
  const boundary = snapshot.boundaries.find((item) => item.id === target.management_boundary_id);
  const targetName = (id: string) => snapshot.targets.find((item) => item.id === id)?.name ?? id;

  async function complete(message: string) {
    await refresh();
    setSuccess(message);
  }

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
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
      </div>

      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
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
          targets={snapshot.targets}
          providers={snapshot.providers}
          catalog={snapshot.catalog}
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
        >
          {methods.map((method, index) => {
            const provider = snapshot.providers.find((item) => item.id === method.provider_id);
            const available = method.check.current;
            return (
              <Record
                key={method.id}
                title={method.name}
                badge={index === 0 ? t("targets.preferred") : undefined}
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
                          setError(t("targets.requestFailed"));
                        } finally {
                          await refresh();
                          setCheckingMethodId(null);
                        }
                      }}
                    >
                      {checkingMethodId === method.id && <Spinner />}
                      {t("targets.check")}
                    </Button>
                    {editingMethodId === method.id ? (
                      <AccessMethodForm
                        target={target}
                        providers={snapshot.providers}
                        catalog={snapshot.catalog}
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
        >
          {relationships.map((relationship) => {
            const outgoing = relationship.source_target_id === target.id;
            const peer = outgoing
              ? relationship.destination_target_id
              : relationship.source_target_id;
            return (
              <Record key={relationship.id} title={relationship.kind}>
                <p className="text-sm text-muted-foreground">
                  {outgoing ? t("targets.outgoing") : t("targets.incoming")} · {targetName(peer)}
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
}: {
  icon: ReactNode;
  title: string;
  empty: string;
  children: ReactNode;
}) {
  const items = Array.isArray(children) ? children : [children];
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <span className="[&_svg]:size-4">{icon}</span>
          {title}
        </CardTitle>
        <CardDescription>
          {items.length} {title}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {items.length ? children : <p className="text-sm text-muted-foreground">{empty}</p>}
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
