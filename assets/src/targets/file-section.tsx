import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { useAuthentication } from "@/auth/context";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Spinner } from "@/components/ui/spinner";
import {
  downloadTargetFile,
  listTargetFiles,
  revokeTargetFile,
  uploadTargetFile,
  type TargetFile,
} from "@/targets/file-transfer";

export function TargetFileSection({ targetId }: { targetId: string }) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const canOperate = account?.role === "admin" || account?.role === "operator";
  const [files, setFiles] = useState<TargetFile[]>([]);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [resumeId, setResumeId] = useState<string>();
  const [now, setNow] = useState(() => Date.now());
  const picker = useRef<HTMLInputElement>(null);
  const refresh = useCallback(async () => setFiles(await listTargetFiles(targetId)), [targetId]);
  useEffect(() => {
    let active = true;
    listTargetFiles(targetId)
      .then((items) => {
        if (active) setFiles(items);
      })
      .catch(() => {
        if (active) setError(t("files.failed"));
      });
    return () => {
      active = false;
    };
  }, [targetId, t]);

  useEffect(() => {
    const next = Math.min(
      ...files.map((file) => Date.parse(file.expires_at)).filter((time) => time > now),
    );
    if (!Number.isFinite(next)) return;
    const timer = setTimeout(() => setNow(Date.now()), Math.min(next - now + 1, 2_147_483_647));
    return () => clearTimeout(timer);
  }, [files, now]);

  async function run(action?: () => Promise<unknown>) {
    setPending(true);
    setError("");
    try {
      await action?.();
    } catch (cause) {
      const key = cause instanceof Error ? cause.message : "failed";
      setError(t(`files.${key}`, { defaultValue: t("files.failed") }));
    } finally {
      await refresh().catch(() => setError(t("files.failed")));
      setPending(false);
    }
  }

  function progress(file: TargetFile) {
    setFiles((current) => [file, ...current.filter((item) => item.id !== file.id)]);
  }

  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between gap-3">
        <CardTitle>{t("files.title")}</CardTitle>
        <div className="flex gap-2">
          <Button size="sm" variant="outline" disabled={pending} onClick={() => void run()}>
            {t("files.refresh")}
          </Button>
          {canOperate && (
            <Button
              size="sm"
              disabled={pending}
              onClick={() => {
                setResumeId(undefined);
                picker.current?.click();
              }}
            >
              {t("files.add")}
            </Button>
          )}
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        {canOperate && (
          <input
            ref={picker}
            type="file"
            className="sr-only"
            aria-label={t("files.add")}
            disabled={pending}
            onChange={(event) => {
              const input = event.currentTarget.files?.[0];
              event.currentTarget.value = "";
              if (input) void run(() => uploadTargetFile(targetId, input, progress, resumeId));
            }}
          />
        )}
        {pending && (
          <div role="status" className="flex items-center gap-2 text-sm">
            <Spinner />
            {t("files.transferring")}
          </div>
        )}
        {error && (
          <Alert variant="destructive">
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        )}
        {!files.length && <p className="text-sm text-muted-foreground">{t("files.empty")}</p>}
        {files.map((file) => {
          const expired = Date.parse(file.expires_at) <= now;
          const available = file.status === "ready" && !expired;
          return (
            <div key={file.id} className="space-y-2 border-b pb-4 last:border-0 last:pb-0">
              <div className="flex flex-wrap items-center gap-2">
                <p className="font-medium">{file.name}</p>
                <Badge variant={available ? "secondary" : "outline"}>
                  {t(`files.status.${expired ? "expired" : file.status}`)}
                </Badge>
              </div>
              <p className="text-sm text-muted-foreground">
                {file.received_bytes} / {file.size_bytes ?? "—"} B · {file.media_type}
              </p>
              <p className="text-xs text-muted-foreground">
                {t("files.expires", { date: new Date(file.expires_at).toLocaleString() })}
              </p>
              {file.sha256 && (
                <details className="text-xs text-muted-foreground">
                  <summary>SHA256</summary>
                  <p className="break-all">{file.sha256}</p>
                </details>
              )}
              {file.request_id && (
                <p className="break-all text-xs text-muted-foreground">
                  {t("files.source", { id: file.request_id })}
                </p>
              )}
              {canOperate && (
                <div className="flex flex-wrap gap-2">
                  {available && (
                    <>
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={pending}
                        onClick={() => void run(() => downloadTargetFile(targetId, file.id))}
                      >
                        {t("files.download")}
                      </Button>
                      <Button asChild size="sm" variant="outline">
                        <Link
                          to={`/cases/new?target=${encodeURIComponent(targetId)}&file=${encodeURIComponent(file.id)}`}
                        >
                          {t("files.useInCase")}
                        </Link>
                      </Button>
                    </>
                  )}
                  {file.status === "uploading" && !expired && (
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={pending}
                      onClick={() => {
                        setResumeId(file.id);
                        picker.current?.click();
                      }}
                    >
                      {t("files.resume")}
                    </Button>
                  )}
                  {(file.status === "ready" ||
                    file.status === "uploading" ||
                    file.status === "receiving") && (
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={pending}
                      onClick={() => void run(() => revokeTargetFile(targetId, file.id))}
                    >
                      {t("files.remove")}
                    </Button>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </CardContent>
    </Card>
  );
}
