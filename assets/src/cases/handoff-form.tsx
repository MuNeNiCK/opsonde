import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import type { Account } from "@/auth/context";
import { PagedSelect } from "@/components/paged-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Spinner } from "@/components/ui/spinner";

async function readAccount(id: string, signal: AbortSignal) {
  const page = await apiClient
    .GET("/api/v1/accounts", {
      params: { query: { ids: [id], limit: 1 } },
      querySerializer: commaSeparatedQuery,
      signal,
    })
    .then(apiData);
  signal.throwIfAborted();
  return page.data[0] ?? null;
}

export function CaseHandoffForm({
  ownerId,
  revision,
  pending,
  onHandoff,
}: {
  ownerId: string;
  revision: number;
  pending: boolean;
  onHandoff: (ownerId: string, revision: number) => Promise<void>;
}) {
  const { t } = useTranslation();
  const [selectedId, setSelectedId] = useState(ownerId);
  const [refresh, setRefresh] = useState(0);
  const [identity, setIdentity] = useState<{
    id: string;
    revision: number;
    refresh: number;
    account: Account | null;
    error: boolean;
  } | null>(null);
  const [checking, setChecking] = useState(false);
  const readOwner = useRef<AbortController | null>(null);
  const submission = useRef<AbortController | null>(null);
  const mounted = useRef(false);
  const current = identity?.id === selectedId ? identity : null;
  const loading = !current || current.revision !== revision || current.refresh !== refresh;
  const failed = !loading && current.error;
  const unavailable =
    !loading && !failed && (!current.account || current.account.role === "viewer");
  const selected = current?.account ? { ...current.account, name: current.account.email } : null;
  const load = useCallback(async (after: string | undefined, signal: AbortSignal) => {
    const page = await apiClient
      .GET("/api/v1/accounts", {
        params: { query: { roles: ["admin", "operator"], limit: 50, after } },
        querySerializer: commaSeparatedQuery,
        signal,
      })
      .then(apiData);
    return { ...page, data: page.data.map((account) => ({ ...account, name: account.email })) };
  }, []);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      submission.current?.abort();
    };
  }, []);
  useEffect(() => {
    const controller = new AbortController();
    readOwner.current = controller;
    void readAccount(selectedId, controller.signal)
      .then((account) => {
        if (!controller.signal.aborted)
          setIdentity({ id: selectedId, revision, refresh, account, error: false });
      })
      .catch(() => {
        if (!controller.signal.aborted)
          setIdentity((previous) => ({
            id: selectedId,
            revision,
            refresh,
            account: previous?.id === selectedId ? previous.account : null,
            error: true,
          }));
      });
    return () => controller.abort();
  }, [selectedId, revision, refresh]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (pending || checking || loading || failed || unavailable || !mounted.current) return;
    const controller = new AbortController();
    submission.current = controller;
    readOwner.current?.abort();
    setChecking(true);
    try {
      const account = await readAccount(selectedId, controller.signal);
      if (!mounted.current || controller.signal.aborted) return;
      setIdentity({ id: selectedId, revision, refresh, account, error: false });
      if (account && account.role !== "viewer") await onHandoff(selectedId, revision);
    } catch {
      if (mounted.current && !controller.signal.aborted)
        setIdentity((previous) => ({
          id: selectedId,
          revision,
          refresh,
          account: previous?.id === selectedId ? previous.account : null,
          error: true,
        }));
    } finally {
      if (mounted.current && !controller.signal.aborted) setChecking(false);
    }
  }

  return (
    <form className="space-y-3" onSubmit={submit}>
      <PagedSelect
        id="handoff-owner"
        label={t("cases.handoffTo")}
        selected={selected}
        onChange={(account) => {
          if (account) setSelectedId(account.id);
        }}
        load={load}
        disabled={pending || checking}
        placeholder={selectedId}
      />
      {selected && <Badge variant="outline">{t(`setup.accounts.roles.${selected.role}`)}</Badge>}
      {(failed || unavailable) && (
        <Alert variant="destructive">
          <AlertDescription>
            {failed ? t("cases.handoffReadFailed") : t("cases.handoffUnavailable")}
          </AlertDescription>
        </Alert>
      )}
      <div className="flex gap-2">
        <Button
          type="submit"
          size="sm"
          variant="outline"
          disabled={pending || checking || loading || failed || unavailable}
        >
          {(pending || checking) && <Spinner />}
          {t("cases.handoff")}
        </Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={pending || checking || loading}
          onClick={() => setRefresh((value) => value + 1)}
        >
          {t("common.refresh")}
        </Button>
      </div>
    </form>
  );
}
