import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { useTranslation } from "react-i18next";
import { apiClient, apiData, commaSeparatedQuery } from "@/api/client";
import { usePagedData } from "@/api/use-paged-data";
import { useAuthentication } from "@/auth/context";
import { PageControls } from "@/components/page-controls";
import { PagedSelect } from "@/components/paged-select";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Spinner } from "@/components/ui/spinner";
import type { TargetReference, TargetSummary } from "@/targets/data";
import { TargetTopology } from "@/targets/topology";

export function TargetTopologySection({
  targetId,
  overviewTargets,
  onChange,
}: {
  targetId?: string;
  overviewTargets: TargetSummary[];
  onChange: () => Promise<unknown>;
}) {
  const { t } = useTranslation();
  const { account } = useAuthentication();
  const [editing, setEditing] = useState(false);
  const [destination, setDestination] = useState<TargetReference | null>(null);
  const [draft, setDraft] = useState<{ source: string; target: string } | null>(null);
  const [kind, setKind] = useState("hosted_by");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const mounted = useRef(false);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  const destinationId = destination?.id;
  const page = usePagedData(
    useCallback(
      async (after: string | undefined, signal: AbortSignal) => {
        const relations = await apiClient
          .GET("/api/v1/target-relationships", {
            params: { query: { target_id: targetId, active: true, limit: 50, after } },
            signal,
          })
          .then(apiData);
        signal.throwIfAborted();
        const ids = [
          ...new Set([
            ...(targetId ? [targetId] : []),
            ...relations.data.flatMap((relation) => [
              relation.source_target_id,
              relation.destination_target_id,
            ]),
            ...(destinationId ? [destinationId] : []),
          ]),
        ];
        const targets = ids.length
          ? await apiClient
              .GET("/api/v1/targets/summaries", {
                params: { query: { ids, active: true, limit: 100 } },
                querySerializer: commaSeparatedQuery,
                signal,
              })
              .then(apiData)
          : { data: [] };
        if (targetId && !targets.data.some((target) => target.id === targetId))
          throw new Error("Selected Target is unavailable");
        return {
          data: [
            {
              targets: targets.data,
              relationships: relations.data.map(
                ({ id, source_target_id, destination_target_id, kind, active }) => ({
                  id,
                  source_target_id,
                  destination_target_id,
                  kind,
                  active,
                }),
              ),
            },
          ],
          page: relations.page,
        };
      },
      [targetId, destinationId],
    ),
  );
  const frame = page.view?.data[0];
  const graphTargets = useMemo(
    () =>
      targetId
        ? (frame?.targets ?? [])
        : [
            ...new Map(
              [...overviewTargets, ...(frame?.targets ?? [])].map((target) => [target.id, target]),
            ).values(),
          ],
    [targetId, frame, overviewTargets],
  );
  const loadDestinations = useCallback(
    (after: string | undefined, signal: AbortSignal) =>
      apiClient
        .GET("/api/v1/targets/references", {
          params: { query: { active: true, exclude_id: targetId, limit: 50, after } },
          signal,
        })
        .then(apiData),
    [targetId],
  );

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft || saving) return;
    setSaving(true);
    setSaveError(false);
    try {
      await apiClient.POST("/api/v1/target-relationships", {
        body: {
          relationship: {
            source_target_id: draft.source,
            destination_target_id: draft.target,
            kind,
            facts: {},
            valid_until: null,
          },
        },
      });
      if (!mounted.current) return;
      setDraft(null);
      await page.reload();
      if (mounted.current) await onChange();
    } catch {
      if (mounted.current) setSaveError(true);
    } finally {
      if (mounted.current) {
        setSaving(false);
        setDraft(null);
      }
    }
  }

  return (
    <section className="space-y-3" aria-label={t("targets.topology")}>
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-xl font-semibold">{t("targets.topology")}</h2>
          <p className="mt-1 text-sm text-muted-foreground">
            {frame
              ? t(targetId ? "targets.topologyScope" : "targets.topologyOverview", {
                  count: frame.relationships.length,
                })
              : t("targets.topologyDescription")}
          </p>
        </div>
        {account?.role === "admin" && (
          <Button
            variant="outline"
            disabled={saving}
            onClick={() => {
              setEditing(!editing);
              setDestination(null);
              setDraft(null);
            }}
          >
            {t(editing ? "common.cancel" : "targets.addRelationship")}
          </Button>
        )}
      </div>
      {(page.error != null || saveError) && (
        <Alert variant="destructive">
          <AlertDescription>{t("targets.requestFailed")}</AlertDescription>
          <Button
            variant="outline"
            disabled={page.pending || saving}
            onClick={() =>
              void page
                .retry()
                .then(async () => {
                  if (!mounted.current) return;
                  if (saveError) await onChange();
                  if (mounted.current) setSaveError(false);
                })
                .catch(() => {
                  if (mounted.current) setSaveError(true);
                })
            }
          >
            {t("common.refresh")}
          </Button>
        </Alert>
      )}
      {page.pending && (
        <div className="flex items-center gap-2">
          <Spinner />
          {t("common.loading")}
        </div>
      )}
      {frame && (
        <>
          <PageControls
            index={page.view?.index ?? 0}
            hasNext={!!page.view?.page.next}
            pending={page.pending || saving}
            previous={page.previous}
            next={page.next}
          />
          <TargetTopology
            targets={graphTargets}
            relationships={frame.relationships}
            editMode={editing && !saving && !page.pending}
            draft={draft}
            onConnect={(source, target) => setDraft({ source, target })}
          />
        </>
      )}
      {editing && (
        <div className="space-y-3 rounded-lg border p-4">
          <p className="text-sm text-muted-foreground">
            {t("targets.connectRelationshipInstruction")}
          </p>
          {targetId && (
            <PagedSelect
              id="topology-destination"
              label={t("targets.destinationTarget")}
              placeholder={t("targets.chooseTarget")}
              selected={destination}
              load={loadDestinations}
              disabled={saving}
              onChange={(target) => {
                setDestination(target);
                setDraft(target ? { source: targetId, target: target.id } : null);
              }}
            />
          )}
          {draft && (
            <form className="flex flex-wrap items-end gap-3" onSubmit={(event) => void save(event)}>
              <p className="text-sm">
                {graphTargets.find((target) => target.id === draft.source)?.name} →{" "}
                {graphTargets.find((target) => target.id === draft.target)?.name}
              </p>
              <div className="space-y-2">
                <label htmlFor="topology-kind" className="text-sm">
                  {t("targets.relationshipKind")}
                </label>
                <Input
                  id="topology-kind"
                  value={kind}
                  onChange={(event) => setKind(event.target.value)}
                  required
                  maxLength={80}
                />
              </div>
              <Button type="submit" disabled={saving || page.pending || page.error != null}>
                {saving && <Spinner />}
                {t("targets.saveRelationship")}
              </Button>
            </form>
          )}
        </div>
      )}
    </section>
  );
}
