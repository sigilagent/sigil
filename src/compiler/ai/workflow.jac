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
import from .lift_types { Rule, RuleSet, Modality, RuleKind, Cohesion }
import from .ir_views { NodeType, Owner, AgirNode, AgirEdge, WorkflowView, SpineResult }

glob wf_llm: any = Model(model_name="gpt-4o-mini");
glob _WF_PINNED: bool = False;

def pin_workflow_llm(m: any) -> None {
    global wf_llm, _WF_PINNED;
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
(Wiring) Entry node first, exactly one TERMINAL last. Edge modality comes from
the rule's modality. Every ROUTE fan-out edge carries a guard. FORBIDDEN rules
become entries in `constraints` ('rule_id: prohibition'), NEVER edges or nodes.
(Concurrency) If independent branches share no moving data, add a SPAWN node;
otherwise set spawn_note explaining why the flow is sequential. Never leave the
decision implicit.
(Provenance) Every node lists the rule ids it realizes in traces_to. The TASK
overrides the SKILL: keep conditional guidance conditional.
If ISSUES from the validator are given, fix exactly those — keep everything
else stable (ids included).""";
sem workflow_view.spec = "The frozen RuleSet — the complete, grounded spec.";
sem workflow_view.skill = "The original skill text, for context. The spec is the contract; the text disambiguates.";
sem workflow_view.issues = "Validator issues from the previous round to fix (empty on round one).";
def workflow_view(spec: RuleSet, skill: str, issues: str) -> WorkflowView by wf_llm();

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

def workflow_spine(spec: RuleSet, skill: str, max_rounds: int = 3) -> SpineResult {
    # Bounded model-propose / code-dispose loop. On exhaustion, returns the last
    # view WITH its outstanding issues — an honest failure, never a silent one.
    wf = WorkflowView();
    issues: list = [];
    rounds = 0;
    digest = "";
    while rounds < max_rounds {
        wf = workflow_view(spec, skill, digest);
        issues = validate_spine(spec, wf);
        rounds += 1;
        if not issues { break; }
        digest = "FIX EXACTLY THESE:\n- " + "\n- ".join([str(i) for i in issues]);
    }
    return SpineResult(view=wf, issues=issues, rounds=rounds);
}
