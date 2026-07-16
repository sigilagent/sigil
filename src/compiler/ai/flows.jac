"""AI compiler — Stage 3: the four annotator flows (the SPAWN fan-out).

Each flow reads the frozen Spec + the spine and emits ONE view of the AG-IR:

- IOFlow        -> IOView        the dataflow view (carries + artifact boundary)
- ContextFlow   -> ContextView   knowledge residency (per-node scoping)
- KnowledgeFlow -> KnowledgeView the snippet sort (tools w/ verbatim bodies vs knowledge)
- HILFlow       -> HILView       human-in-the-loop gates

They are read-shared / write-isolated (each writes only its own view), so they
fan out concurrently via Jac's flow/wait — the same mechanism the compiler's
SPAWN lowering emits. LLM calls are I/O-bound: four flows finish in ~1x
wall-clock. `parallel=False` runs them sequentially (tests script a MockLLM
whose outputs pop in call order, so tests need a deterministic order).
"""

import from jaclang.byllm.lib { Model }
import from .lift_types { RuleSet }
import from .ir_views {
    WorkflowView, IOView, ContextView, KnowledgeView, HILView, ViewBundle
}

glob flows_llm: any = Model(model_name="gpt-4o-mini");
glob _FLOWS_PINNED: bool = False;

def pin_flows_llm(m: any) -> None {
    global flows_llm, _FLOWS_PINNED;
    flows_llm = m;
    _FLOWS_PINNED = True;
}

# ---------------------------------------------------------------------------
# the shared context digest (folded into one string arg — slots stay <=3 args)
# ---------------------------------------------------------------------------

def spine_digest(wf: WorkflowView, skill: str) -> str {
    lines: list = ["SPINE NODES:"];
    for n in wf.nodes {
        rd = ",".join(n.reads);
        wr = ",".join(n.writes);
        lines.append("- " + n.id + " [" + n.ntype.name + "/" + n.owner.name + "] reads(" + rd + ") writes(" + wr + ") :: " + n.doc);
    }
    lines.append("SPINE EDGES:");
    for e in wf.edges {
        g = (" if " + e.guard) if e.guard else "";
        lines.append("- " + e.src + " -> " + e.dst + g);
    }
    lines.append("SKILL TEXT:");
    lines.append(skill);
    return "\n".join(lines);
}

# ---------------------------------------------------------------------------
# the four slots
# ---------------------------------------------------------------------------

sem io_view = """The dataflow pass. For every datum in the workflow ask: does it
sit still or travel? MOVING data (produced at one node, consumed downstream)
becomes a Carry with its produced_by node; static reference material is NOT a
carry (it belongs to knowledge). Always include the 'task' carry (role=input).
Every node's writes must appear as a carry; every non-knowledge read must be a
carry someone produces. The artifact boundary is the USER-INTERACTION line, not
the filesystem: note in artifact_note which ACT delivers the artifact the user
receives and which of its parameters are task-variant.""";
sem io_view.spec = "The frozen RuleSet.";
sem io_view.ctx = "The spine digest (nodes with reads/writes, edges) plus the skill text.";
def io_view(spec: RuleSet, ctx: str) -> IOView by flows_llm();

sem context_view = """The context-flow scoping pass. For each knowledge key the
skill supplies (patterns, templates, rule tables, reference text), decide which
spine nodes need it: a node gets EXACTLY the knowledge it uses — over-injection
is a token-cost bomb, under-injection drops guidance to prose-only. Emit one
Residency entry per knowledge key, naming the node ids it is resident on. Use
the knowledge key names implied by the spec's KNOWLEDGE rules.""";
sem context_view.spec = "The frozen RuleSet.";
sem context_view.ctx = "The spine digest plus the skill text.";
def context_view(spec: RuleSet, ctx: str) -> ContextView by flows_llm();

sem knowledge_view = """The snippet sort (the Owner test on every code snippet /
reference block in the skill). A snippet whose operation is a FUNCTION OF ITS
INPUTS (only args vary) becomes a TOOL: fixed sig, its implementation VERBATIM
in body (or the exact command line in command), serves = the node ids it fires
for. A snippet that merely GROUNDS AN OPEN-ENDED JUDGMENT stays a KnowledgeItem
whose content is VERBATIM from the skill. EMBODY, DON'T POINT: never emit a
'see X.md' / library-name / summary in place of the actual content — an entry
with neither body nor command nor content is a prose-pointer and will be
rejected. A demand to consult a LIVE source stays a live tool (name it after
the fetch, leave body empty, note the URL in the skill knowledge).""";
sem knowledge_view.spec = "The frozen RuleSet.";
sem knowledge_view.ctx = "The spine digest plus the skill text (the snippets live here — copy them verbatim).";
def knowledge_view(spec: RuleSet, ctx: str) -> KnowledgeView by flows_llm();

sem hil_view = """The human-in-the-loop pass. Find every point where the skill
demands a human decision before proceeding: confirmations ('ask before
overwriting'), approvals ('get sign-off'), inputs ('ask the user for X'). Emit
one HILPoint per gate, bound to the spine node it guards, with the prompt
VERBATIM where the skill provides wording. Return an empty list when the skill
demands none — never invent gates.""";
sem hil_view.spec = "The frozen RuleSet.";
sem hil_view.ctx = "The spine digest plus the skill text.";
def hil_view(spec: RuleSet, ctx: str) -> HILView by flows_llm();

# ---------------------------------------------------------------------------
# the fan-out
# ---------------------------------------------------------------------------

def gather_views(spec: RuleSet, ctx: str, parallel: bool = True) -> ViewBundle {
    if parallel {
        # read-shared, write-isolated: each flow writes only its own view, so
        # they run concurrently (flow launches on the pool, wait joins).
        f_io = flow io_view(spec, ctx);
        f_cx = flow context_view(spec, ctx);
        f_kn = flow knowledge_view(spec, ctx);
        f_hl = flow hil_view(spec, ctx);
        # `wait` futures are Unknown to the checker — cast back to the view types
        return ViewBundle(
            io=(wait f_io) as IOView, ctxv=(wait f_cx) as ContextView,
            kn=(wait f_kn) as KnowledgeView, hil=(wait f_hl) as HILView
        );
    }
    # deterministic call order for scripted (MockLLM) runs
    return ViewBundle(
        io=io_view(spec, ctx), ctxv=context_view(spec, ctx),
        kn=knowledge_view(spec, ctx), hil=hil_view(spec, ctx)
    );
}
