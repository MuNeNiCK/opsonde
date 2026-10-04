import { useState, type FormEvent } from "react";
import { Plus } from "lucide-react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData } from "@/api/client";
import { FormSelect } from "@/components/form-select";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import type { Provider, TargetTypeCatalog } from "@/targets/data";

export type ConnectionChoice = Pick<
  TargetTypeCatalog["types"][number],
  "id" | "label" | "access_method_types"
>;
export type CreatedConnection = { provider: Provider; endpoint?: string; checkPassed?: boolean };

function value(form: FormData, name: string) {
  const entry = form.get(name);
  return typeof entry === "string" ? entry : "";
}

export function TargetConnectionForm({
  choice,
  catalog,
  onCreated,
  onError,
}: {
  choice: ConnectionChoice;
  catalog: TargetTypeCatalog;
  onCreated: (connection: CreatedConnection) => void | Promise<void>;
  onError: (message: string) => void;
}) {
  const { t } = useTranslation();
  const [adapterType, setAdapterType] = useState<string>(choice.access_method_types[0] ?? "");
  const [authMethod, setAuthMethod] = useState("password");
  const [pending, setPending] = useState(false);
  const [created, setCreated] = useState<CreatedConnection | null>(null);
  const adapter = catalog.methods.find((method) => method.adapter_type === adapterType);
  const isNetBox = choice.id === "netbox";

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    onError("");
    try {
      const connection = isNetBox
        ? await createNetBox(form)
        : adapter
          ? await createTarget(form, adapter.protocol)
          : null;
      if (connection) await onCreated(connection);
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
            registration_id: crypto.randomUUID(),
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
    try {
      const checked = apiData(
        await apiClient.POST("/api/v1/providers/{id}/check", {
          params: { path: { id: response.data.id } },
          body: {
            provider: {
              expected_revision: response.data.revision,
              check_input: { resource: value(form, "resource"), filters: {}, page_size: 50 },
            },
          },
        }),
      );
      return { provider: checked.data, checkPassed: checked.data.check.status === "passed" };
    } catch {
      return { provider: response.data, checkPassed: false };
    }
  }

  async function createTarget(
    form: FormData,
    family: TargetTypeCatalog["methods"][number]["protocol"],
  ) {
    const endpoint = created?.endpoint ?? value(form, "endpoint");
    let configuration: Record<string, unknown>;
    let credentials: Record<string, unknown>;

    if (family === "ssh" || family === "netconf") {
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
    } else if (family === "http") {
      configuration = {};
      if (value(form, "ca_certificate"))
        configuration.ca_certificate = value(form, "ca_certificate");
      credentials = value(form, "token") ? { bearer_token: value(form, "token") } : {};
    } else if (family === "restconf") {
      configuration = { ca_certificate: value(form, "ca_certificate") };
      credentials = { username: value(form, "username"), password: value(form, "password") };
    } else if (family === "redfish") {
      configuration = {
        ca_certificate: value(form, "ca_certificate"),
      };
      if (value(form, "system_path")) configuration.system_path = value(form, "system_path");
      if (value(form, "expected_uuid")) configuration.expected_uuid = value(form, "expected_uuid");
      credentials = { username: value(form, "username"), password: value(form, "password") };
    } else if (family === "ipmi") {
      configuration = {
        privilege_level: Number(value(form, "privilege_level")),
        cipher_suite:
          value(form, "cipher_suite") === "auto" ? "auto" : Number(value(form, "cipher_suite")),
      };
      credentials = { username: value(form, "username"), password: value(form, "password") };
    } else if (family === "kubernetes") {
      configuration = value(form, "namespace") ? { namespace: value(form, "namespace") } : {};
      credentials = { kubeconfig: value(form, "kubeconfig") };
    } else {
      throw new Error(t("targets.requestFailed"));
    }

    const response = created
      ? apiData(
          await apiClient.GET("/api/v1/providers/{id}", {
            params: { path: { id: created.provider.id } },
          }),
        )
      : apiData(
          await apiClient.POST("/api/v1/providers", {
            body: {
              provider: {
                registration_id: crypto.randomUUID(),
                name: value(form, "name"),
                kind: "target",
                adapter_type: adapterType,
                configuration,
                credentials,
              },
            },
          }),
        );
    setCreated({ provider: response.data, endpoint });
    const enabled = response.data.enabled
      ? response
      : apiData(
          await apiClient.POST("/api/v1/providers/{id}/enable", {
            params: { path: { id: response.data.id } },
            body: { provider: { expected_revision: response.data.revision } },
          }),
        );
    return { provider: enabled.data, endpoint };
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle>
          {t(`targets.typeLabels.${choice.id}`, { defaultValue: choice.label })}
        </CardTitle>
        <CardDescription>{t("targets.secretDescription")}</CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4 md:grid-cols-2" onSubmit={create}>
          <fieldset className="contents" disabled={created !== null}>
            <Field label={t("targets.name")} name="name" required />
            {choice.access_method_types.length > 1 && (
              <div className="space-y-2">
                <Label htmlFor="target-adapter">{t("targets.connectionType")}</Label>
                <FormSelect
                  id="target-adapter"
                  value={adapterType}
                  onValueChange={(next) => next && setAdapterType(next)}
                  options={choice.access_method_types.map((type) => ({
                    value: type,
                    label:
                      catalog.methods.find((method) => method.adapter_type === type)?.label ?? type,
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
                  placeholder={
                    adapter?.protocol === "http"
                      ? "https://service.example.com"
                      : adapter?.protocol === "restconf" ||
                          adapter?.protocol === "redfish" ||
                          adapter?.protocol === "kubernetes"
                        ? "https://device.example.com:443"
                        : adapter?.protocol === "ipmi"
                          ? "ipmi://bmc.example.com:623"
                          : "ssh://host:22"
                  }
                  required
                />
                {(adapter?.protocol === "ssh" || adapter?.protocol === "netconf") && (
                  <SSHFields
                    adapterType={adapterType}
                    authMethod={authMethod}
                    setAuthMethod={setAuthMethod}
                  />
                )}
                {adapter?.protocol === "restconf" && <RESTCONFFields />}
                {adapter?.protocol === "http" && <HTTPFields />}
                {adapter?.protocol === "redfish" && <RedfishFields />}
                {adapter?.protocol === "ipmi" && <IPMIFields />}
                {adapter?.protocol === "kubernetes" && <KubernetesFields />}
              </>
            )}
          </fieldset>
          <Button type="submit" className="md:col-span-2 md:w-fit" disabled={pending}>
            {pending ? <Spinner /> : <Plus />}
            {t(
              isNetBox
                ? "targets.addAndCheck"
                : created
                  ? "targets.enableConnection"
                  : "targets.addConnection",
            )}
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

function HTTPFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field label={t("targets.token")} name="token" type="password" autoComplete="off" />
      <Area label={t("targets.caCertificate")} name="ca_certificate" />
    </>
  );
}

function RedfishFields() {
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
      <Field
        label={t("targets.redfishSystemPath")}
        name="system_path"
        placeholder="/redfish/v1/Systems/1"
      />
      <Field label={t("targets.redfishSystemUuid")} name="expected_uuid" />
      <Area label={t("targets.caCertificate")} name="ca_certificate" required />
    </>
  );
}

function IPMIFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field
        label={t("targets.username")}
        name="username"
        autoComplete="username"
        maxLength={16}
        required
      />
      <Field
        label={t("targets.password")}
        name="password"
        type="password"
        autoComplete="off"
        maxLength={20}
        required
      />
      <div className="space-y-2">
        <Label htmlFor="target-ipmi-privilege">{t("targets.ipmiPrivilege")}</Label>
        <FormSelect
          id="target-ipmi-privilege"
          name="privilege_level"
          defaultValue="4"
          options={[
            { value: "1", label: "Callback" },
            { value: "2", label: "User" },
            { value: "3", label: "Operator" },
            { value: "4", label: "Administrator" },
            { value: "5", label: "OEM" },
          ]}
        />
      </div>
      <div className="space-y-2">
        <Label htmlFor="target-ipmi-cipher">{t("targets.ipmiCipher")}</Label>
        <FormSelect
          id="target-ipmi-cipher"
          name="cipher_suite"
          defaultValue="auto"
          options={[
            { value: "auto", label: t("targets.ipmiCipherAuto") },
            ...Array.from({ length: 18 }, (_, index) => ({
              value: String(index),
              label: String(index),
            })),
          ]}
        />
      </div>
    </>
  );
}

function KubernetesFields() {
  const { t } = useTranslation();
  return (
    <>
      <Field
        label={t("targets.namespace")}
        name="namespace"
        placeholder={t("targets.allNamespaces")}
      />
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
