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
  type Connection,
  type Edge,
  type Node,
  type NodeProps,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { Link } from "react-router-dom";
import { useTheme } from "@/components/theme-provider";
import { Badge } from "@/components/ui/badge";
import type { AccessMethod, Target, TargetRelationship } from "@/targets/data";

type TargetNodeData = {
  target: Target;
  methods: AccessMethod[];
  editMode: boolean;
};

type TargetNode = Node<TargetNodeData, "target">;

type Topology = {
  nodes: TargetNode[];
  edges: Edge[];
};

const nodeWidth = 320;
const nodeHeight = 156;
const nodeTypes = { target: TargetNodeCard };

export function TargetTopology({
  targets,
  relationships,
  methods,
  editMode,
  draft,
  onConnect,
}: {
  targets: Target[];
  relationships: TargetRelationship[];
  methods: AccessMethod[];
  editMode: boolean;
  draft: { source: string; target: string } | null;
  onConnect: (source: string, target: string) => void;
}) {
  const { resolvedTheme } = useTheme();
  const topology = useMemo(
    () => layoutTargets(targets, relationships, methods, editMode),
    [editMode, methods, relationships, targets],
  );
  const edges = draft
    ? [
        ...topology.edges,
        {
          id: "draft-relationship",
          source: draft.source,
          target: draft.target,
          animated: true,
          markerEnd: { type: MarkerType.ArrowClosed, color: "var(--primary)" },
          style: { stroke: "var(--primary)", strokeDasharray: "5 4" },
        },
      ]
    : topology.edges;

  return (
    <div className="h-[28rem] overflow-hidden rounded-lg border bg-card">
      <ReactFlow
        nodes={topology.nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        colorMode={resolvedTheme}
        fitView
        fitViewOptions={{ padding: 0.18, maxZoom: 1.2 }}
        minZoom={0.2}
        maxZoom={1.8}
        nodesDraggable={false}
        nodesConnectable={editMode}
        onConnect={(connection: Connection) => {
          if (connection.source && connection.target && connection.source !== connection.target) {
            onConnect(connection.source, connection.target);
          }
        }}
        isValidConnection={(connection) => connection.source !== connection.target}
        edgesFocusable={false}
        proOptions={{ hideAttribution: true }}
      >
        <Background variant={BackgroundVariant.Dots} gap={20} size={1} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  );
}

function TargetNodeCard({ data }: NodeProps<TargetNode>) {
  const visibleMethods = data.methods.slice(0, 2);
  return (
    <>
      <Handle
        type="target"
        position={Position.Top}
        className={
          data.editMode
            ? "size-3 border-2 border-background bg-primary"
            : "pointer-events-none opacity-0"
        }
      />
      <Link
        to={`/targets/${data.target.id}`}
        className="block h-full rounded-lg border bg-card p-3 text-card-foreground shadow-sm transition-colors hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <span className="flex items-start justify-between gap-2">
          <span className="min-w-0 break-words text-sm font-semibold">{data.target.name}</span>
          <Badge variant="outline" className="shrink-0">
            {data.target.platform}
          </Badge>
        </span>
        <span className="mt-1 block text-xs text-muted-foreground">{data.target.kind}</span>
        <div className="mt-2 space-y-1 text-xs">
          {visibleMethods.map((method) => (
            <div key={method.id} className="flex min-w-0 items-center justify-between gap-2">
              <span className="truncate font-mono" title={method.endpoint}>
                {endpointHost(method.endpoint)}
              </span>
              <Badge variant="secondary" className="shrink-0">
                {method.method}
              </Badge>
            </div>
          ))}
          {data.methods.length === 0 && <span className="text-muted-foreground">—</span>}
          {data.methods.length > visibleMethods.length && (
            <span className="text-muted-foreground">
              +{data.methods.length - visibleMethods.length}
            </span>
          )}
        </div>
      </Link>
      <Handle
        type="source"
        position={Position.Bottom}
        className={
          data.editMode
            ? "size-3 border-2 border-background bg-primary"
            : "pointer-events-none opacity-0"
        }
      />
    </>
  );
}

function endpointHost(endpoint: string) {
  try {
    return new URL(endpoint).hostname || endpoint;
  } catch {
    return endpoint;
  }
}

function layoutTargets(
  targets: Target[],
  relationships: TargetRelationship[],
  methods: AccessMethod[],
  editMode: boolean,
): Topology {
  const targetIds = new Set(targets.map((target) => target.id));
  const visibleRelationships = relationships.filter(
    (relationship) =>
      relationship.active &&
      targetIds.has(relationship.source_target_id) &&
      targetIds.has(relationship.destination_target_id),
  );
  const graph = new dagre.graphlib.Graph({ multigraph: true });
  graph.setGraph({ rankdir: "TB", ranksep: 88, nodesep: 56, marginx: 24, marginy: 24 });
  graph.setDefaultEdgeLabel(() => ({}));
  targets.forEach((target) => graph.setNode(target.id, { width: nodeWidth, height: nodeHeight }));
  visibleRelationships.forEach((relationship) =>
    graph.setEdge(
      relationship.source_target_id,
      relationship.destination_target_id,
      {},
      relationship.id,
    ),
  );
  dagre.layout(graph);

  return {
    nodes: targets.map((target) => ({
      id: target.id,
      type: "target",
      position: {
        x: graph.node(target.id).x - nodeWidth / 2,
        y: graph.node(target.id).y - nodeHeight / 2,
      },
      data: {
        target,
        methods: methods
          .filter((method) => method.active && method.target_id === target.id)
          .sort((left, right) => left.priority - right.priority),
        editMode,
      },
      style: { width: nodeWidth, height: nodeHeight },
    })),
    edges: visibleRelationships.map((relationship) => ({
      id: relationship.id,
      source: relationship.source_target_id,
      target: relationship.destination_target_id,
      label: relationship.kind,
      type: "smoothstep",
      markerEnd: { type: MarkerType.ArrowClosed, color: "var(--muted-foreground)" },
      style: { stroke: "var(--muted-foreground)" },
      labelStyle: { fill: "var(--foreground)", fontSize: 11 },
      labelBgStyle: { fill: "var(--card)" },
      labelBgPadding: [5, 3],
      labelBgBorderRadius: 4,
    })),
  };
}
