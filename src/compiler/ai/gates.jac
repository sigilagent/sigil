"""AI compiler — the gate battery. This module seeds it with G4, the compile
oracle: round-trip a candidate AG-IR through the MECHANICAL half
(transpile_ir) and the jac type-checker. This is the property a manual lift
never has — a deterministic ground truth on every iteration. Later gates
(standalone / C1 / determinization / STRUCT-COV / grounding) land beside it.

Every verdict is typed and must be ROUTED by the caller — an unrouted failure
is a silent success (pipeline B.9.1).
"""

import ast;
import os;
import re;
import shutil;
import subprocess;
import tempfile;
import textwrap;
import traceback;
import yaml;
# absolute import (main.jac style): a parent-relative `..mechanical` breaks under
# `jac test`, which roots the package at the module's own directory.
import from src.compiler.mechanical.compiler { transpile_ir, _load_ir }
import from src.compiler.mechanical.envbind { extract_manifest, probe_manifest }
import from src.compiler.mechanical.concurrency { extract_concurrency }
import from .lift_types { CompileVerdict, Modality, RuleKind }
import from .spec_loop { RuleSet }
import from .ir_views { NodeType, Owner, StructCov }
import from .workflow { AgirNode, WorkflowView }
import from .flows { ViewBundle }

def _jac_bin() -> str {
    env = os.environ.get("SIGIL_JAC", "");
    if env and os.path.isfile(env) { return env; }
    w = shutil.which("jac");
    if w { return str(w); }
    home = os.path.expanduser("~/.local/bin/jac");
    if os.path.isfile(home) { return home; }
    return "jac";
}

# ---------------------------------------------------------------------------
# G1 — the standalone gate (delete-SKILL.md), mechanical
# ---------------------------------------------------------------------------

glob _POINTER_SMELLS: list = ["see ", "refer to ", "as described in ", "per the skill"];

def gate_standalone(vb: ViewBundle) -> list[str] {
    # Delete SKILL.md: could the IR still lower to a working agent? Every tool
    # must be EMBODIED (verbatim body or exact command); every knowledge item
    # must carry its content, not a pointer to where the content lives.
    issues: list = [];
    for td in vb.kn.tools {
        if (not td.body.strip()) and (not td.command.strip()) {
            issues.append("G1: tool '" + td.name + "' is a prose-pointer (no body, no command) — embody it");
        }
    }
    for ki in vb.kn.knowledge {
        c = ki.content.strip();
        if not c {
            issues.append("G1: knowledge '" + ki.key + "' has no content — embody it");
            continue;
        }
        low = c.casefold();
        if len(c) < 80 {
            for sm in _POINTER_SMELLS {
                if low.startswith(str(sm)) {
                    issues.append("G1: knowledge '" + ki.key + "' looks like a pointer ('" + c[:40] + "...') — embody the referenced content verbatim");
                    break;
                }
            }
        }
    }
    return issues;
}

# ---------------------------------------------------------------------------
# G3-hard — the artifact boundary (A.6 as a HARD gate)
# ---------------------------------------------------------------------------

def _is_embodied_act(n: AgirNode, vb: ViewBundle) -> bool {
    # an ACT that will actually WRITE at runtime: a bound tool with body/command,
    # or the mechanical _write_artifact fallback (ACT + str content read).
    if n.ntype != NodeType.ACT { return False; }
    for td in vb.kn.tools {
        if (n.id in td.serves) and (td.body.strip() or td.command.strip()) { return True; }
    }
    if n.reads { return True; }   # ACT with a content read lowers to _write_artifact
    return False;
}

def gate_artifact_boundary(spec: RuleSet, wf: WorkflowView, vb: ViewBundle) -> list[str] {
    # The sweep's systemic finding: process-skill deliverables die in carries —
    # authored, never written. Enforce A.6 mechanically: every MANDATORY IO rule
    # must chain (rule -> traced node, or 1 hop through its written carries) to
    # an ACT that genuinely writes. A deliverable with no embodied write is a
    # dropped artifact, however good the content in the carry looks.
    issues: list = [];
    consumers: dict[str, list[AgirNode]] = {};
    for n in wf.nodes {
        for rd in n.reads {
            cur: list[AgirNode] = list(consumers.get(rd, []));
            cur.append(n);
            consumers[rd] = cur;
        }
    }
    for r in spec.rules {
        if (r.kind != RuleKind.IO) or (r.modality != Modality.MANDATORY) { continue; }
        owners = [n for n in wf.nodes if r.id in n.traces_to];
        satisfied = False;
        for n in owners {
            if _is_embodied_act(n, vb) { satisfied = True; break; }
            for w in n.writes {
                for c in consumers.get(w, []) {
                    if _is_embodied_act(c, vb) { satisfied = True; break; }
                }
                if satisfied { break; }
            }
            if satisfied { break; }
        }
        if not satisfied {
            hint = (" (nodes: " + ", ".join([n.id for n in owners]) + ")") if owners else " (no node realizes it)";
            issues.append("G3: IO mandate '" + r.id + "' has no embodied artifact write" + hint
                          + " — add an ACT node served by a write-tool (body/command) or reading the content carry");
        }
    }
    return issues;
}

# ---------------------------------------------------------------------------
# G5 — STRUCT-COV / no-monolith, static on the COMPILED module
# ---------------------------------------------------------------------------

# The markers the mechanical half emits when a code-owned node had nothing to
# lower — no tool bound, no inline body. The ability is still generated (it has
# to be, the walker must traverse it), so its NAME appears in the module either
# way; only the marker distinguishes a real gate from a pass-through.
glob HOLLOW_MARKERS: list[str] = ["# CODE ", "# SENSE ", "# ACT "];

"""Did this node lower to a marker comment instead of to work?

`can n_compile_checkpoint … { _progress(…); # CODE compile_checkpoint; visit …; }`
is a station the walker visits and which does nothing. Scoring that `gated`
("guaranteed by construction") is strictly worse than scoring it `missing`: a
missing rule is reported, a hollow one is reported as the strongest realization
there is. Checking `("can n_" + nid) in module_src` cannot tell them apart."""
def _lowered_hollow(node_id: str, module_src: str) -> bool {
    for m in HOLLOW_MARKERS {
        if (m + node_id) in module_src { return True; }
    }
    return False;
}

def gate_struct_cov(spec: RuleSet, wf: WorkflowView, module_src: str) -> StructCov {
    # For each MANDATORY STEP/IO rule: how does the compiled agent realize it?
    #   gated      owner=code ability  -> guaranteed by construction
    #   slotted    dedicated model slot -> observable, model executes it
    #   monolithic folded into another slot -> model-dependent (prose-grade risk)
    #   missing    no realization at all -> a structural gap
    # monolithic/missing are ISSUES naming exactly which node to strengthen.
    sc = StructCov();
    node_by_rule: dict[str, list[AgirNode]] = {};
    for n in wf.nodes {
        for t in n.traces_to {
            cur: list[AgirNode] = list(node_by_rule.get(t, []));
            cur.append(n);
            node_by_rule[t] = cur;
        }
    }
    for r in spec.rules {
        if r.modality != Modality.MANDATORY { continue; }
        if (r.kind != RuleKind.STEP) and (r.kind != RuleKind.IO) { continue; }
        owners: list[AgirNode] = list(node_by_rule.get(r.id, []));
        if not owners {
            sc.missing.append(r.id);
            sc.issues.append("G5: MANDATORY rule '" + r.id + "' has NO realization in the graph");
            continue;
        }
        best = "";
        hollow_on: list[str] = [];
        for n2 in owners {
            nid = re.sub(r"[^0-9a-zA-Z_]", "_", str(n2.id));
            has_ability = ("can n_" + nid) in module_src;
            if not has_ability { continue; }
            if n2.owner == Owner.CODE {
                # owner=CODE only earns `gated` if the node actually lowered to
                # work. A marker-comment body is a gate in name only.
                if _lowered_hollow(str(n2.id), module_src) {
                    hollow_on.append(str(n2.id));
                    continue;
                }
                best = "gated";
                break;
            }
            if (("def " + nid + "(") in module_src) or (("def gen_" + nid + "(") in module_src) {
                if best != "gated" { best = "slotted"; }
            } elif not best { best = "monolithic"; }
        }
        if best == "gated" { sc.gated.append(r.id); }
        elif best == "slotted" { sc.slotted.append(r.id); }
        elif best == "monolithic" {
            sc.monolithic.append(r.id);
            sc.issues.append("G5: rule '" + r.id + "' realized MONOLITHICALLY (node '" + owners[0].id + "' has no dedicated slot) — split it or add a code gate");
        } elif hollow_on {
            sc.missing.append(r.id);
            sc.issues.append("G5: rule '" + r.id + "' realized HOLLOW — code node(s) [" + ", ".join(hollow_on)
                + "] lowered to a marker comment, so the station is visited but does nothing."
                + " Bind a tool (body or command) to it, or re-own the rule to MODEL.");
        } else {
            sc.missing.append(r.id);
            sc.issues.append("G5: rule '" + r.id + "' traced to node(s) that never lowered to an ability — structural gap");
        }
    }
    return sc;
}

# ---------------------------------------------------------------------------
# G6-HIL — human-feedback gates are owner=code (slotted != gated)
# ---------------------------------------------------------------------------

def gate_hil_gates(wf: WorkflowView, vb: ViewBundle) -> list[str] {
    # The superpowers HIL session's sharpest finding: a model-owned approval
    # route read the human's explicit "NOT approved" and proceeded as approved.
    # A route that consumes human feedback is a MANDATE-CLASS gate: owner=code,
    # explicit guards on every branch — no model judgment between the human's
    # words and the control flow.
    issues: list = [];
    gated_nodes = [hp.node for hp in vb.hil.points];
    hil_carries: list = [];
    for n in wf.nodes {
        if n.id in gated_nodes {
            for w in n.writes { if w not in hil_carries { hil_carries.append(w); } }
        }
    }
    for n in wf.nodes {
        if n.ntype != NodeType.ROUTE { continue; }
        feeds = [rd for rd in n.reads if rd in hil_carries];
        if not feeds { continue; }
        if n.owner != Owner.CODE {
            issues.append("G6: route '" + n.id + "' consumes human feedback ('" + ", ".join(feeds)
                          + "') but is model-owned — make it owner=code with explicit guards (e.g. contains 'approved')");
        }
    }
    return issues;
}

# ---------------------------------------------------------------------------
# G7-ENV — environment binding (SkillRT AOT pass 2, install-time probe)
# ---------------------------------------------------------------------------

def gate_env_binding(ir_text: str) -> list[str] {
    # A tool body's import or command that cannot resolve in THIS runtime is a
    # compile-time fact, not a runtime surprise: unprobed, it becomes a
    # ModuleNotFoundError that takes the walker down AFTER tokens are spent
    # (caught live: slack-gif-creator's unshipped `core/` — the OSP zero was a
    # crash, not a capability gap). Bind it at install time or ship it.
    issues: list = [];
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return []; }
    pr = probe_manifest(extract_manifest(ir));
    for m in list(pr["missing_py"]) {
        issues.append("G7: tool(s) [" + ", ".join([str(t) for t in list(m[2])]) + "] import '" + str(m[0])
            + "' — not importable in this runtime. Bind it (pip install " + str(m[1])
            + ") or ship the module with the agent bundle.");
    }
    for b in list(pr["missing_bin"]) {
        issues.append("G7: tool(s) [" + ", ".join([str(t) for t in list(b[1])]) + "] shell out to '" + str(b[0])
            + "' — not on PATH. Install it or embody a python fallback.");
    }
    return issues;
}

# ---------------------------------------------------------------------------
# G8-PAR — concurrency extraction (SkillRT AOT pass 3, mechanical on the
# typed dataflow). False parallelism is a hard issue; missed parallelism is
# an opportunity the caller records (advisory — never blocks a compile).
# ---------------------------------------------------------------------------

def gate_concurrency(ir_text: str) -> dict {
    try {
        ir = _load_ir(ir_text);
        return extract_concurrency(ir);
    } except Exception {
        return {"stages": [], "opportunities": [], "issues": [], "dlp": []};
    }
}

# ---------------------------------------------------------------------------
# G9-TY — typed-dataflow unification (mechanical on the FINAL IR).
#
# The carry table declares one type per lane; the producing slot's return
# schema and every consuming tool's contract both derive from it. Nothing
# audited that triangle: a fresh compile shipped a model slot returning `str`
# into a tool body demanding `list` — green through every gate, TypeError at
# runtime. Worse, an untyped carry lowers the walker field to `any`, so the
# G4 jac-check is structurally BLIND to the mismatch. The demand a tool body
# states is ground truth (its code is frozen); the carry type must match it.
#
# Evidence read per tool param, mirroring the _bind_args join (name first,
# then positional over the node's reads):
#   - a param annotation            def f(headers: list) / (rows: list[str])
#   - a guard-clause isinstance     if not isinstance(x, list): raise ...
#   - an assert isinstance          assert isinstance(x, dict)
# refined to list[T] when the same guard runs all(isinstance(h, T) for h in x).
#
# autofix_carry_types applies the unification MECHANICALLY (no model): adopt
# the consumer's demand into walker.carries.<c>.type and let the caller
# re-gate through G4 — the oracle stays the authority on the patched IR.
# ---------------------------------------------------------------------------

glob _TY_SCALARS: list = ["str", "int", "float", "bool"];

def _ty_base(t: any) -> str {
    # IR type string -> comparable base kind ("" when unknown/custom).
    s = str(t or "").strip().rstrip("?").strip();
    if not s { return ""; }
    s = s.split("|")[0].strip();
    if s.startswith("enum{") { return "str"; }
    b = s.split("[")[0].strip();
    if b == "path" { return "str"; }
    if b in _TY_SCALARS { return b; }
    if b in ["list", "dict", "any"] { return b; }
    return "";   # custom obj/enum types: out of scope, never flagged
}

def _ty_class(t: any) -> str {
    b = _ty_base(t);
    if b in _TY_SCALARS { return "scalar"; }
    if b in ["list", "dict"] { return b; }
    return "";
}

def _ann_type(ann: any) -> str {
    # ast annotation / type expression -> IR type string ("" when unmappable).
    if isinstance(ann, ast.Name) {
        nm = str(ann.id);
        if nm in ["str", "int", "float", "bool", "list", "dict"] { return nm; }
        return "";
    }
    if isinstance(ann, ast.Subscript) and isinstance(ann.value, ast.Name) {
        base = str(ann.value.id).lower();
        if base == "list" {
            sl = ann.slice;
            if isinstance(sl, ast.Name) and (str(sl.id) in ["str", "int"]) {
                return "list[" + str(sl.id) + "]";
            }
            return "list";
        }
        if base == "dict" { return "dict"; }
    }
    return "";
}

def _g9_refine_list(guard_test: any, param: str) -> str {
    # `all(isinstance(h, T) for h in <param>)` anywhere in the guard test
    # refines a bare `list` demand to list[T].
    for nd in ast.walk(guard_test) {
        if not (isinstance(nd, ast.Call) and isinstance(nd.func, ast.Name) and (str(nd.func.id) == "all")) { continue; }
        if not nd.args { continue; }
        gen = nd.args[0];
        if not isinstance(gen, ast.GeneratorExp) { continue; }
        elt = gen.elt;
        iters_param = False;
        for comp in gen.generators {
            if isinstance(comp.iter, ast.Name) and (str(comp.iter.id) == param) { iters_param = True; }
        }
        if not iters_param { continue; }
        if isinstance(elt, ast.Call) and isinstance(elt.func, ast.Name) and (str(elt.func.id) == "isinstance") and (len(elt.args) == 2) {
            it = _ann_type(elt.args[1]);
            if it in ["str", "int"] { return "list[" + it + "]"; }
        }
    }
    return "list";
}

def _g9_guard_demands(fn: any) -> list {
    # [[param, type], ...] from guard clauses that RAISE (or assert) on an
    # isinstance failure — the only isinstance shape that is a demand rather
    # than a coercion branch (`if isinstance(x, str): x = json.loads(x)`
    # ACCEPTS str and must not be read as demanding it).
    out: list = [];
    for st in ast.walk(fn) {
        guard_test: any = None;
        if isinstance(st, ast.If) {
            raises = [b for b in st.body if isinstance(b, ast.Raise)];
            if raises { guard_test = st.test; }
        } elif isinstance(st, ast.Assert) {
            guard_test = st.test;
        }
        if guard_test is None { continue; }
        for nd in ast.walk(guard_test) {
            neg = isinstance(nd, ast.UnaryOp) and isinstance(nd.op, ast.Not);
            call: any = getattr(nd, "operand") if neg else nd;
            # in an if-raise the demand is the NEGATED isinstance; in an
            # assert it is the bare one.
            if neg == isinstance(st, ast.Assert) { continue; }
            if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and (str(call.func.id) == "isinstance") and (len(call.args) == 2)) { continue; }
            if not isinstance(call.args[0], ast.Name) { continue; }
            pname = str(call.args[0].id);
            t = _ann_type(call.args[1]);
            if not t { continue; }
            if t == "list" { t = _g9_refine_list(guard_test, pname); }
            out.append([pname, t]);
        }
    }
    return out;
}

def _g9_tool_params(td: any) -> list {
    # The tool's entry-function params as [[name, demanded_type], ...] —
    # annotation first, guard/assert demand as fallback. "" when untyped.
    body = td.get("body") if isinstance(td, dict) else None;
    if not body { return []; }
    tree: any = None;
    try { tree = ast.parse(textwrap.dedent(str(body))); } except Exception { return []; }
    for st in tree.body {
        if not (isinstance(st, ast.FunctionDef) or isinstance(st, ast.AsyncFunctionDef)) { continue; }
        demands: dict = {};
        for d in _g9_guard_demands(st) {
            if str(d[0]) not in demands { demands[str(d[0])] = str(d[1]); }
        }
        out: list = [];
        for a in st.args.args {
            t = _ann_type(a.annotation) if (a.annotation is not None) else "";
            if not t { t = str(demands.get(str(a.arg), "")); }
            out.append([str(a.arg), t]);
        }
        return out;
    }
    return [];
}

def _g9_tool_for(ir: any, nd: any) -> list {
    # [tool_name, tool_def] bound to this node (serves / explicit / 1:1 name),
    # mirroring the mechanical half's _node_tool join; [] when none.
    tools = ir.get("tools");
    if not isinstance(tools, dict) { return []; }
    nid = nd.get("id");
    tn = nd.get("tool");
    if isinstance(tn, list) { tn = tn[0] if tn else None; }
    if isinstance(tn, str) and (tn in tools) { return [str(tn), tools[tn]]; }
    for k in tools {
        t = tools[k];
        if isinstance(t, dict) and (nid in list(t.get("serves") or [])) { return [str(k), t]; }
    }
    if nid in tools { return [str(nid), tools[nid]]; }
    return [];
}

def _g9_evidence(ir: any) -> list {
    # [carries, producers, demands] where demands: carry -> [[tool, param, type], ...]
    wlk = ir.get("walker") if isinstance(ir.get("walker"), dict) else {};
    carries = wlk.get("carries") if isinstance(wlk.get("carries"), dict) else {};
    producers: dict = {};
    demands: dict = {};
    for nd in list(ir.get("nodes") or []) {
        if not isinstance(nd, dict) { continue; }
        for w in list(nd.get("writes") or []) {
            cur: list = list(producers.get(str(w), []));
            cur.append(nd);
            producers[str(w)] = cur;
        }
        if str(nd.get("owner", "")) != "code" { continue; }
        bound = _g9_tool_for(ir, nd);
        if not bound { continue; }
        params = _g9_tool_params(bound[1]);
        # positional fallback mirrors _bind_args: the index runs over ALL of
        # the node's reads (not just carry lanes), advancing once per param.
        rl = list(nd.get("reads") or []);
        i = 0;
        for p in params {
            pname = str(p[0]);
            ptype = str(p[1]);
            carry = "";
            if pname in carries { carry = pname; }
            elif (i < len(rl)) and (str(rl[i]) in carries) { carry = str(rl[i]); }
            i += 1;
            if (not carry) or (not ptype) { continue; }
            cur2: list = list(demands.get(carry, []));
            cur2.append([str(bound[0]), pname, ptype]);
            demands[carry] = cur2;
        }
    }
    return [carries, producers, demands];
}

def _g9_is_model(nd: any) -> bool {
    return isinstance(nd, dict) and (str(nd.get("owner", "")) == "model");
}

def gate_type_unification(ir_text: str) -> list[str] {
    issues: list = [];
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return []; }
    ev = _g9_evidence(ir);
    carries: dict = ev[0] if isinstance(ev[0], dict) else {};
    producers: dict = ev[1] if isinstance(ev[1], dict) else {};
    demands: dict = ev[2] if isinstance(ev[2], dict) else {};

    for cname in carries {
        c = carries[cname];
        if not isinstance(c, dict) { continue; }
        declared = str(c.get("type") or "");
        dcls = _ty_class(declared);
        dm: list = list(demands.get(str(cname), []));
        prods: list = list(producers.get(str(cname), []));
        model_prod = [p for p in prods if _g9_is_model(p)];

        # demands must agree among themselves before they can bind the carry
        classes: list = [];
        for d in dm {
            cl = _ty_class(d[2]);
            if cl and (cl not in classes) { classes.append(cl); }
        }
        if len(classes) > 1 {
            spans = "; ".join(["tool '" + str(d[0]) + "' param '" + str(d[1]) + "' wants '" + str(d[2]) + "'" for d in dm]);
            issues.append("G9: carry '" + str(cname) + "' has CONFLICTING consumer contracts (" + spans
                + ") — the tools themselves disagree; align the tool bodies before typing the carry");
            continue;
        }
        if dm and classes {
            want = str(dm[0][2]);
            for d in dm {   # prefer the most refined spelling (list[str] over list)
                if len(str(d[2])) > len(want) { want = str(d[2]); }
            }
            if dcls and (dcls != classes[0]) {
                issues.append("G9: carry '" + str(cname) + "' is declared '" + declared + "' but tool '"
                    + str(dm[0][0]) + "' requires '" + want + "' for param '" + str(dm[0][1])
                    + "' — the walker crashes at this boundary at runtime. Set walker.carries."
                    + str(cname) + ".type: " + want + " (autofix adopts the consumer's type; the producing"
                    + " slot's return schema then enforces the shape at generation)");
            } elif (not declared.strip()) or (_ty_base(declared) == "any") {
                issues.append("G9: carry '" + str(cname) + "' is untyped ('" + (declared if declared else "missing")
                    + "') but tool '" + str(dm[0][0]) + "' requires '" + want
                    + "' — untyped lowers the walker field to `any`, so jac check cannot see the mismatch."
                    + " Set walker.carries." + str(cname) + ".type: " + want);
            }
        } elif model_prod and ((not declared.strip()) or (_ty_base(declared) == "any")) {
            # a model-written carry consumed by embodied code with NO stated
            # demand: the slot's return schema has nothing to derive from.
            code_readers: list = [];
            for nd2 in list(ir.get("nodes") or []) {
                if not isinstance(nd2, dict) { continue; }
                if str(cname) not in list(nd2.get("reads") or []) { continue; }
                if (str(nd2.get("owner", "")) == "code") and _g9_tool_for(ir, nd2) { code_readers.append(str(nd2.get("id"))); }
            }
            if code_readers {
                issues.append("G9: carry '" + str(cname) + "' crosses model->code untyped — slot '"
                    + str(model_prod[0].get("id")) + "' returns whatever shape the model chose and code node(s) ["
                    + ", ".join(code_readers) + "] consume it blind. Declare walker.carries." + str(cname) + ".type");
            }
        }
    }

    # -- IO provenance: an embodied ACT's reads must be produced, not seeded --
    # (caught live: a relearned agent ran green to TERMINAL while writing its
    # input file from a carry nothing produced — the carry held its task-string
    # seed, so the "artifact" was the task echoed into the input path.)
    for nd3 in list(ir.get("nodes") or []) {
        if not isinstance(nd3, dict) { continue; }
        if str(nd3.get("type", "")) != "ACT" { continue; }
        embodied = False;
        b3 = _g9_tool_for(ir, nd3);
        if b3 and isinstance(b3[1], dict) and (str(b3[1].get("body") or "").strip() or str(b3[1].get("command") or "").strip()) { embodied = True; }
        if (not embodied) and list(nd3.get("reads") or []) { embodied = True; }   # _write_artifact fallback
        if not embodied { continue; }
        for rd3 in list(nd3.get("reads") or []) {
            rc = str(rd3);
            if (rc not in carries) or (rc == "task") { continue; }
            cdef = carries[rc] if isinstance(carries[rc], dict) else {};
            if str(cdef.get("role", "")) == "input" { continue; }
            if not list(producers.get(rc, [])) {
                issues.append("G9: ACT '" + str(nd3.get("id")) + "' writes its artifact from carry '" + rc
                    + "' which NO node produces — at runtime the carry holds its seed/default, so the"
                    + " deliverable is disconnected from the pipeline. Wire a producer or mark the carry role: input");
            }
        }
    }
    return issues;
}

def autofix_carry_types(ir_text: str) -> dict {
    # The mechanical half of G9: adopt an agreeing consumer demand into
    # walker.carries.<c>.type. Pure code, no model. Returns the (possibly
    # unchanged) IR text + human-readable fix notes; the CALLER re-gates
    # through G4 — a patch the oracle rejects is never adopted silently.
    fixes: list = [];
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return {"ir_text": ir_text, "fixes": []}; }
    ev = _g9_evidence(ir);
    carries: dict = ev[0] if isinstance(ev[0], dict) else {};
    demands: dict = ev[2] if isinstance(ev[2], dict) else {};
    for cname in carries {
        c = carries[cname];
        if not isinstance(c, dict) { continue; }
        dm: list = list(demands.get(str(cname), []));
        if not dm { continue; }
        classes: list = [];
        for d in dm {
            cl = _ty_class(d[2]);
            if cl and (cl not in classes) { classes.append(cl); }
        }
        if len(classes) != 1 { continue; }   # disagreeing tools: not fixable mechanically
        want = str(dm[0][2]);
        for d in dm {
            if len(str(d[2])) > len(want) { want = str(d[2]); }
        }
        declared = str(c.get("type") or "");
        dcls = _ty_class(declared);
        if dcls == classes[0] { continue; }              # same class: keep the author's spelling
        if declared.strip() and (_ty_base(declared) == "") { continue; }   # custom obj/enum: never overwrite
        c["type"] = want;
        fixes.append("carry '" + str(cname) + "': type '" + (declared if declared else "missing")
            + "' -> '" + want + "' (required by tool '" + str(dm[0][0]) + "' param '" + str(dm[0][1]) + "')");
    }
    if not fixes { return {"ir_text": ir_text, "fixes": []}; }
    fm = ir.get("_frontmatter") if isinstance(ir.get("_frontmatter"), dict) else {};
    body: dict = {};
    for k in ir {
        if str(k) != "_frontmatter" { body[k] = ir[k]; }
    }
    out = str(yaml.safe_dump(body, sort_keys=False, allow_unicode=True));
    if fm {
        out = "---\n" + str(yaml.safe_dump(fm, sort_keys=False, allow_unicode=True)) + "---\n" + out;
    }
    return {"ir_text": out, "fixes": fixes};
}

# ---------------------------------------------------------------------------
# G4 — the compile oracle
# ---------------------------------------------------------------------------

def _diagnostic(out: str, budget: int = 2400) -> str {
    # `jac check` prints every diagnostic, errors first-come-first-served among
    # warnings, and a long module can push the real errors far above the end of
    # the output. Tailing it therefore hands the repair loop a diagnostic that
    # need not contain a single error — the repair then "fixes" a warning and
    # the gate fails again identically. Keep the ERROR blocks instead, and only
    # fall back to the tail when there are none (a FAILED with no error[E…]).
    blocks: list[str] = re.split(r"\n(?=" + chr(0x2716) + r" Error: |" + chr(0x26A0) + r" warning\[)", out);
    errs: list[str] = [b for b in blocks if re.search(r"error\[E\d+\]", b)];
    if not errs { return out[-budget:]; }
    kept: list[str] = [];
    used = 0;
    for b in errs {
        if used + len(b) > budget { break; }
        kept.append(b);
        used += len(b);
    }
    if not kept { kept = [errs[0][:budget]]; }
    dropped = len(errs) - len(kept);
    tail = ("\n\n... and " + str(dropped) + " more error(s)") if dropped > 0 else "";
    return "\n".join(kept).strip() + tail;
}

def compile_gate(ir_text: str, name: str, check: bool = True) -> CompileVerdict {
    # G4: the AG-IR must lower mechanically and type-check with zero errors.
    osp = "";
    try {
        osp = str(transpile_ir(ir_text, name));
    } except Exception as e {
        return CompileVerdict(ok=False, errors="transpile failed: " + str(traceback.format_exc())[-1200:]);
    }
    if "def run(" not in osp {
        return CompileVerdict(ok=False, module_src=osp, errors="lowered module has no run() entrypoint");
    }
    # The mechanical half is permissive: unparseable/empty IR still lowers to a
    # bare module whose run() returns "". That is a SILENT SUCCESS — fail loud
    # instead (the same choice sigil's _lower makes): require ≥1 lowered node.
    if "can n_" not in osp {
        return CompileVerdict(ok=False, module_src=osp, errors="lowered module has no nodes (empty/unparseable IR)");
    }
    if not check { return CompileVerdict(ok=True, module_src=osp); }
    tmp = tempfile.mkdtemp(prefix="sigil_g4_");
    path = os.path.join(tmp, re.sub(r"[^0-9a-zA-Z_]", "_", str(name)) + ".jac");
    try {
        with open(path, "w") as f { f.write(osp); }
        r = subprocess.run([_jac_bin(), "check", path], capture_output=True, text=True, timeout=180);
        out = str(r.stdout) + "\n" + str(r.stderr);
        n_err = len(re.findall(r"error\[E\d+\]", out));
        if (n_err > 0) or ("FAILED" in out and "PASSED" not in out) {
            return CompileVerdict(ok=False, module_src=osp, errors=f"jac check: {n_err} error(s)\n{_diagnostic(out)}");
        }
        return CompileVerdict(ok=True, module_src=osp);
    } except Exception as e {
        return CompileVerdict(ok=False, module_src=osp, errors="jac check could not run: " + str(e)[:400]);
    } finally {
        try { shutil.rmtree(tmp); } except Exception {  }
    }
}
