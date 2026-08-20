"""raise2 — the strategy-independent FAITHFULNESS CORE (Layer 0 + Layer 2).

The rearchitected raise separates two concerns the current pipeline conflates:

  AUTHORING     how the IR is produced — pluggable, ALWAYS coherent (one author
                writes every cross-reference, so no seams). direct / agent / staged
                / hand-written are all just strategies.
  VERIFICATION  a FAITHFULNESS invariant every candidate must pass — total over
                ALL rule kinds, and independent of how the IR was authored.

This module is the verification core. It is PURE CODE, no model: a faithfulness
verdict is deterministic and reproducible even though authoring is not. It
computes the two-directional closure between the frozen spec and a parsed IR:

  completeness : every rule has a SHAPE-CORRECT realization  (nothing DROPPED)
  soundness    : every IR element traces to a rule           (nothing ADDED)

The rearchitecture turns on ONE reprioritization: a FAITHFULNESS violation FAILS
the raise (an agent that silently drops/adds an obligation is a compliance failure
wearing a green check), while COHERENCE issues (won't compile, type mismatch,
hollow node) DEGRADE under fix-forward as before. `classify()` encodes that axis.

Why this is stronger than today's G5: G5 audits only MANDATORY STEP/IO and trusts
whatever `traces_to` the model wrote. Here EVERY rule kind has a required shape
(§9 of the authoring guide, made mechanical), and `traces_to` is enforced as a
closure — a node that traces to nothing is an unverifiable (added) behavior, not
a free pass.
"""

import re;
import yaml;
import from src.compiler.mechanical.compiler { _load_ir }
import from src.sigil_agir_yaml { dump_agir }
import from .lift_types { Cohesion, Modality, RuleKind }
import from .spec_loop { Rule, RuleSet }

# ---------------------------------------------------------------------------
# Layer 0 — the required-realization table.
#
# A pure function (kind, modality) -> the shape a faithful IR must realize the
# rule as. This is the authoring guide's §9 ("realizing obligations faithfully")
# lifted out of prose into a decision the closure can check. Frozen WITH the spec:
# once the RuleSet exists, "complete" has a precise meaning for every rule.
# ---------------------------------------------------------------------------

enum RealShape { OPTIONAL, NODE, EMBODIED_WRITE, CONSTRAINT, CODE_GATE, EMBODIED_KNOWLEDGE, LIVE_TOOL }
sem RealShape = "The structural form a faithful IR must realize a rule as.";
sem RealShape.OPTIONAL = "DISCRETIONARY guidance — realizing it is allowed, never required.";
sem RealShape.NODE = "A mandatory step — at least one node must trace to it.";
sem RealShape.EMBODIED_WRITE = "A mandatory deliverable — an ACT that genuinely writes must chain from it.";
sem RealShape.CONSTRAINT = "A prohibition — folded into the doc/body of the slot(s) it governs (a traced node).";
sem RealShape.CODE_GATE = "A human gate — an owner=code route or an ask/confirm tool on the guarded node.";
sem RealShape.EMBODIED_KNOWLEDGE = "Reference material — a knowledge item (or tool) carrying its content verbatim.";
sem RealShape.LIVE_TOOL = "A live-source demand — a tool that consults the source at run time.";

def required_shape(kind: RuleKind, modality: Modality, binds: str = "agent") -> RealShape {
    # DISCRETIONARY is never required (that is what "may / if needed" means).
    # An obligation the skill places on a TOOL, the environment, or the user
    # cannot be demanded of the agent: KNOWLEDGE-kind facts are carried verbatim,
    # everything else non-agent is unrealizable-by-design (optional).
    # FORBIDDEN does NOT override KNOWLEDGE — a descriptive 'never' ("the harness
    # never guesses") is a fact to embody, not a constraint to trace; modal force
    # never outranks what the rule IS.
    # Dispatch on enum NAMES, not enum identity. Under multi-file `jac test` a
    # module can be imported more than once, and `Modality.FORBIDDEN` from one
    # load is not the same object as `Modality.FORBIDDEN` from another: every
    # identity test then misses and a FORBIDDEN CONSTRAINT silently falls
    # through to the NODE default — i.e. a prohibition is demanded as a
    # procedure. Names are stable across loads.
    k = str(getattr(kind, "name", kind));
    m = str(getattr(modality, "name", modality));
    if m == "DISCRETIONARY" { return RealShape.OPTIONAL; }
    b = str(binds or "agent");
    if b not in ["agent", ""] {
        if k == "KNOWLEDGE" { return RealShape.EMBODIED_KNOWLEDGE; }
        return RealShape.OPTIONAL;
    }
    if m == "FORBIDDEN" {
        if k == "KNOWLEDGE" { return RealShape.EMBODIED_KNOWLEDGE; }
        return RealShape.CONSTRAINT;
    }
    if k == "STEP" { return RealShape.NODE; }
    if k == "IO" { return RealShape.EMBODIED_WRITE; }
    if k == "CONSTRAINT" { return RealShape.CONSTRAINT; }
    if k == "HIL" { return RealShape.CODE_GATE; }
    if k == "KNOWLEDGE" { return RealShape.EMBODIED_KNOWLEDGE; }
    if k == "GROUNDING" { return RealShape.LIVE_TOOL; }
    return RealShape.NODE;
}

# ---------------------------------------------------------------------------
# The parsed IR — a fuller reconstruction than the gates' _views_from_ir.
#
# _views_from_ir deliberately parses only what G1/G5 read ("a parse, not a second
# opinion"). The faithfulness closure needs MORE: edges, tool bindings, knowledge
# provenance, carries — everything that decides whether each rule kind is realized.
# Still pure structure, no judgment.
# ---------------------------------------------------------------------------

obj PNode {
    has id: str = "";
    has ntype: str = "";        # upper-cased, dashes normalized to underscores (GEN_RAW, ACT, ...)
    has owner: str = "model";
    has doc: str = "";
    has reads: list[str] = [];
    has writes: list[str] = [];
    has traces_to: list[str] = [];
    has tool: str = "";
    has surface: str = "";
}

obj PTool {
    has name: str = "";
    has body: str = "";
    has command: str = "";
    has surface: str = "";
    has serves: list[str] = [];
    has traces_to: list[str] = [];
}

obj PKnow {
    has key: str = "";
    has content: str = "";
    has traces_to: list[str] = [];
    has resident_on: list[str] = [];
}

obj ParsedIR {
    has nodes: list[PNode] = [];
    has tools: list[PTool] = [];
    has knowledge: list[PKnow] = [];
    has carries: list[str] = [];
    has ok: bool = True;        # False when the text did not parse to an IR at all
}

def _s(v: any) -> str { return str(v) if v is not None else ""; }

def _slist(v: any) -> list[str] {
    if isinstance(v, list) { return [str(x) for x in v]; }
    if v is None { return []; }
    return [str(v)];
}

def _ntype(v: any) -> str {
    return str(v or "").upper().replace("-", "_").strip();
}

# The content sub-fields a knowledge entry may use (guide §8: template / pattern /
# body / value / content). Any one embodies the entry; none = a prose-pointer.
glob _KN_CONTENT_KEYS: list[str] = ["content", "body", "template", "pattern", "value", "text"];

def _kn_content(ent: any) -> str {
    if not isinstance(ent, dict) { return _s(ent); }
    for k in _KN_CONTENT_KEYS {
        v = ent.get(k);
        if v and str(v).strip() { return str(v); }
    }
    return "";
}

def parse_ir(ir_text: str) -> ParsedIR {
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return ParsedIR(ok=False); }
    if not isinstance(ir, dict) or (not ir.get("nodes")) { return ParsedIR(ok=False); }

    nodes: list[PNode] = [];
    for raw in list(ir.get("nodes") or []) {
        if not isinstance(raw, dict) { continue; }
        tn = raw.get("tool");
        if isinstance(tn, list) { tn = tn[0] if tn else ""; }
        nodes.append(PNode(
            id=_s(raw.get("id")), ntype=_ntype(raw.get("type")),
            owner=str(raw.get("owner", "model")).lower(),
            doc=_s(raw.get("doc")), reads=_slist(raw.get("reads")),
            writes=_slist(raw.get("writes")), traces_to=_slist(raw.get("traces_to")),
            tool=_s(tn), surface=_s(raw.get("surface"))
        ));
    }

    tools: list[PTool] = [];
    raw_tools = ir.get("tools") or {};
    if isinstance(raw_tools, dict) {
        for kv in raw_tools.items() {
            td = kv[1] if isinstance(kv[1], dict) else {};
            tools.append(PTool(
                name=_s(kv[0]), body=_s(td.get("body")), command=_s(td.get("command")),
                surface=_s(td.get("surface")), serves=_slist(td.get("serves")),
                traces_to=_slist(td.get("traces_to"))
            ));
        }
    }

    knowledge: list[PKnow] = [];
    raw_kn = ir.get("knowledge") or {};
    if isinstance(raw_kn, dict) {
        for kv2 in raw_kn.items() {
            ent = kv2[1];
            res = _slist(ent.get("resident_on")) if isinstance(ent, dict) else [];
            tr = _slist(ent.get("traces_to")) if isinstance(ent, dict) else [];
            knowledge.append(PKnow(key=_s(kv2[0]), content=_kn_content(ent),
                                   traces_to=tr, resident_on=res));
        }
    }

    carries: list[str] = [];
    wlk: dict = {};
    w0 = ir.get("walker");
    if isinstance(w0, dict) { wlk = w0; }
    cs: dict = {};
    c0 = wlk.get("carries");
    if isinstance(c0, dict) { cs = c0; }
    for ck in cs { carries.append(str(ck)); }

    return ParsedIR(nodes=nodes, tools=tools, knowledge=knowledge, carries=carries, ok=True);
}

# ---------------------------------------------------------------------------
# The proof object + finding type.
#
# The raise's real deliverable is not "a module (trust me)" but a per-rule proof
# of realization you can inspect. A FaithFinding names the rule, the axis it
# violates, and the concrete fix — so a failure routes straight into rule-scoped
# repair, deterministically, with no model call to explain it.
# ---------------------------------------------------------------------------

obj FaithFinding {
    has axis: str = "faithfulness";   # faithfulness | coherence
    has severity: str = "fail";       # fail (faithfulness) | error | warn
    has rule: str = "";
    has shape: str = "";
    has message: str = "";
}

obj FaithReport {
    has ok: bool = False;             # no faithfulness violations (dropped or added)
    # False when the text did not parse to an IR at all. Such a report carries a
    # SINGLE coherence finding, so by raw gap count it scores 1 — better than any
    # genuine repair with real gaps. The repair ladder must never treat "did not
    # parse" as "almost perfect"; see gap_score().
    has parsed: bool = True;
    has rules_total: int = 0;
    has realized: int = 0;
    has dropped: list[FaithFinding] = [];    # completeness violations (rule -> nothing)
    has added: list[FaithFinding] = [];      # soundness violations (element -> no rule)
    has by_shape: dict[str, int] = {};       # realized count per shape (the breakdown)
    # Cognition-preservation notes. Deliberately NOT folded into `ok` or
    # gap_score: shredding an INVOKE_UNIT rule is a real faithfulness problem,
    # but it has never been measured on the raise2 path (enforcement lived only
    # in the staged front-end's spine validator), and landing it as a hard
    # failure would fail compiles that pass today on evidence we do not have.
    # Reported, counted, and one line away from being promoted.
    has cohesion: list[FaithFinding] = [];
    # True when the spec HAD obligations but none survived modality resolution as
    # required. A faithfulness verdict over an empty required set is a vacuous
    # truth, not a proof — see vacuity_finding().
    has vacuous: bool = False;
}

# How far a candidate is from faithful, for ladder COMPARISONS.
#
# An unparseable IR carries ONE coherence finding, so by raw gap count it scores
# 1 — better than any genuine repair with real gaps. That is exactly what sank
# pptx: the authored IR did not parse (scored 1), the repair round produced a
# PARSEABLE IR with 31 real gaps (scored 31), the ladder "kept prior", and the
# unparseable text went to lowering, which found no nodes and reported the whole
# compile as UNFAITHFUL 0/130. A candidate that does not parse must lose to any
# candidate that does.
def gap_score(fr: FaithReport) -> int {
    if not fr.parsed { return 1000000 + fr.rules_total; }
    return len(fr.dropped) + len(fr.added);
}


def classify(axis: str) -> str {
    # The reprioritization: faithfulness fails, coherence degrades.
    return "fail" if axis == "faithfulness" else "warn";
}

def fold_untraced_prohibitions(ir_text: str, spec: RuleSet, drop_ids: list[str]) -> str {
    # The mechanical last rung for a DROPPED rule of CONSTRAINT shape: fold the
    # prohibition's text into the doc of every model-owned working node and add
    # the rule id to its traces_to — exactly the fix the drop message
    # prescribes, applied by code. Over-applying a prohibition is conservative-
    # SAFE: the skill states it, so stamping it onto more slots than strictly
    # necessary can never make the IR unfaithful (this is assemble.jac's v1
    # "FORBIDDEN rides every model Mind node" lowering, applied post-hoc).
    # CONSTRAINT shapes only — auto-attaching a dropped step/knowledge/gate
    # would mean inventing an element, which is unsound. Returns "" when
    # nothing could be folded.
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return ""; }
    if (not isinstance(ir, dict)) or (not ir.get("nodes")) { return ""; }
    by_id: dict = {};
    for r in spec.rules { by_id[r.id] = r; }
    # Partition the slots ONCE. A prohibition rides the model-owned working
    # nodes it governs — but a fully DETERMINISTIC pipeline owns every node as
    # code, and skipping those left the fold with nowhere to write, so it
    # returned "" and the gate stayed permanently unsatisfiable (azure-bgp:
    # 5/6, one CONSTRAINT rule and no model node in the whole IR). CONSTRAINT is
    # realized by any TRACED node — check_completeness reads traces_to and
    # ignores owner — so fall back to the code nodes instead of folding nothing.
    # TERMINAL is never a target either way: an end marker is not a slot a
    # prohibition can govern.
    model_nodes: list = [];
    code_nodes: list = [];
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        ntype = _ntype(nd.get("type"));
        if ntype == "TERMINAL" { continue; }
        owner = str(nd.get("owner", "model")).lower();
        if (owner == "code") or (ntype == "CODE") { code_nodes.append(nd); }
        else { model_nodes.append(nd); }
    }
    targets: list = model_nodes if model_nodes else code_nodes;
    touched = False;
    for rid in drop_ids {
        r = by_id.get(str(rid));
        if not r { continue; }
        text = (str(r.statement).strip() or str(r.quote).strip());
        if not text { continue; }
        for nd in targets {
            doc = str(nd.get("doc") or "");
            nd["doc"] = doc + ("\n" if doc else "") + "PROHIBITION (" + str(rid) + "): " + text;
            tl = _slist(nd.get("traces_to"));
            if str(rid) not in tl { tl.append(str(rid)); }
            nd["traces_to"] = tl;
            touched = True;
        }
    }
    if not touched { return ""; }
    return dump_agir(ir);
}

# ---------------------------------------------------------------------------
# Layer 2 — completeness: every rule has a shape-correct realization.
# ---------------------------------------------------------------------------

def _traced_nodes(pir: ParsedIR, rid: str) -> list[PNode] {
    return [n for n in pir.nodes if rid in n.traces_to];
}

def _tool_for(pir: ParsedIR, n: PNode) -> list[PTool] {
    # mirror the back-end _node_tool join: explicit tool: field, then serves, then
    # a tool named exactly the node id.
    out: list[PTool] = [];
    for t in pir.tools {
        if (n.tool and (t.name == n.tool)) or (n.id in t.serves) or (t.name == n.id) { out.append(t); }
    }
    return out;
}

def _is_embodied_act(pir: ParsedIR, n: PNode) -> bool {
    if n.ntype != "ACT" { return False; }
    for t in _tool_for(pir, n) {
        if t.body.strip() or t.command.strip() { return True; }
    }
    return bool(n.reads);   # ACT with a content read lowers to the _write_artifact fallback
}

def _realizes_write(pir: ParsedIR, rid: str) -> bool {
    # the G3 chain, over ParsedIR: a traced node that is an embodied ACT, or writes
    # a carry an embodied ACT downstream consumes.
    owners = _traced_nodes(pir, rid);
    for n in owners {
        if _is_embodied_act(pir, n) { return True; }
        for w in n.writes {
            for c in pir.nodes {
                if (w in c.reads) and _is_embodied_act(pir, c) { return True; }
            }
        }
    }
    return False;
}

def _realizes_gate(pir: ParsedIR, rid: str) -> bool {
    # an owner=code ROUTE traced to the rule, OR a traced node served by an
    # ask/confirm tool (the HIL gate the mechanical half emits).
    for n in _traced_nodes(pir, rid) {
        if (n.ntype == "ROUTE") and (n.owner == "code") { return True; }
        for t in _tool_for(pir, n) {
            low = t.name.lower();
            if low.startswith("ask_") or low.startswith("confirm") or ("ask_user" in low) { return True; }
        }
    }
    return False;
}

# A pointer body READS something and NAMES a sibling document. Both halves are
# required: the filename can sit in a candidate list rather than inside the
# open() call ("for candidate in ('forms.md', './forms.md'): ... open(candidate)"),
# so matching only `open("x.md")` misses the shape that actually ships.
glob _POINTER_READ: str = r"\b(open|read_text|read_bytes|loadtxt|Path)\s*\(";
glob _POINTER_DOC: str  = r"[\"'][^\"']*\.([mM][dD]|[tT][xX][tT]|[rR][sS][tT]|[aA][dD][oO][cC])[\"']";

def _is_pointer_body(text: str) -> bool {
    # A body that merely OPENS a sibling document is a pointer, not embodiment.
    # The harness deploys the compiled artifact alone, so such a read finds
    # nothing at run time — this is the "instruction to consult a file the
    # harness does not carry" that admission is supposed to reject. Observed
    # live: the SkillsBench pdf skill compiled `faithful` with a tool whose whole
    # body was a search for forms.md, and shipped without the file.
    t = str(text or "");
    if not t.strip() { return False; }
    return bool(re.search(_POINTER_READ, t)) and bool(re.search(_POINTER_DOC, t));
}

def _realizes_knowledge(pir: ParsedIR, rid: str) -> bool {
    for k in pir.knowledge {
        if (rid in k.traces_to) and k.content.strip() { return True; }
    }
    for t in pir.tools {
        if rid not in t.traces_to { continue; }
        body = str(t.body or ""); cmd = str(t.command or "");
        if not (body.strip() or cmd.strip()) { continue; }
        # carrying the content counts; pointing at where the content lives does not
        if _is_pointer_body(body) and (not cmd.strip()) { continue; }
        return True;
    }
    return False;
}

def _realizes_live_tool(pir: ParsedIR, rid: str) -> bool {
    for t in pir.tools {
        if rid in t.traces_to { return True; }
    }
    # a live source is often bound to a SENSE node that traces the rule
    for n in _traced_nodes(pir, rid) {
        if n.ntype == "SENSE" { return True; }
    }
    return False;
}

def _fix_for(shape: RealShape, r: Rule) -> str {
    # the statement (when the extractor filled one) reads better in a directive
    # than a truncated span; the quote stays the anchor either way.
    q = (str(r.statement).strip() or str(r.quote))[:70];
    if shape == RealShape.NODE {
        return "add a node whose traces_to includes '" + r.id + "' realizing: " + q;
    }
    if shape == RealShape.EMBODIED_WRITE {
        return "add an ACT (write-tool or content read) traced to '" + r.id + "' that writes the deliverable: " + q;
    }
    if shape == RealShape.CONSTRAINT {
        return "fold this prohibition into the doc/body of the slot(s) it governs and add '" + r.id
             + "' to their traces_to (an untraced prohibition cannot be verified): " + q;
    }
    if shape == RealShape.CODE_GATE {
        return "add an owner=code ROUTE (or an ask/confirm tool) traced to '" + r.id + "' for the human gate: " + q;
    }
    if shape == RealShape.EMBODIED_KNOWLEDGE {
        return "add a knowledge item (content verbatim) traced to '" + r.id + "', resident on the node(s) that use it: " + q;
    }
    if shape == RealShape.LIVE_TOOL {
        return "add a live-source tool traced to '" + r.id + "' (consult the source at run time, do not paraphrase): " + q;
    }
    return "realize '" + r.id + "': " + q;
}

def check_completeness(spec: RuleSet, pir: ParsedIR) -> list[FaithFinding] {
    out: list[FaithFinding] = [];
    for r in spec.rules {
        shape = required_shape(r.kind, r.modality, r.binds);
        if shape == RealShape.OPTIONAL { continue; }
        realized = False;
        if shape == RealShape.NODE { realized = len(_traced_nodes(pir, r.id)) > 0; }
        elif shape == RealShape.EMBODIED_WRITE { realized = _realizes_write(pir, r.id); }
        elif shape == RealShape.CONSTRAINT { realized = len(_traced_nodes(pir, r.id)) > 0; }
        elif shape == RealShape.CODE_GATE { realized = _realizes_gate(pir, r.id); }
        elif shape == RealShape.EMBODIED_KNOWLEDGE { realized = _realizes_knowledge(pir, r.id); }
        elif shape == RealShape.LIVE_TOOL { realized = _realizes_live_tool(pir, r.id); }
        if not realized {
            out.append(FaithFinding(
                axis="faithfulness", severity="fail", rule=r.id, shape=shape.name,
                message="DROPPED " + r.kind.name + "/" + r.modality.name + " rule '" + r.id
                    + "' — no " + shape.name + " realization. " + _fix_for(shape, r)
            ));
        }
    }
    return out;
}

# ---------------------------------------------------------------------------
# Layer 2 — soundness: every IR element traces to a rule (nothing added), and the
# provenance it names is real. This is the enforced-traces_to closure.
# ---------------------------------------------------------------------------

def check_soundness(spec: RuleSet, pir: ParsedIR) -> list[FaithFinding] {
    out: list[FaithFinding] = [];
    rule_ids: list[str] = [r.id for r in spec.rules];

    for n in pir.nodes {
        if n.ntype == "TERMINAL" { continue; }   # structural exit — serializes the report
        if not n.traces_to {
            out.append(FaithFinding(axis="faithfulness", severity="fail", rule="", shape="",
                message="ADDED behavior: node '" + n.id + "' traces to no rule — every node must"
                    + " realize a spec rule (set traces_to) or be removed. An untraced node cannot"
                    + " be shown faithful."));
            continue;
        }
        for t in n.traces_to {
            if t not in rule_ids {
                out.append(FaithFinding(axis="faithfulness", severity="fail", rule=t, shape="",
                    message="node '" + n.id + "' traces to unknown rule '" + t + "' (dangling provenance)"));
            }
        }
    }
    for tl in pir.tools {
        for t in tl.traces_to {
            if t not in rule_ids {
                out.append(FaithFinding(axis="faithfulness", severity="fail", rule=t, shape="",
                    message="tool '" + tl.name + "' traces to unknown rule '" + t + "'"));
            }
        }
    }
    for k in pir.knowledge {
        for t in k.traces_to {
            if t not in rule_ids {
                out.append(FaithFinding(axis="faithfulness", severity="fail", rule=t, shape="",
                    message="knowledge '" + k.key + "' traces to unknown rule '" + t + "'"));
            }
        }
    }
    return out;
}

# ---------------------------------------------------------------------------
# The closure — the strategy-independent verification core.
# ---------------------------------------------------------------------------

glob _MIND_TYPES: list[str] = ["GEN_RAW", "GEN_ENUM", "GEN_FILL", "GEN_EDIT"];

def check_cohesion(spec: RuleSet, pir: ParsedIR) -> list[FaithFinding] {
    # Cognition preservation (anti-shred). An INVOKE_UNIT rule is an adaptive
    # tool-using activity — "explore ...", "iterate until ..." — and its value is
    # the observe-and-adapt loop. Split across fixed nodes, the loop is gone even
    # though every fragment traces back to the rule and the closure reads it as
    # realized. Ported from workflow.jac's spine validator, which only the staged
    # front-end ever ran, so the default path had no check at all.
    out: list[FaithFinding] = [];
    for r in spec.rules {
        if r.cohesion != Cohesion.INVOKE_UNIT { continue; }
        owners = [n for n in pir.nodes if r.id in n.traces_to];
        if len(owners) > 1 {
            frag = ", ".join([str(n.id) for n in owners]);
            out.append(FaithFinding(axis="coherence", severity="warn", rule=str(r.id),
                shape="INVOKE_UNIT",
                message="INVOKE_UNIT rule '" + str(r.id) + "' shredded across nodes ["
                        + frag + "] — keep it ONE adaptive node with a tool-belt"));
        } elif len(owners) == 1 {
            n3 = owners[0];
            if (str(n3.owner).lower() != "model") or (str(n3.ntype) not in _MIND_TYPES) {
                out.append(FaithFinding(axis="coherence", severity="warn", rule=str(r.id),
                    shape="INVOKE_UNIT",
                    message="INVOKE_UNIT rule '" + str(r.id) + "' lowered to the non-cognitive node '"
                            + str(n3.id) + "' — it needs a model-owned Mind node with an autonomy tool-belt"));
            }
        }
    }
    return out;
}

def faithfulness_report(spec: RuleSet, ir_text: str) -> FaithReport {
    pir = parse_ir(ir_text);
    if not pir.ok {
        # No parseable IR at all is a coherence failure (G4 territory), not a
        # faithfulness verdict — report it honestly rather than as "all dropped".
        fr = FaithReport(ok=False, rules_total=len(spec.rules), parsed=False);
        fr.dropped = [FaithFinding(axis="coherence", severity="error", rule="", shape="",
            message="IR did not parse — cannot verify faithfulness (fix the compile first)")];
        return fr;
    }
    dropped = check_completeness(spec, pir);
    added = check_soundness(spec, pir);

    required = [r for r in spec.rules if required_shape(r.kind, r.modality, r.binds) != RealShape.OPTIONAL];
    by_shape: dict[str, int] = {};
    dropped_ids: list[str] = [d.rule for d in dropped];
    realized = 0;
    for r in required {
        sh = required_shape(r.kind, r.modality, r.binds).name;
        if r.id not in dropped_ids {
            realized += 1;
            by_shape[sh] = int(by_shape.get(sh, 0)) + 1;
        }
    }
    return FaithReport(
        ok=(not dropped) and (not added),
        rules_total=len(required), realized=realized,
        dropped=dropped, added=added, by_shape=by_shape,
        cohesion=check_cohesion(spec, pir),
        # A spec that arrived with obligations and leaves with nothing required
        # cannot be violated, so `ok` says FAITHFUL about an agent the compiler
        # guaranteed nothing about.
        vacuous=(bool(spec.rules) and (not required))
    );
}

def vacuity_finding() -> FaithFinding {
    return FaithFinding(axis="coherence", severity="warn", rule="", shape="",
        message="every obligation resolved to optional — the faithfulness verdict is vacuous:"
              + " nothing is required of the agent, so nothing can be violated."
              + " Re-run with --clarify to state which of these are a Do.");
}

def proof_lines(fr: FaithReport) -> list[str] {
    # The inspectable proof: what was realized, at what shape, and what is missing.
    lines: list[str] = [];
    verdict = "FAITHFUL" if fr.ok else "UNFAITHFUL";
    lines.append("faithfulness: " + verdict + "  (" + str(fr.realized) + "/" + str(fr.rules_total)
                 + " required rules realized)");
    if fr.by_shape {
        parts: list[str] = [];
        for kv in fr.by_shape.items() { parts.append(str(kv[1]) + "×" + str(kv[0])); }
        lines.append("  by shape: " + ", ".join(parts));
    }
    for d in fr.dropped { lines.append("  ✗ DROP " + d.message); }
    for a in fr.added { lines.append("  ✗ ADD  " + a.message); }
    # Warn-level, so it rides the proof without changing the verdict above it.
    for c in fr.cohesion { lines.append("  ! SHRED " + c.message); }
    if fr.vacuous {
        lines.append("  ! VACUOUS " + vacuity_finding().message);
    }
    return lines;
}
