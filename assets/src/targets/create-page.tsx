import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useNavigate } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";

type Boundary = components["schemas"]["ManagementBoundary"];

export function TargetCreatePage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { account } = useAuthentication();
  const [boundaries, setBoundaries] = useState<Boundary[] | null>(null);
  const [creatingBoundary, setCreatingBoundary] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const canManage = account?.role === "admin";

  useEffect(() => {
    let active = true;
    loadBoundaries()
      .then((items) => active && setBoundaries(items))
      .catch(() => active && setError(t("targets.requestFailed")));
    return () => {
      active = false;
    };
  }, [t]);

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
      const response = apiData(
        await apiClient.POST("/api/v1/targets", {
          body: {
            target: {
              name: value(form, "name"),
              kind: value(form, "kind"),
              platform: value(form, "platform"),
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
          <Link to="/targets">
            <ArrowLeft />
            {t("targets.back")}
          </Link>
        </Button>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h1 className="text-2xl font-semibold tracking-tight">
            {t(creatingBoundary ? "targets.addBoundary" : "targets.addTarget")}
          </h1>
          {canManage && (
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
        <p className="mt-2 text-muted-foreground">{t("targets.targetDescription")}</p>
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
              <Field
                label={t("targets.kind")}
                name="kind"
                list="target-kind-options"
                placeholder="host"
                required
                maxLength={80}
              />
              <datalist id="target-kind-options">
                <option value="host" />
                <option value="cluster" />
                <option value="network_device" />
                <option value="bmc" />
                <option value="virtualization" />
              </datalist>
              <Field
                label={t("targets.platform")}
                name="platform"
                list="target-platform-options"
                placeholder="linux"
                required
                maxLength={120}
              />
              <datalist id="target-platform-options">
                <option value="linux" />
                <option value="kubernetes" />
                <option value="cisco_ios_xe" />
                <option value="generic" />
              </datalist>
              <div className="space-y-2">
                <Label htmlFor="target-create-boundary">{t("targets.boundary")}</Label>
                <select
                  id="target-create-boundary"
                  name="management_boundary_id"
                  className={selectClass}
                >
                  <option value="">{t("targets.noBoundary")}</option>
                  {boundaries
                    ?.filter((item) => item.active)
                    .map((item) => (
                      <option key={item.id} value={item.id}>
                        {item.name}
                      </option>
                    ))}
                </select>
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

const selectClass =
  "flex h-10 w-full rounded-md border border-input bg-card px-3 py-2 text-sm outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/35";

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
