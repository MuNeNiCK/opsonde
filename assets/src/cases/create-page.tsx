import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { ArrowLeft } from "lucide-react";
import { useTranslation } from "react-i18next";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { apiClient, apiData, collectPages } from "@/api/client";
import type { components } from "@/api/schema";
import { useAuthentication } from "@/auth/context";
import { FormSelect } from "@/components/form-select";
import { PageControls } from "@/components/page-controls";
import { usePagedData } from "@/api/use-paged-data";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Spinner } from "@/components/ui/spinner";
import { Textarea } from "@/components/ui/textarea";
import { fileReference, getTargetFile, type TargetFile } from "@/targets/file-transfer";

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
  const [selection, setSelection] = useState<{
    targetId: string;
    id: string;
    file: TargetFile | null;
    revision: number;
    error: boolean;
  } | null>(null);
  const [refreshFile, setRefreshFile] = useState(0);
  const [now, setNow] = useState(() => Date.now());
  const mounted = useRef(false);
  const submissionRead = useRef<AbortController | null>(null);
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const selected = selection?.targetId === targetId && selection.id === fileId ? selection : null;
  const filePage = usePagedData(
    useCallback(
      (after: string | undefined, signal: AbortSignal) =>
        targetId && canOperate
          ? apiClient
              .GET("/api/v1/targets/{target_id}/files", {
                params: { path: { target_id: targetId }, query: { limit: 50, after } },
                signal,
              })
              .then(apiData)
          : Promise.resolve({ data: [] as TargetFile[], page: { next: null } }),
      [targetId, canOperate],
    ),
  );
  const available = (file: TargetFile) =>
    file.status === "ready" &&
    file.size_bytes != null &&
    file.sha256 != null &&
    Date.parse(file.expires_at) > now;
  const files = (filePage.view?.data ?? []).filter(
    (file) => available(file) && file.id !== selected?.file?.id,
  );
  if (selected?.file) files.push(selected.file);
  const loadingFile = !!fileId && (!selected || selected.revision !== refreshFile);
  const fileError = selected?.revision === refreshFile && selected.error;
  const unavailableFile =
    !!fileId &&
    !!selected &&
    !loadingFile &&
    !fileError &&
    (!selected.file || !available(selected.file));

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      submissionRead.current?.abort();
    };
  }, []);
  const nextExpiry = Math.min(
    ...files.map((file) => Date.parse(file.expires_at)).filter((time) => time > now),
  );
  useEffect(() => {
    if (!Number.isFinite(nextExpiry)) return;
    const timer = setTimeout(
      () => setNow(Date.now()),
      Math.min(nextExpiry - now + 1, 2_147_483_647),
    );
    return () => clearTimeout(timer);
  }, [nextExpiry, now]);

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
    if (!targetId || !fileId || !canOperate) return;
    const controller = new AbortController();
    void getTargetFile(targetId, fileId, controller.signal)
      .then((file) => {
        if (!controller.signal.aborted)
          setSelection({ targetId, id: fileId, file, revision: refreshFile, error: false });
      })
      .catch(() => {
        if (!controller.signal.aborted)
          setSelection((previous) => ({
            targetId,
            id: fileId,
            file: previous?.targetId === targetId && previous.id === fileId ? previous.file : null,
            revision: refreshFile,
            error: true,
          }));
      });
    return () => controller.abort();
  }, [targetId, fileId, canOperate, refreshFile]);

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
    const controller = new AbortController();
    submissionRead.current = controller;
    try {
      let attachment = null;
      if (fileId) {
        const file = await getTargetFile(targetId, fileId, controller.signal);
        if (controller.signal.aborted) return;
        setSelection({ targetId, id: fileId, file, revision: refreshFile, error: false });
        attachment = fileReference(file);
      }
      if (!mounted.current) return;
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
      if (mounted.current) void navigate(`/cases/${response.data.id}`);
    } catch (cause) {
      if (mounted.current)
        setError(
          cause instanceof Error && cause.message === "unavailable"
            ? t("files.unavailable")
            : t("cases.requestFailed"),
        );
    } finally {
      if (mounted.current) setPending(false);
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
                    disabled={pending}
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
                <div className="space-y-2" role="group" aria-label={t("files.select")}>
                  <Label htmlFor="case-file">{t("files.select")}</Label>
                  <FormSelect
                    key={`${targetId}:${fileId}`}
                    id="case-file"
                    value={fileId || null}
                    disabled={filePage.pending || loadingFile || pending}
                    placeholder={t("files.none")}
                    onValueChange={(value) => setFileId(value ?? "")}
                    options={[
                      { value: "", label: t("files.none") },
                      ...files.map((file) => ({
                        value: file.id,
                        label: file.name,
                        disabled: !available(file),
                      })),
                    ]}
                  />
                  <PageControls
                    index={filePage.view?.index ?? 0}
                    hasNext={!!filePage.view?.page.next}
                    pending={filePage.pending || pending}
                    previous={filePage.previous}
                    next={filePage.next}
                  />
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={pending || filePage.pending || loadingFile}
                    onClick={() => {
                      setRefreshFile((revision) => revision + 1);
                      void filePage.retry().catch(() => {});
                    }}
                  >
                    {t("files.refresh")}
                  </Button>
                  {(filePage.error != null || fileError) && (
                    <Alert variant="destructive">
                      <AlertDescription>{t("files.failed")}</AlertDescription>
                    </Alert>
                  )}
                  {unavailableFile && (
                    <p className="text-sm text-destructive">{t("files.unavailable")}</p>
                  )}
                </div>
              )}
              <Button
                type="submit"
                disabled={pending || loadingFile || unavailableFile || fileError}
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
