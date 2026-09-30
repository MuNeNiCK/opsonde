import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
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
import { Textarea } from "@/components/ui/textarea";
import {
  fileReference,
  getTargetFile,
  listTargetFiles,
  type TargetFile,
} from "@/targets/file-transfer";

type Target = components["schemas"]["Target"];

export function CaseCreatePage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [search] = useSearchParams();
  const { account } = useAuthentication();
  const [sourceRef] = useState(() => crypto.randomUUID());
  const [targets, setTargets] = useState<Target[]>([]);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [targetId, setTargetId] = useState(search.get("target") ?? "");
  const [fileId, setFileId] = useState(search.get("file") ?? "");
  const [fileListing, setFileListing] = useState<{ targetId: string; items: TargetFile[] } | null>(
    null,
  );
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const files = fileListing?.targetId === targetId ? fileListing.items : [];
  const loadingFiles = canOperate && !!targetId && fileListing?.targetId !== targetId;

  useEffect(() => {
    let active = true;
    collectPages((after) =>
      apiClient
        .GET("/api/v1/targets", { params: { query: { limit: 100, after: after ?? undefined } } })
        .then(apiData),
    )
      .then((items) => active && setTargets(items.filter((item) => item.active)))
      .catch(() => active && setError(t("cases.requestFailed")));
    return () => {
      active = false;
    };
  }, [t]);

  useEffect(() => {
    let active = true;
    if (!targetId || !canOperate) return;
    listTargetFiles(targetId)
      .then((items) => {
        if (active)
          setFileListing({
            targetId,
            items: items.filter(
              (file) => file.status === "ready" && Date.parse(file.expires_at) > Date.now(),
            ),
          });
      })
      .catch(() => {
        if (active) {
          setFileListing({ targetId, items: [] });
          setError(t("files.failed"));
        }
      });
    return () => {
      active = false;
    };
  }, [targetId, canOperate, t]);

  async function create(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const value = (key: string) => {
      const entry = form.get(key);
      return typeof entry === "string" ? entry.trim() : "";
    };
    const desiredOutcome = value("desired_outcome");
    if (!desiredOutcome) {
      setError(t("cases.desiredOutcomeRequired"));
      return;
    }

    setPending(true);
    setError("");
    try {
      const attachment = fileId ? fileReference(await getTargetFile(targetId, fileId)) : null;
      const response = apiData(
        await apiClient.POST("/api/v1/cases", {
          body: {
            case: {
              trigger_kind: "manual",
              source: "web",
              source_ref: sourceRef,
              title: value("title"),
              severity: value("severity") as "info" | "warning" | "error" | "critical",
              initial_target_id: targetId || null,
              initial_context: {
                desired_outcome: desiredOutcome,
                ...(attachment ? { files: { attachment } } : {}),
                ...(value("observed_problem")
                  ? { observed_problem: value("observed_problem") }
                  : {}),
              },
            },
          },
        }),
      );
      void navigate(`/cases/${response.data.id}`);
    } catch (cause) {
      setError(
        cause instanceof Error && cause.message === "unavailable"
          ? t("files.unavailable")
          : t("cases.requestFailed"),
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6 p-6 lg:p-8">
      <Button asChild variant="ghost" size="sm">
        <Link to="/cases">
          <ArrowLeft />
          {t("cases.title")}
        </Link>
      </Button>
      <div>
        <h1 className="text-2xl font-semibold">{t("cases.createManual")}</h1>
        <p className="mt-1 text-sm text-muted-foreground">{t("cases.createManualDescription")}</p>
      </div>
      {error && (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}
      {!canOperate ? (
        <Alert>
          <AlertDescription>{t("cases.readOnly")}</AlertDescription>
        </Alert>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>{t("cases.manualRequest")}</CardTitle>
            <CardDescription>{t("cases.desiredOutcomeHelp")}</CardDescription>
          </CardHeader>
          <CardContent>
            <form className="space-y-5" onSubmit={create}>
              <div className="space-y-2">
                <Label htmlFor="case-title">{t("cases.manualTitle")}</Label>
                <Input id="case-title" name="title" required maxLength={200} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="case-desired-outcome">{t("cases.desiredOutcome")}</Label>
                <Textarea
                  id="case-desired-outcome"
                  name="desired_outcome"
                  required
                  maxLength={2000}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="case-observed-problem">{t("cases.observedProblemOptional")}</Label>
                <Textarea id="case-observed-problem" name="observed_problem" maxLength={2000} />
              </div>
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="case-target">{t("cases.initialTarget")}</Label>
                  <FormSelect
                    id="case-target"
                    name="initial_target_id"
                    placeholder={t("cases.findTarget")}
                    value={targetId || null}
                    onValueChange={(value) => {
                      setTargetId(value ?? "");
                      setFileId("");
                    }}
                    options={targets.map((target) => ({ value: target.id, label: target.name }))}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="case-severity">{t("cases.manualSeverity")}</Label>
                  <FormSelect
                    id="case-severity"
                    name="severity"
                    defaultValue="warning"
                    options={(["info", "warning", "error", "critical"] as const).map((value) => ({
                      value,
                      label: t(`cases.severity.${value}`),
                    }))}
                  />
                </div>
              </div>
              {targetId && (
                <div className="space-y-2">
                  <Label htmlFor="case-file">{t("files.select")}</Label>
                  <FormSelect
                    id="case-file"
                    value={fileId || null}
                    disabled={loadingFiles || pending}
                    placeholder={t("files.none")}
                    onValueChange={(value) => setFileId(value ?? "")}
                    options={[
                      { value: "", label: t("files.none") },
                      ...files.map((file) => ({ value: file.id, label: file.name })),
                    ]}
                  />
                  {fileId && !loadingFiles && !files.some((file) => file.id === fileId) && (
                    <p className="text-sm text-destructive">{t("files.unavailable")}</p>
                  )}
                </div>
              )}
              <Button
                type="submit"
                disabled={
                  pending || loadingFiles || !!(fileId && !files.some((file) => file.id === fileId))
                }
              >
                {pending && <Spinner />}
                {t("cases.createManual")}
              </Button>
            </form>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
