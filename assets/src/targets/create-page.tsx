import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Plus, Server } from "lucide-react";
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
type Catalog = components["schemas"]["TargetTypeCatalog"];

export function TargetCreatePage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { targetType } = useParams();
  const { account } = useAuthentication();
  const [catalog, setCatalog] = useState<Catalog | null>(null);
  const [boundaries, setBoundaries] = useState<Boundary[] | null>(null);
  const [creatingBoundary, setCreatingBoundary] = useState(false);
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [success, setSuccess] = useState("");
  const canManage = account?.role === "admin";
  const choice = catalog?.types.find((item) => item.id === targetType);
  const categoryLabels = new Map(
    catalog?.categories.map((item) => [
      item.id,
      t(`targets.categoryLabels.${item.id}`, { defaultValue: item.label }),
    ]),
  );
  const visibleTypes = (catalog?.types ?? []).filter((item) => {
    const label = t(`targets.typeLabels.${item.id}`, { defaultValue: item.label });
    return (
      (category === "all" || item.category_id === category) &&
      `${label} ${item.label} ${categoryLabels.get(item.category_id) ?? ""}`
        .toLocaleLowerCase()
        .includes(search.trim().toLocaleLowerCase())
    );
  });

  useEffect(() => {
    let active = true;
    Promise.all([loadBoundaries(), apiClient.GET("/api/v1/target-types").then(apiData)])
      .then(([items, response]) => {
        if (active) {
          setBoundaries(items);
          setCatalog(response.data);
        }
      })
      .catch(() => active && setError(t("targets.requestFailed")));
    return () => {
      active = false;
    };
  }, [t]);

  if (catalog && targetType && !choice) return <Navigate to="/targets/new" replace />;

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
      if (!choice) return;
      const response = apiData(
        await apiClient.POST("/api/v1/targets", {
          body: {
            target: {
              name: value(form, "name"),
              kind: choice.kind,
              type_id: choice.id,
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
                ? t(`targets.typeLabels.${choice.id}`, { defaultValue: choice.label })
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
          {choice
            ? t(`targets.typeDescriptions.${choice.id}`, {
                defaultValue: t("targets.targetCreateGuidance"),
              })
            : t("targets.chooseTargetTypeDescription")}
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
      ) : !catalog ? (
        !error && <Spinner />
      ) : !choice ? (
        <div className="space-y-4">
          <div className="flex flex-wrap gap-3">
            <Input
              className="max-w-sm"
              aria-label={t("targets.searchTargetTypes")}
              placeholder={t("targets.searchTargetTypes")}
              value={search}
              onChange={(event) => setSearch(event.target.value)}
            />
            <FormSelect
              id="target-type-category"
              ariaLabel={t("targets.filterCategory")}
              value={category}
              onValueChange={(next) => setCategory(next ?? "all")}
              options={[
                { value: "all", label: t("targets.allCategories") },
                ...catalog.categories.map((item) => ({
                  value: item.id,
                  label: categoryLabels.get(item.id) ?? item.label,
                })),
              ]}
            />
          </div>
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {visibleTypes.map((item) => (
              <ProviderChoiceCard
                key={item.id}
                to={`/targets/new/${item.id}`}
                title={t(`targets.typeLabels.${item.id}`, { defaultValue: item.label })}
                description={t(`targets.typeDescriptions.${item.id}`, {
                  defaultValue: t("targets.targetCreateGuidance"),
                })}
                badge={categoryLabels.get(item.category_id)}
                icon={Server}
              />
            ))}
          </div>
          {visibleTypes.length === 0 && <p>{t("targets.noTargetTypes")}</p>}
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
