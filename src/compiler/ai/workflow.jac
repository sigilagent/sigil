"""AI compiler — Stage 2: the WorkFlow spine (frozen RuleSet -> WorkflowView).

The P1/P2/P3 pass: type every STEP rule (tightest GEN-*), owner-test it, wire the
modality-annotated CFG. Runs BEFORE the annotator flows because it mints the node
ids they attach to.

Same shape as the spec loop — the model proposes the view, a CODE validator
disposes (spine-level C1 + structure + the granularity discipline), and the loop
re-prompts with the validator's issues, bounded. The validator enforces:

- C1 soundness: every node traces to real rule ids (no hallucinated nodes).
- C1 completeness / no-monolith precursor: every MANDATORY STEP/IO rule is
  realized by >=1 node — a mandate folded into some other node's interior is
  exactly the `monolithic` failure the OSP-loser postmortem named.
- Cognition preservation (anti-shred): an INVOKE_UNIT rule maps to exactly ONE
  model-owned Mind node — shredding an observe-and-adapt loop into fixed calls
  destroys the adaptation; the envelope (autonomy_tools, budget) is the mandate.
- Forbidden-as-absent: no edge traces to a FORBIDDEN rule (prohibitions become
  node constraints, never transitions).
- Structure: unique ids, exactly one TERMINAL, edges resolve, no dead ends, all
  nodes reachable, guarded fan-outs, and an explicit spawn_note (concurrency is
  decided, never silently omitted).
"""

import from jaclang.byllm.lib { Model }
import from .lift_types { Modality, RuleKind, Cohesion }
import from .spec_loop { Rule, RuleSet }
import from .ir_views { NodeType, Owner }

# NOTE: objs that ride a `by llm` slot's return schema are defined IN the
# slot's module — byllm's schema builder cannot resolve a nested obj from
# another module ("'str' object has no attribute 'fields'"); cross-module
# ENUMS are fine.

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

glob wf_llm: any = Model(model_name="gpt-4o-mini");
glob _WF_PINNED: bool = False;

def pin_workflow_llm(m: any) -> None {
    wf_llm = m;
    _WF_PINNED = True;
}

# ---------------------------------------------------------------------------
# model proposes
# ---------------------------------------------------------------------------

sem workflow_view = """Design the workflow graph (CFG view) that realizes EVERY
rule of the spec — nothing added, nothing dropped, nothing re-modalized. Apply,
in order:
(P1, the Owner test) For each step ask: is the output a function of the inputs —
mechanizable without a guess? Yes -> owner=CODE (a CODE/SENSE/ACT/ROUTE node).
Needs a guess -> owner=MODEL.
(P2, tighten) Every surviving MODEL node gets the TIGHTEST Mind type:
GEN_ENUM > GEN_FILL > GEN_EDIT > GEN_RAW. 'Classify/choose' is GEN_ENUM;
'produce the parameters' is GEN_FILL; reserve GEN_RAW for open-ended bodies.
(Granularity — two-sided) Decompose to the COARSEST granularity that still
exposes every enforceable mandate as its own node — no finer. A rule tagged
INVOKE_UNIT (adaptive tool use: 'explore...', 'iterate until...') stays ONE
model-owned node with its tools in autonomy_tools — never shredded into fixed
calls. Conversely never fold several MANDATORY rules into one big authoring
node — each mandate gets its own node so the structure can enforce it.
(Presentational rules are NOT enforceable structure) A rule whose whole content
is speaking to the human — 'announce ...', 'tell/inform the user ...', 'state
that ...', 'present/offer <fixed text>' — has no verifiable post-condition: no
artifact, no carry any later node reads, nothing a gate could check. It is NOT a
node. Attach its rule id to the traces_to of a nearby node so it stays realized
without manufacturing a step — but NOT a node that produces an artifact (its
narration would leak into that artifact; see the `target` guidance); prefer a
non-producing node, else keep it as a constraint note. The ONLY exception is a presentation whose
answer drives control flow (a human gate / approval prompt): that IS structure —
keep it, wired to its guard. This is the coarse-granularity principle, not an
exception to completeness: every rule still appears in some node's traces_to.
(Wiring) Entry node first, exactly one TERMINAL last. Edge modality comes from
the rule's modality. Every ROUTE fan-out edge carries a guard. FORBIDDEN rules
become entries in `constraints` ('rule_id: prohibition'), NEVER edges or nodes.
(Concurrency) If independent branches share no moving data, add a SPAWN node;
otherwise set spawn_note explaining why the flow is sequential. Never leave the
decision implicit.
(Human gates) A route that consumes human feedback (approval, confirmation,
review response) is owner=CODE with explicit string-match guards — the human's
words bind control flow directly; model judgment must never sit between them.
(Artifact boundary) Every MANDATORY IO rule ends in an ACT node with
surface 'artifact' that READS the content carry it must write — a deliverable
authored into a carry but never written is a dropped artifact.
(Provenance) Every node lists the rule ids it realizes in traces_to. The TASK
overrides the SKILL: keep conditional guidance conditional.
If ISSUES from the validator are given, fix exactly those — keep everything
else stable (ids included).""";
sem workflow_view.spec = "The frozen RuleSet — the complete, grounded spec.";
sem workflow_view.skill = "The original skill text, for context. The spec is the contract; the text disambiguates.";
sem workflow_view.issues = "Validator issues from the previous round to fix (empty on round one).";
sem workflow_view.target = """The model that will EXECUTE this graph, node by
node — NOT the model designing it. You compile FOR it, like a cross-compiler
targeting a specific ISA. When it names a small or local model (an 8B, a quantized
local model, anything below frontier), design defensively for a weak executor:
(a) each cognitive node's output IS its deliverable carry and nothing else — NEVER
fold speak-to-the-human narration ('announce...', 'tell them...') into the doc of
a node that PRODUCES an artifact; a weak model emits the narration as part of the
artifact (an 'announce' folded into a header node becomes the first line of the
header). Attach such a rule to a NON-producing node, or if none exists, keep it as
a constraint note — never a producing node's output contract. (b) Pass every input
a node needs EXPLICITLY in its reads, especially the task — a weak model loses the
thread when a value is implicit. (c) Prefer the TIGHTEST slot type: an ENUM/FILL a
weak model can't wander out of beats an open GEN_RAW. (d) One unambiguous
responsibility per node. If the target is blank or a frontier model, design
normally.""";
def workflow_view(spec: RuleSet, skill: str, issues: str, target: str) -> WorkflowView by wf_llm();

# ---------------------------------------------------------------------------
# code disposes — the spine validator
# ---------------------------------------------------------------------------

glob MIND_TYPES: list = [NodeType.GEN_RAW, NodeType.GEN_ENUM, NodeType.GEN_FILL, NodeType.GEN_EDIT];

def validate_spine(spec: RuleSet, wf: WorkflowView) -> list[str] {
    issues: list = [];
    rule_ids = [r.id for r in spec.rules];
    rule_by_id: dict = {};
    for r in spec.rules { rule_by_id[r.id] = r; }
    node_ids = [n.id for n in wf.nodes];

    # -- structure ----------------------------------------------------------
    if not wf.nodes { return ["empty graph: no nodes"]; }
    seen: list = [];
    for nid in node_ids {
        if nid in seen { issues.append(f"duplicate node id '{nid}'"); }
        else { seen.append(nid); }
    }
    terminals = [n.id for n in wf.nodes if n.ntype == NodeType.TERMINAL];
    if len(terminals) != 1 {
        issues.append(f"need exactly one TERMINAL node, found {len(terminals)}");
    }
    for e in wf.edges {
        if e.src not in node_ids { issues.append(f"edge from unknown node '{e.src}'"); }
        if e.dst not in node_ids { issues.append(f"edge to unknown node '{e.dst}'"); }
    }
    # dead ends + reachability (from the first node)
    for n in wf.nodes {
        if n.ntype == NodeType.TERMINAL { continue; }
        outs = [e for e in wf.edges if e.src == n.id];
        if not outs { issues.append(f"dead end: non-terminal node '{n.id}' has no out-edge"); }
        if (len(outs) > 1) and (n.ntype != NodeType.ROUTE) and (n.ntype != NodeType.SPAWN) {
            issues.append(f"unguarded fan-out: node '{n.id}' has {len(outs)} out-edges but is not a ROUTE/SPAWN");
        }
        if (n.ntype == NodeType.ROUTE) and (n.owner == Owner.CODE) {
            for e2 in outs {
                if not e2.guard.strip() { issues.append(f"ROUTE '{n.id}' branch to '{e2.dst}' has no guard"); }
            }
        }
    }
    if wf.nodes {
        reached: list = [wf.nodes[0].id];
        frontier: list = [wf.nodes[0].id];
        while frontier {
            cur = frontier.pop();
            for e in wf.edges {
                if (e.src == cur) and (e.dst not in reached) {
                    reached.append(e.dst);
                    frontier.append(e.dst);
                }
            }
        }
        for nid2 in node_ids {
            if nid2 not in reached { issues.append(f"unreachable node '{nid2}'"); }
        }
    }
    # concurrency decided, never implicit
    has_spawn = False;
    for n in wf.nodes { if n.ntype == NodeType.SPAWN { has_spawn = True; } }
    if (not has_spawn) and (not wf.spawn_note.strip()) {
        issues.append("no SPAWN node and no spawn_note — decide concurrency explicitly");
    }

    # -- C1 soundness: no hallucinated provenance ---------------------------
    for n in wf.nodes {
        if (not n.traces_to) and (n.ntype != NodeType.TERMINAL) {
            # TERMINAL is structural (serializes the report) — every other node
            # must be demanded by a rule or it is an added behavior (C1).
            issues.append(f"node '{n.id}' traces to no rule (hallucinated node?)");
        }
        for t in n.traces_to {
            if t not in rule_ids { issues.append(f"node '{n.id}' traces to unknown rule '{t}'"); }
        }
    }

    # -- C1 completeness / no-monolith precursor ----------------------------
    traced: list = [];
    for n in wf.nodes { for t in n.traces_to { traced.append(t); } }
    for r in spec.rules {
        if (r.modality == Modality.MANDATORY) and ((r.kind == RuleKind.STEP) or (r.kind == RuleKind.IO)) {
            if r.id not in traced {
                # concatenation, not an f-string: a slice + nested quotes inside
                # f-string braces mis-compiles (the quote after the id is eaten)
                issues.append("MANDATORY rule '" + r.id + "' realized by no node ('" + str(r.quote)[:60] + "')");
            }
        }
    }

    # -- forbidden-as-absent -------------------------------------------------
    forbidden_ids = [r.id for r in spec.rules if r.modality == Modality.FORBIDDEN];
    for e in wf.edges {
        if e.traces_to in forbidden_ids {
            issues.append(f"edge {e.src}->{e.dst} traces to FORBIDDEN rule '{e.traces_to}' — prohibitions are constraints, never transitions");
        }
    }
    con_ids = [c.split(":")[0].strip() for c in wf.constraints if ":" in c];
    for fid in forbidden_ids {
        if (fid not in con_ids) and (fid not in traced) {
            issues.append(f"FORBIDDEN rule '{fid}' appears in no constraints entry");
        }
    }

    # -- cognition preservation (anti-shred) --------------------------------
    for r in spec.rules {
        if r.cohesion != Cohesion.INVOKE_UNIT { continue; }
        owners = [n for n in wf.nodes if r.id in n.traces_to];
        if len(owners) > 1 {
            frag = ", ".join([n.id for n in owners]);
            issues.append(f"INVOKE_UNIT rule '{r.id}' shredded across nodes [{frag}] — keep it ONE adaptive node");
        } elif len(owners) == 1 {
            n3 = owners[0];
            if (n3.owner != Owner.MODEL) or (n3.ntype not in MIND_TYPES) {
                issues.append(f"INVOKE_UNIT rule '{r.id}' lowered to a non-cognitive node '{n3.id}' — it needs a model-owned Mind node with an autonomy tool-belt");
            }
        }
    }
    return issues;
}

# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------

def workflow_spine(spec: RuleSet, skill: str, max_rounds: int = 0, target: str = "") -> SpineResult {
    # Bounded model-propose / code-dispose loop. On exhaustion, returns the last
    # view WITH its outstanding issues — an honest failure, never a silent one.
    wf = WorkflowView();
    issues: list = [];
    rounds = 0;
    digest = "";
    # auto budget: spine rounds scale with spec size (3 for toys, up to 6)
    cap = max_rounds if (max_rounds > 0) else min(6, max(3, 2 + len(spec.rules) // 30));
    while rounds < cap {
        wf = workflow_view(spec, skill, digest, target);
        issues = validate_spine(spec, wf);
        rounds += 1;
        if not issues { break; }
        digest = "FIX EXACTLY THESE:\n- " + "\n- ".join([str(i) for i in issues]);
    }
    return SpineResult(view=wf, issues=issues, rounds=rounds);
}

