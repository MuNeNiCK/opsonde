import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Boxes, Cable, Network, Plus, Server } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useNavigate, useParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { ProviderChoiceCard } from "@/providers/choice-card";

type Boundary = components["schemas"]["ManagementBoundary"];

const targetChoices = {
  linux: {
    title: "Linux",
    kind: "host",
    platform: "linux",
    icon: Server,
    description: "targets.targetChoiceLinux",
  },
  "physical-host": {
    title: "Physical host",
    kind: "physical_host",
    platform: "bare_metal",
    icon: Server,
    description: "targets.targetChoicePhysicalHost",
  },
  "cisco-ios-xe": {
    title: "Cisco IOS XE",
    kind: "network_device",
    platform: "cisco_ios_xe",
    icon: Network,
    description: "targets.targetChoiceCisco",
  },
  kubernetes: {
    title: "Kubernetes",
    kind: "cluster",
    platform: "kubernetes",
    icon: Boxes,
    description: "targets.targetChoiceKubernetes",
  },
  generic: {
    title: "Generic",
    kind: null,
    platform: null,
    icon: Cable,
    description: "targets.targetChoiceGeneric",
  },
} as const;

export function TargetCreatePage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { targetType } = useParams();
  const { account } = useAuthentication();
  const [boundaries, setBoundaries] = useState<Boundary[] | null>(null);
  const [creatingBoundary, setCreatingBoundary] = useState(false);
  const [targetKind, setTargetKind] = useState("host");
  const [targetPlatform, setTargetPlatform] = useState("generic");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const canManage = account?.role === "admin";
  const choice =
    targetType && targetType in targetChoices
      ? targetChoices[targetType as keyof typeof targetChoices]
      : undefined;

  useEffect(() => {
    let active = true;
    loadBoundaries()
      .then((items) => active && setBoundaries(items))
      .catch(() => active && setError(t("targets.requestFailed")));
    return () => {
      active = false;
    };
  }, [t]);

  if (targetType && !choice) return <Navigate to="/targets/new" replace />;

  async function createBoundary(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError("");
    try {
      await apiClient.POST("/api/v1/management-boundaries", {
        body: {
          management_boundary: {
            name: value(form, "name"),
            kind: value(form, "kind"),
            facts: {},
          },
        },
      });
      setBoundaries(await loadBoundaries());
      setCreatingBoundary(false);
      setSuccess(t("targets.boundaryCreated"));
    } catch {
      setError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError("");
    try {
      const targetKindValue =
        choice?.kind ??
        (value(form, "kind") === "custom" ? value(form, "custom_kind") : value(form, "kind"));
      const targetPlatformValue =
        choice?.platform ??
        (value(form, "platform") === "custom"
          ? value(form, "custom_platform")
          : value(form, "platform"));
      const response = apiData(
        await apiClient.POST("/api/v1/targets", {
          body: {
            target: {
              name: value(form, "name"),
              kind: targetKindValue,
              platform: targetPlatformValue,
              facts: {},
              management_boundary_id: value(form, "management_boundary_id") || null,
            },
          },
        }),
      );
      void navigate("/targets/" + response.data.id, { replace: true, state: { created: true } });
    } catch {
      setError(t("targets.requestFailed"));
      setPending(false);
    }
  }

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={choice ? "/targets/new" : "/targets"}>
            <ArrowLeft />
            {t(choice ? "targets.backToTargetTypes" : "targets.back")}
          </Link>
        </Button>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="text-2xl font-semibold tracking-tight">
            {creatingBoundary
              ? t("targets.addBoundary")
              : choice
                ? choice.title
                : t("targets.chooseTargetType")}
          </h1>
          {canManage && choice && (
            <Button
              variant="outline"
              onClick={() => {
                setCreatingBoundary((current) => !current);
                setSuccess("");
              }}
            >
              {t(creatingBoundary ? "targets.backToTargetForm" : "targets.addBoundary")}
            </Button>
          )}
        </div>
        <p className="mt-2 text-muted-foreground">
          {t(choice ? choice.description : "targets.chooseTargetTypeDescription")}
        </p>
      </div>
      {error && (
        <Alert variant="destructive" className="sticky top-16 z-20">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {success && (
        <Alert>
          <AlertDescription>{success}</AlertDescription>
        </Alert>
      )}
      {!canManage ? (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      ) : !choice ? (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {Object.entries(targetChoices).map(([id, item]) => (
            <ProviderChoiceCard
              key={id}
              to={`/targets/new/${id}`}
              title={item.title}
              description={t(item.description)}
              icon={item.icon}
            />
          ))}
        </div>
      ) : creatingBoundary ? (
        <Card>
          <CardHeader>
            <CardTitle>{t("targets.addBoundary")}</CardTitle>
            <CardDescription>{t("targets.boundaryDescription")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={createBoundary}>
              <Field label={t("targets.name")} name="name" required maxLength={120} />
              <Field
                label={t("targets.kind")}
                name="kind"
                placeholder="datacenter"
                required
                maxLength={80}
              />
              <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending}>
                {pending ? <Spinner /> : <Plus />}
                {t("targets.addBoundary")}
              </Button>
            </form>
          </CardContent>
        </Card>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>{t("targets.targetIdentity")}</CardTitle>
            <CardDescription>{t("targets.targetCreateGuidance")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
              <Field label={t("targets.name")} name="name" required maxLength={120} />
              {choice.kind === null && (
                <div className="space-y-2">
                  <Label htmlFor="target-create-kind">{t("targets.kind")}</Label>
                  <FormSelect
                    id="target-create-kind"
                    name="kind"
                    value={targetKind}
                    onValueChange={(next) => next && setTargetKind(next)}
                    required
                    options={[
                      { value: "host", label: "host" },
                      { value: "cluster", label: "cluster" },
                      { value: "network_device", label: "network_device" },
                      { value: "bmc", label: "bmc" },
                      { value: "virtualization", label: "virtualization" },
                      { value: "custom", label: t("targets.custom") },
                    ]}
                  />
                </div>
              )}
              {choice.kind === null && targetKind === "custom" && (
                <Field label={t("targets.customKind")} name="custom_kind" required maxLength={80} />
              )}
              {choice.platform === null && (
                <div className="space-y-2">
                  <Label htmlFor="target-create-platform">{t("targets.platform")}</Label>
                  <FormSelect
                    id="target-create-platform"
                    name="platform"
                    value={targetPlatform}
                    onValueChange={(next) => next && setTargetPlatform(next)}
                    required
                    options={[
                      { value: "linux", label: "linux" },
                      { value: "kubernetes", label: "kubernetes" },
                      { value: "cisco_ios_xe", label: "cisco_ios_xe" },
                      { value: "generic", label: "generic" },
                      { value: "custom", label: t("targets.custom") },
                    ]}
                  />
                </div>
              )}
              {choice.platform === null && targetPlatform === "custom" && (
                <Field
                  label={t("targets.customPlatform")}
                  name="custom_platform"
                  required
                  maxLength={120}
                />
              )}
              <div className="space-y-2">
                <Label htmlFor="target-create-boundary">{t("targets.boundary")}</Label>
                <FormSelect
                  id="target-create-boundary"
                  name="management_boundary_id"
                  placeholder={t("targets.noBoundary")}
                  options={(boundaries ?? [])
                    .filter((item) => item.active)
                    .map((item) => ({ value: item.id, label: item.name }))}
                />
              </div>
              <div className="md:col-span-2 flex flex-wrap gap-2">
                <Button type="submit" disabled={pending || boundaries === null}>
                  {pending ? <Spinner /> : <Plus />}
                  {t("targets.addTarget")}
                </Button>
                <Button asChild type="button" variant="outline">
                  <Link to="/targets">{t("common.cancel")}</Link>
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

function loadBoundaries() {
  return collectPages((after) =>
    apiClient
      .GET("/api/v1/management-boundaries", {
        params: { query: { limit: 100, after: after ?? undefined } },
      })
      .then(apiData),
  );
}

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

function Field({
  label,
  name,
  ...props
}: React.ComponentProps<typeof Input> & { label: string; name: string }) {
  const id = "target-create-" + name;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} {...props} />
    </div>
  );
}
