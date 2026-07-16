"""AI compiler — the typed AG-IR views.

The AG-IR is one graph read four ways (flowchart / CFG / dataflow / knowledge).
Each LIFT stage emits ONE view as a typed object; the assembler joins them on the
rule-id spine (`traces_to`). Every obj is walker-safe: all fields defaulted, no
`T | None`.
"""

import from .lift_types { Modality }

enum NodeType {
    GEN_RAW, GEN_ENUM, GEN_FILL, GEN_EDIT,
    ROUTE, LOOP, SPAWN, CALL,
    SENSE, ACT, CODE, TERMINAL
}
sem NodeType = "The AG-IR action-type alphabet. Mind (GEN_*) always owner=MODEL; CODE always owner=CODE; Flow/Boundary either.";
sem NodeType.GEN_ENUM = "Choose from a fixed set — the TIGHTEST Mind form. 'Classify the operation' is GEN_ENUM, not GEN_RAW.";
sem NodeType.GEN_FILL = "Fill a typed object from context (schema-validated).";
sem NodeType.GEN_EDIT = "Mutate existing content touching only what must change.";
sem NodeType.GEN_RAW = "Free-form generation — reserve for genuinely open-ended output.";
sem NodeType.SENSE = "Pull world-state in (read, grep, fetch). Idempotent.";
sem NodeType.ACT = "Push an effect out (write a file, emit the deliverable).";
sem NodeType.CODE = "Pure function of inputs — no guess, runs for free.";
sem NodeType.TERMINAL = "The single exit node; serializes produced carries into the report.";

enum Owner { MODEL, CODE }
sem Owner = "Who fires the node: MODEL needs a guess; CODE is a function of its inputs (the Owner test).";

obj AgirNode {
    has id: str = "";
    has ntype: NodeType = NodeType.GEN_RAW;
    has owner: Owner = Owner.MODEL;
    has doc: str = "";
    has reads: list[str] = [];
    has writes: list[str] = [];
    has autonomy_tools: list[str] = [];
    has surface: str = "";
    has traces_to: list[str] = [];
}
sem AgirNode = "One action in the workflow graph.";
sem AgirNode.id = "snake_case node id, unique in the graph.";
sem AgirNode.doc = "The node's semantic purpose — becomes the slot sem / routing intent.";
sem AgirNode.reads = "Carry names this node consumes (dataflow in).";
sem AgirNode.writes = "Carry names this node produces (dataflow out).";
sem AgirNode.autonomy_tools = "For an adaptive tool-using node (an INVOKE_UNIT rule): the tool names the model may ReAct over. Empty for single-shot nodes.";
sem AgirNode.surface = "For ACT nodes only: 'artifact' (a deliverable the user interacts with — must be a tool) or 'workspace' (free scratch).";
sem AgirNode.traces_to = "The spec rule ids this node realizes. NEVER empty — a node no rule demands is a hallucinated node (C1).";

obj AgirEdge {
    has src: str = "";
    has dst: str = "";
    has modality: Modality = Modality.MANDATORY;
    has guard: str = "";
    has traces_to: str = "";
}
sem AgirEdge = "A control-flow transition. FORBIDDEN rules never become edges — a forbidden path is an ABSENT path (it attaches as a node constraint instead).";
sem AgirEdge.guard = "For a ROUTE branch: the condition (e.g. \"op == MERGE\"). Empty on unconditional transitions.";

obj WorkflowView {
    has nodes: list[AgirNode] = [];
    has edges: list[AgirEdge] = [];
    has spawn_note: str = "";
    has constraints: list[str] = [];
}
sem WorkflowView = "The CFG view of the skill: every rule realized as nodes + modality-annotated edges, entry first, exactly one TERMINAL last.";
sem WorkflowView.spawn_note = "Concurrency decision: if no SPAWN node exists, WHY not (never silently omit). E.g. 'sequential: every step consumes the prior step's output'.";
sem WorkflowView.constraints = "FORBIDDEN-rule constraints as 'rule_id: <verbatim prohibition>' — enforced as slot sems, not transitions.";

obj SpineResult {
    has view: WorkflowView = WorkflowView();
    has issues: list[str] = [];
    has rounds: int = 0;
}
