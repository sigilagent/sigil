"""AI compiler — the gate battery. This module seeds it with G4, the compile
oracle: round-trip a candidate AG-IR through the MECHANICAL half
(transpile_ir) and the jac type-checker. This is the property a manual lift
never has — a deterministic ground truth on every iteration. Later gates
(standalone / C1 / determinization / STRUCT-COV / grounding) land beside it.

Every verdict is typed and must be ROUTED by the caller — an unrouted failure
is a silent success (pipeline B.9.1).
"""

import os;
import re;
import shutil;
import subprocess;
import tempfile;
import traceback;
# absolute import (main.jac style): a parent-relative `..mechanical` breaks under
# `jac test`, which roots the package at the module's own directory.
import from src.compiler.mechanical.compiler { transpile_ir }
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
        for n2 in owners {
            nid = re.sub(r"[^0-9a-zA-Z_]", "_", str(n2.id));
            has_ability = ("can n_" + nid) in module_src;
            if not has_ability { continue; }
            if n2.owner == Owner.CODE {
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
        } else {
            sc.missing.append(r.id);
            sc.issues.append("G5: rule '" + r.id + "' traced to node(s) that never lowered to an ability — structural gap");
        }
    }
    return sc;
}

# ---------------------------------------------------------------------------
# G4 — the compile oracle
# ---------------------------------------------------------------------------

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
            tail = out[-1600:];
            return CompileVerdict(ok=False, module_src=osp, errors=f"jac check: {n_err} error(s)\n{tail}");
        }
        return CompileVerdict(ok=True, module_src=osp);
    } except Exception as e {
        return CompileVerdict(ok=False, module_src=osp, errors="jac check could not run: " + str(e)[:400]);
    } finally {
        try { shutil.rmtree(tmp); } except Exception {  }
    }
}
