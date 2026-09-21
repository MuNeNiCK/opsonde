import { useMemo } from "react";
import dagre from "@dagrejs/dagre";
import {
  Background,
  BackgroundVariant,
  Controls,
  Handle,
  MarkerType,
  Position,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { BellRing, CircleAlert, Route, Server, type LucideIcon } from "lucide-react";
import { useTranslation } from "react-i18next";
import type { components } from "@/api/schema";
import { translatedToken } from "@/cases/detail-utils";
import type { WorkflowLogInput } from "@/cases/workflow-log";
import { useTheme } from "@/components/theme-provider";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

type Target = components["schemas"]["Target"];
type AccessMethod = components["schemas"]["AccessMethod"];

type Props = WorkflowLogInput & {
  targets: Target[];
  methods: AccessMethod[];
  selectedLogId: string | null;
  onSelectLog: (id: string) => void;
};

type Activity = {
  key: string;
  title: string;
  status: string;
  attempts: number;
  failed: boolean;
  order: number;
  logIds: string[];
};

type InvestigationNodeData = {
  kind: "signal" | "target" | "outcome";
  icon: LucideIcon;
  title: string;
  subtitle?: string;
  badges?: string[];
  activities: Activity[];
  active: boolean;
  failed: boolean;
  logIds: string[];
  highlighted?: boolean;
};

type InvestigationNode = Node<InvestigationNodeData, "investigation">;
type InvestigationGraph = {
  nodes: InvestigationNode[];
  edges: Edge[];
  logToNode: Map<string, string>;
};

const nodeTypes = { investigation: InvestigationNodeCard };

export function InvestigationMap(props: Props) {
  const { t } = useTranslation();
  const { resolvedTheme } = useTheme();
  const graph = useMemo(() => buildGraph(props, t), [props, t]);
  const selectedNodeId = props.selectedLogId ? graph.logToNode.get(props.selectedLogId) : undefined;
  const nodes = graph.nodes.map((node) => ({
    ...node,
    data: { ...node.data, highlighted: node.id === selectedNodeId },
  }));

  if (nodes.length === 0) {
    return (
      <div className="flex h-full items-center justify-center text-sm text-muted-foreground">
        {t("cases.workflow.map.waiting")}
      </div>
    );
  }

  return (
    <ReactFlow
      nodes={nodes}
      edges={graph.edges}
      nodeTypes={nodeTypes}
      colorMode={resolvedTheme}
      fitView
      fitViewOptions={{ padding: 0.06, maxZoom: 1 }}
      minZoom={0.25}
      maxZoom={1.35}
      nodesDraggable={false}
      nodesConnectable={false}
      elementsSelectable
      edgesFocusable={false}
      onNodeClick={(_event, node) => {
        const logId = node.data.logIds.at(-1);
        if (logId) props.onSelectLog(logId);
      }}
      proOptions={{ hideAttribution: true }}
    >
      <Background variant={BackgroundVariant.Dots} gap={20} size={1} />
      <Controls showInteractive={false} />
    </ReactFlow>
  );
}

function InvestigationNodeCard({ data }: NodeProps<InvestigationNode>) {
  const { t } = useTranslation();
  const Icon = data.icon;
  const visibleActivities = data.activities.slice(-3);
  const hiddenCount = data.activities.length - visibleActivities.length;

  return (
    <>
      <Handle type="target" position={Position.Left} className="pointer-events-none opacity-0" />
      <div
        className={cn(
          "overflow-hidden rounded-xl border bg-card text-card-foreground shadow-sm transition",
          data.active &&
            !data.failed &&
            "border-primary shadow-[0_0_0_4px_color-mix(in_oklab,var(--primary)_10%,transparent),0_10px_30px_color-mix(in_oklab,var(--primary)_12%,transparent)]",
          data.failed && "border-destructive/55",
          data.active &&
            data.failed &&
            "shadow-[0_0_0_4px_color-mix(in_oklab,var(--destructive)_10%,transparent),0_10px_30px_color-mix(in_oklab,var(--destructive)_12%,transparent)]",
          data.highlighted && "ring-2 ring-primary ring-offset-2 ring-offset-background",
        )}
      >
        <div className="flex items-start gap-3 px-4 py-3">
          <span
            className={cn(
              "relative flex size-9 shrink-0 items-center justify-center rounded-lg bg-muted text-muted-foreground",
              data.active && !data.failed && "bg-primary/10 text-primary",
              data.failed && "bg-destructive/10 text-destructive",
            )}
          >
            {data.active && (
              <span
                className={cn(
                  "absolute inset-0 animate-ping rounded-lg ring-1 ring-primary/40",
                  data.failed && "ring-destructive/40",
                )}
              />
            )}
            <Icon className="relative size-4" />
          </span>
          <span className="min-w-0 flex-1">
            <strong className="block break-words text-sm leading-5">{data.title}</strong>
            {data.subtitle && (
              <span className="mt-0.5 block break-words text-xs text-muted-foreground">
                {data.subtitle}
              </span>
            )}
          </span>
        </div>

        {data.badges && data.badges.length > 0 && (
          <div className="flex flex-wrap gap-1.5 border-t px-4 py-2">
            {data.badges.map((badge) => (
              <Badge key={badge} variant="outline" className="font-mono text-[10px]">
                {badge}
              </Badge>
            ))}
          </div>
        )}

        {visibleActivities.length > 0 && (
          <div className="border-t bg-muted/15 px-3 py-2">
            {hiddenCount > 0 && (
              <p className="px-1 pb-1 text-[10px] text-muted-foreground">
                {t("cases.workflow.map.previousSteps", { count: hiddenCount })}
              </p>
            )}
            <ul className="space-y-1">
              {visibleActivities.map((activity) => (
                <li
                  key={activity.key}
                  className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 rounded-md px-1 py-1 text-xs"
                >
                  <span
                    className={cn(
                      "size-1.5 rounded-full bg-primary",
                      activity.failed && "bg-destructive",
                    )}
                  />
                  <span className="truncate" title={activity.title}>
                    {activity.title}
                  </span>
                  <span
                    className={cn(
                      "whitespace-nowrap text-[10px] text-muted-foreground",
                      activity.failed && "text-destructive",
                    )}
                  >
                    {activity.attempts > 1 && `×${activity.attempts} · `}
                    {activity.status}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
      <Handle type="source" position={Position.Right} className="pointer-events-none opacity-0" />
    </>
  );
}

function buildGraph(props: Props, t: ReturnType<typeof useTranslation>["t"]): InvestigationGraph {
  const generationByRun = new Map(
    props.snapshot.resolution_runs.map((run) => [run.id, run.generation]),
  );
  const turnOrder = (turn: (typeof props.turns)[number]) =>
    (generationByRun.get(turn.resolution_run_id) ?? 0) * 100_000 + turn.ordinal;
  const turns = [...props.turns].sort((left, right) => turnOrder(left) - turnOrder(right));
  const proposals = props.snapshot.proposals;
  const operations = props.snapshot.operations;
  const evidence = props.evidence;
  const reviews = props.reviews;
  const approvals = props.approvals;

  const targetById = new Map(props.targets.map((target) => [target.id, target]));
  const methodById = new Map(props.methods.map((method) => [method.id, method]));
  const turnById = new Map(turns.map((turn) => [turn.id, turn]));
  const operationByProposal = new Map(
    operations.map((operation) => [operation.proposal_id, operation]),
  );
  const reviewByProposal = new Map(reviews.map((review) => [review.proposal_id, review]));
  const approvalByProposal = new Map(approvals.map((approval) => [approval.proposal_id, approval]));
  const signalEvidence = evidence.filter((item) => item.kind === "signal_event");
  const latestSignal = signalEvidence.at(-1);
  const targetActivities = new Map<string, Map<string, Activity>>();
  const targetLogIds = new Map<string, Set<string>>();
  const targetOrder = new Map<string, number>();

  for (const proposal of proposals) {
    const operation = operationByProposal.get(proposal.id);
    const turn = turnById.get(proposal.source_turn_id);
    const review = reviewByProposal.get(proposal.id);
    const approval = approvalByProposal.get(proposal.id);
    const activityKey = [
      proposal.access_method_id,
      proposal.capability,
      proposal.operation,
      JSON.stringify(proposal.selectors),
    ].join(":");
    const activities = targetActivities.get(proposal.target_id) ?? new Map<string, Activity>();
    const logIds = [
      `turn-${proposal.source_turn_id}`,
      review && `review-${review.id}`,
      approval && `approval-${approval.id}`,
      operation && `operation-${operation.id}`,
      ...evidence
        .filter((item) => item.source_ref === operation?.id)
        .map((item) => `evidence-${item.id}`),
    ].filter((value): value is string => Boolean(value));
    const failed = operation ? ["failed", "partial", "unknown"].includes(operation.status) : false;
    const status = operation
      ? translatedToken(t, "operationStatus", operation.status)
      : review
        ? translatedToken(t, "decision", review.verdict)
        : translatedToken(t, "proposalStatus", proposal.status);
    const existing = activities.get(activityKey);
    const order = turn ? turnOrder(turn) : 0;
    const latest = !existing || order >= existing.order;
    activities.set(activityKey, {
      key: activityKey,
      title: conciseOperation(proposal.operation),
      status: latest ? status : existing.status,
      attempts: (existing?.attempts ?? 0) + 1,
      failed: latest ? failed : existing.failed,
      order: Math.max(existing?.order ?? 0, order),
      logIds: [...(existing?.logIds ?? []), ...logIds],
    });
    targetActivities.set(proposal.target_id, activities);
    const allLogIds = targetLogIds.get(proposal.target_id) ?? new Set<string>();
    logIds.forEach((id) => allLogIds.add(id));
    targetLogIds.set(proposal.target_id, allLogIds);
    targetOrder.set(
      proposal.target_id,
      Math.min(
        targetOrder.get(proposal.target_id) ?? Number.MAX_SAFE_INTEGER,
        turn ? turnOrder(turn) : 0,
      ),
    );
  }

  const traversalTurns = turns.flatMap((turn) => {
    const decision = recordValue(turn.decision);
    const relationship = recordValue(decision?.relationship);
    if (textField(decision, "type") !== "target_traversal" || !relationship) return [];
    const source = textField(relationship, "source_target_id");
    const destination = textField(relationship, "destination_target_id");
    if (!source || !destination) return [];
    return [
      {
        turn,
        source,
        destination,
        kind: textField(relationship, "kind") || t("cases.workflow.map.relatedTarget"),
      },
    ];
  });

  for (const traversal of traversalTurns) {
    for (const targetId of [traversal.source, traversal.destination]) {
      const ids = targetLogIds.get(targetId) ?? new Set<string>();
      ids.add(`turn-${traversal.turn.id}`);
      targetLogIds.set(targetId, ids);
    }
    targetOrder.set(
      traversal.destination,
      Math.min(
        targetOrder.get(traversal.destination) ?? Number.MAX_SAFE_INTEGER,
        turnOrder(traversal.turn),
      ),
    );
  }

  const selectedTargetId = props.snapshot.case.selected_target_id;
  if (selectedTargetId && !targetOrder.has(selectedTargetId)) targetOrder.set(selectedTargetId, 1);
  const orderedTargetIds = [...targetOrder.entries()]
    .sort((left, right) => left[1] - right[1])
    .map(([id]) => id);
  const lastTargetId = orderedTargetIds.at(-1);
  const attention = ["needs_attention", "cancelled"].includes(props.snapshot.case.status);
  const resolved = props.snapshot.case.status === "resolved";
  const graphNodes: Array<InvestigationNode & { width: number; height: number }> = [];

  const signalContent = recordValue(latestSignal?.content);
  const signalAttributes = recordValue(signalContent?.attributes);
  const signalAnnotations = recordValue(signalAttributes?.annotations);
  const signalTitle =
    textField(signalAnnotations, "summary") ||
    textField(signalAttributes, "title") ||
    props.snapshot.case.title;
  const signalLogIds = signalEvidence.map((item) => `evidence-${item.id}`);
  graphNodes.push({
    id: "signal",
    type: "investigation",
    position: { x: 0, y: 0 },
    width: 174,
    height: 104,
    data: {
      kind: "signal",
      icon: BellRing,
      title: t("cases.workflow.phases.alert"),
      subtitle:
        textField(recordValue(signalContent?.target_ref), "value") ||
        latestSignal?.source ||
        signalTitle,
      badges: [translatedToken(t, "alert", props.snapshot.case.alert_state)],
      activities: [],
      active: orderedTargetIds.length === 0 && !attention,
      failed: false,
      logIds: signalLogIds,
    },
  });

  for (const targetId of orderedTargetIds) {
    const target = targetById.get(targetId);
    const activities = [...(targetActivities.get(targetId)?.values() ?? [])].sort(
      (left, right) => left.order - right.order,
    );
    const methodNames = [
      ...new Set(
        proposals
          .filter((proposal) => proposal.target_id === targetId)
          .map((proposal) => methodById.get(proposal.access_method_id))
          .filter((method): method is AccessMethod => Boolean(method))
          .map((method) => method.method),
      ),
    ];
    const latestActivity = activities.at(-1);
    graphNodes.push({
      id: `target-${targetId}`,
      type: "investigation",
      position: { x: 0, y: 0 },
      width: 218,
      height: 114 + Math.min(activities.length, 3) * 30,
      data: {
        kind: "target",
        icon: Server,
        title: target?.name ?? targetId,
        subtitle: target ? `${target.kind} · ${target.platform}` : undefined,
        badges: methodNames,
        activities,
        active: !attention && !resolved && targetId === lastTargetId,
        failed: Boolean(latestActivity?.failed),
        logIds: [...(targetLogIds.get(targetId) ?? [])],
      },
    });
  }

  if (attention || resolved) {
    const terminalLogs = [
      ...turns.slice(-1).map((turn) => `turn-${turn.id}`),
      ...props.timeline
        .filter((event) =>
          attention
            ? ["case_needs_attention", "case_cancelled"].includes(event.type)
            : event.type === "case_resolved",
        )
        .map((event) => `event-${event.id}`),
    ];
    graphNodes.push({
      id: "outcome",
      type: "investigation",
      position: { x: 0, y: 0 },
      width: 174,
      height: 104,
      data: {
        kind: "outcome",
        icon: attention ? CircleAlert : Route,
        title: t(`cases.status.${props.snapshot.case.status}`),
        subtitle: attention
          ? t("cases.workflow.map.stopped")
          : t("cases.workflow.map.recoveryReached"),
        activities: [],
        active: true,
        failed: attention,
        logIds: terminalLogs,
      },
    });
  }

  const edges: Edge[] = [];
  const incomingTraversal = new Set(traversalTurns.map((item) => item.destination));
  const firstTargets = orderedTargetIds.filter((targetId) => !incomingTraversal.has(targetId));
  for (const targetId of firstTargets.length > 0 ? firstTargets : orderedTargetIds.slice(0, 1)) {
    edges.push(graphEdge("signal", `target-${targetId}`, t("cases.workflow.map.investigate")));
  }
  for (const traversal of traversalTurns) {
    edges.push(
      graphEdge(
        `target-${traversal.source}`,
        `target-${traversal.destination}`,
        traversal.kind,
        traversal.destination === lastTargetId && !attention,
      ),
    );
  }
  if ((attention || resolved) && lastTargetId) {
    edges.push(
      graphEdge(
        `target-${lastTargetId}`,
        "outcome",
        attention ? t("cases.workflow.map.stoppedEdge") : t("cases.workflow.map.recoveredEdge"),
        true,
        attention,
      ),
    );
  }

  const layout = new dagre.graphlib.Graph();
  layout.setGraph({ rankdir: "LR", ranksep: 72, nodesep: 32, marginx: 12, marginy: 12 });
  layout.setDefaultEdgeLabel(() => ({}));
  graphNodes.forEach((node) => layout.setNode(node.id, { width: node.width, height: node.height }));
  edges.forEach((edge) => layout.setEdge(edge.source, edge.target));
  dagre.layout(layout);

  const nodes = graphNodes.map(({ width, height, ...node }) => ({
    ...node,
    position: {
      x: layout.node(node.id).x - width / 2,
      y: layout.node(node.id).y - height / 2,
    },
    style: { width, height },
  }));
  const logToNode = new Map<string, string>();
  nodes.forEach((node) => node.data.logIds.forEach((logId) => logToNode.set(logId, node.id)));

  return { nodes, edges, logToNode };
}

function graphEdge(
  source: string,
  target: string,
  label: string,
  animated = false,
  failed = false,
): Edge {
  const color = failed ? "var(--destructive)" : "var(--primary)";
  return {
    id: `${source}-${target}-${label}`,
    source,
    target,
    label,
    type: "smoothstep",
    animated,
    markerEnd: { type: MarkerType.ArrowClosed, color },
    style: { stroke: color, strokeWidth: animated ? 2 : 1.5 },
    labelStyle: { fill: "var(--foreground)", fontSize: 10, fontWeight: 600 },
    labelBgStyle: { fill: "var(--card)" },
    labelBgPadding: [4, 3],
    labelBgBorderRadius: 5,
  };
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function textField(value: Record<string, unknown> | undefined, key: string) {
  const field = value?.[key];
  return typeof field === "string" ? field : "";
}

function conciseOperation(operation: string) {
  const parts = operation.split(".");
  return parts.length > 2 ? parts.slice(-2).join(".") : operation;
}
