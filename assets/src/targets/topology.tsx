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
import { Link } from "react-router-dom";
import { useTheme } from "@/components/theme-provider";
import { Badge } from "@/components/ui/badge";
import type { Target, TargetRelationship } from "@/targets/data";

type TargetNodeData = {
  target: Target;
};

type TargetNode = Node<TargetNodeData, "target">;

type Topology = {
  nodes: TargetNode[];
  edges: Edge[];
};

const nodeWidth = 220;
const nodeHeight = 82;
const nodeTypes = { target: TargetNodeCard };

export function TargetTopology({
  targets,
  relationships,
}: {
  targets: Target[];
  relationships: TargetRelationship[];
}) {
  const { resolvedTheme } = useTheme();
  const topology = useMemo(() => layoutTargets(targets, relationships), [relationships, targets]);

  return (
    <div className="h-[28rem] overflow-hidden rounded-lg border bg-card">
      <ReactFlow
        nodes={topology.nodes}
        edges={topology.edges}
        nodeTypes={nodeTypes}
        colorMode={resolvedTheme}
        fitView
        fitViewOptions={{ padding: 0.18, maxZoom: 1.2 }}
        minZoom={0.2}
        maxZoom={1.8}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
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
  return (
    <>
      <Handle type="target" position={Position.Top} className="opacity-0" />
      <Link
        to={`/targets/${data.target.id}`}
        className="block h-full rounded-lg border bg-card p-3 text-card-foreground shadow-sm transition-colors hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <span className="flex items-start justify-between gap-2">
          <span className="truncate text-sm font-semibold">{data.target.name}</span>
          <Badge variant="outline" className="max-w-24 truncate">
            {data.target.platform}
          </Badge>
        </span>
        <span className="mt-2 block truncate text-xs text-muted-foreground">
          {data.target.kind}
        </span>
      </Link>
      <Handle type="source" position={Position.Bottom} className="opacity-0" />
    </>
  );
}

function layoutTargets(targets: Target[], relationships: TargetRelationship[]): Topology {
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
      data: { target },
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
