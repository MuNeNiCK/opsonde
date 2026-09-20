import { useState, type FormEvent } from "react";
import { ArrowLeft, Boxes, Cable, Database, Network, Plus, Server } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, Navigate, useNavigate, useParams } from "react-router-dom";
import { apiClient, apiData } from "@/api/client";
import { useAuthentication } from "@/auth/context";
import { FormSelect } from "@/components/form-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import { ProviderChoiceCard } from "@/providers/choice-card";
import { targetAdapter, targetProviderChoice, targetProviderChoices } from "@/targets/adapters";

const presentations = {
  linux: { icon: Server, title: "Linux", description: "targets.choiceLinux" },
  "cisco-ios-xe": { icon: Network, title: "Cisco IOS XE", description: "targets.choiceCisco" },
  kubernetes: { icon: Boxes, title: "Kubernetes", description: "targets.choiceKubernetes" },
  generic: { icon: Cable, title: "Generic SSH", description: "targets.choiceGeneric" },
  netbox: { icon: Database, title: "NetBox", description: "targets.choiceNetBox" },
} as const;

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

export function TargetConnectionCreatePage() {
  const { family } = useParams();
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const navigate = useNavigate();
  const [error, setError] = useState("");
  const choice = targetProviderChoice(family);

  if (family && !choice) return <Navigate to="/targets/connections/new" replace />;

  return (
    <div className="space-y-6 p-6 lg:p-8">
      <div>
        <Button asChild size="sm" variant="ghost" className="mb-3 -ml-3">
          <Link to={choice ? "/targets/connections/new" : "/targets/connections"}>
            <ArrowLeft />
            {t(choice ? "targets.backToConnectionTypes" : "targets.backToConnections")}
          </Link>
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">
          {choice ? presentations[choice.id].title : t("targets.chooseProviderType")}
        </h1>
        <p className="mt-2 text-muted-foreground">
          {t(choice ? presentations[choice.id].description : "targets.chooseProviderDescription")}
        </p>
      </div>

      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {account?.role !== "admin" ? (
        <Alert>
          <AlertDescription>{t("targets.readOnly")}</AlertDescription>
        </Alert>
      ) : choice ? (
        <TargetConnectionForm
          choice={choice}
          onError={setError}
          onCreated={() =>
            void navigate("/targets/connections", {
              replace: true,
              state: { created: "target" },
            })
          }
        />
      ) : (
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          {targetProviderChoices.map(({ id }) => {
            const item = presentations[id];
            return (
              <ProviderChoiceCard
                key={id}
                to={`/targets/connections/new/${id}`}
                title={item.title}
                description={t(item.description)}
                icon={item.icon}
              />
            );
          })}
        </div>
      )}
    </div>
  );
}

function TargetConnectionForm({
  choice,
  onCreated,
  onError,
}: {
  choice: NonNullable<ReturnType<typeof targetProviderChoice>>;
  onCreated: () => void;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [adapterType, setAdapterType] = useState<string>(choice.adapterTypes[0]);
  const [authMethod, setAuthMethod] = useState("password");
  const [pending, setPending] = useState(false);
  const adapter = targetAdapter(adapterType);
  const isNetBox = choice.id === "netbox";

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    onError("");
    try {
      if (isNetBox) await createNetBox(form);
      else if (adapter) await createTarget(form, adapter.family);
      onCreated();
    } catch {
      onError(t("targets.requestFailed"));
    } finally {
      setPending(false);
    }
  }

  async function createNetBox(form: FormData) {
    const response = apiData(
      await apiClient.POST("/api/v1/providers", {
        body: {
          provider: {
            name: value(form, "name"),
            kind: "inventory",
            adapter_type: "netbox-api",
            configuration: {
              base_url: value(form, "base_url"),
              ca_certificate: value(form, "ca_certificate"),
            },
            credentials: { token: value(form, "token") },
          },
        },
      }),
    );
    await apiClient.POST("/api/v1/providers/{id}/check", {
      params: { path: { id: response.data.id } },
      body: {
        provider: {
          expected_revision: response.data.revision,
          check_input: { resource: value(form, "resource"), filters: {}, page_size: 50 },
        },
      },
    });
  }

  async function createTarget(form: FormData, family: "ssh" | "restconf" | "kubernetes") {
    const endpoint = value(form, "endpoint");
    let configuration: Record<string, unknown>;
    let credentials: Record<string, unknown>;

    if (family === "ssh") {
      configuration = { host_key_fingerprints: { [endpoint]: value(form, "fingerprint") } };
      const legacyAlgorithms = value(form, "legacy_algorithms")
        .split(",")
        .map((item) => item.trim())
        .filter(Boolean);
      if (legacyAlgorithms.length) configuration.legacy_algorithms = legacyAlgorithms;
      if (adapterType === "linux-ssh") configuration.privilege = value(form, "privilege");
      credentials = { username: value(form, "username"), auth_method: authMethod };
      credentials[authMethod === "password" ? "password" : "private_key"] = value(
        form,
        authMethod === "password" ? "password" : "private_key",
      );
    } else if (family === "restconf") {
      configuration = { ca_certificate: value(form, "ca_certificate") };
      credentials = { username: value(form, "username"), password: value(form, "password") };
    } else {
      configuration = { namespace: value(form, "namespace") };
      credentials = { kubeconfig: value(form, "kubeconfig") };
    }

    const response = apiData(
      await apiClient.POST("/api/v1/providers", {
        body: {
          provider: {
            name: value(form, "name"),
            kind: "target",
            adapter_type: adapterType,
            configuration,
            credentials,
          },
        },
      }),
    );
    await apiClient.POST("/api/v1/providers/{id}/check", {
      params: { path: { id: response.data.id } },
      body: {
        provider: {
          expected_revision: response.data.revision,
          check_input: { endpoint },
        },
      },
    });
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>{presentations[choice.id].title}</CardTitle>
        <CardDescription>{t("targets.secretDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
          <Field label={t("targets.name")} name="name" required />
          {choice.adapterTypes.length > 1 && (
            <div className="space-y-2">
              <Label htmlFor="target-adapter">{t("targets.connectionType")}</Label>
              <FormSelect
                id="target-adapter"
                value={adapterType}
                onValueChange={(next) => next && setAdapterType(next)}
                options={choice.adapterTypes.map((type) => ({
                  value: type,
                  label: targetAdapter(type)?.label ?? type,
                }))}
              />
            </div>
          )}
          {isNetBox ? (
            <NetBoxFields />
          ) : (
            <>
              <Field
                label={t("targets.endpoint")}
                name="endpoint"
                placeholder={adapter?.family === "restconf" ? "https://host:443" : "ssh://host:22"}
                required
              />
              {adapter?.family === "ssh" && (
                <SSHFields
                  adapterType={adapterType}
                  authMethod={authMethod}
                  setAuthMethod={setAuthMethod}
                />
              )}
              {adapter?.family === "restconf" && <RESTCONFFields />}
              {adapter?.family === "kubernetes" && <KubernetesFields />}
            </>
          )}
          <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending}>
            {pending ? <Spinner /> : <Plus />}
            {t("targets.addAndCheck")}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

function SSHFields({
  adapterType,
  authMethod,
  setAuthMethod,
}: {
  adapterType: string;
  authMethod: string;
  setAuthMethod: (value: string) => void;
}) {
  const { t } = useTranslation();
  return (
    <>
      <Field label={t("targets.fingerprint")} name="fingerprint" placeholder="SHA256:…" required />
      <div className="space-y-2">
        <Label htmlFor="target-legacy_algorithms">{t("targets.legacyAlgorithms")}</Label>
        <Input
          id="target-legacy_algorithms"
          name="legacy_algorithms"
          maxLength={160}
          placeholder="ssh-rsa, diffie-hellman-group14-sha1"
        />
        <p className="text-sm text-muted-foreground">{t("targets.legacyAlgorithmsDescription")}</p>
      </div>
      <Field label={t("targets.username")} name="username" autoComplete="username" required />
      <div className="space-y-2">
        <Label htmlFor="target-auth-method">{t("targets.authentication")}</Label>
        <FormSelect
          id="target-auth-method"
          value={authMethod}
          onValueChange={(next) => next && setAuthMethod(next)}
          options={[
            { value: "password", label: t("targets.password") },
            { value: "public_key", label: t("targets.privateKey") },
          ]}
        />
      </div>
      {authMethod === "password" ? (
        <Field
          label={t("targets.password")}
          name="password"
          type="password"
          autoComplete="off"
          required
        />
      ) : (
        <Area label={t("targets.privateKey")} name="private_key" required />
      )}
      {adapterType === "linux-ssh" && (
        <div className="space-y-2">
          <Label htmlFor="target-privilege">{t("targets.privilege")}</Label>
          <FormSelect
            id="target-privilege"
            name="privilege"
            defaultValue="none"
            options={[
              { value: "none", label: "none" },
              { value: "sudo", label: "sudo" },
            ]}
          />
        </div>
      )}
    </>
  );
}

function RESTCONFFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field label={t("targets.username")} name="username" autoComplete="username" required />
      <Field
        label={t("targets.password")}
        name="password"
        type="password"
        autoComplete="off"
        required
      />
      <Area label={t("targets.caCertificate")} name="ca_certificate" required />
    </>
  );
}

function KubernetesFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field label={t("targets.namespace")} name="namespace" defaultValue="default" required />
      <Area label={t("targets.kubeconfig")} name="kubeconfig" required />
    </>
  );
}

function NetBoxFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field label={t("targets.baseUrl")} name="base_url" type="url" required />
      <Field label={t("targets.token")} name="token" type="password" autoComplete="off" required />
      <div className="space-y-2">
        <Label htmlFor="netbox-resource">{t("targets.resource")}</Label>
        <FormSelect
          id="netbox-resource"
          name="resource"
          defaultValue="devices"
          options={[
            { value: "devices", label: "devices" },
            { value: "virtual_machines", label: "virtual_machines" },
          ]}
        />
      </div>
      <Area label={t("targets.caCertificate")} name="ca_certificate" required />
    </>
  );
}

function Field({
  label,
  name,
  ...props
}: React.ComponentProps<typeof Input> & { label: string; name: string }) {
  const id = `target-${name}`;
  return (
    <div className="space-y-2">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} name={name} {...props} />
    </div>
  );
}

function Area({ label, name, required }: { label: string; name: string; required?: boolean }) {
  const id = `target-${name}`;
  return (
    <div className="space-y-2 md:col-span-2">
      <Label htmlFor={id}>{label}</Label>
      <Textarea id={id} name={name} required={required} rows={5} />
    </div>
  );
}
