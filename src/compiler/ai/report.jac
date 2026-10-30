"""AI compiler — the report layer, where every gate's output becomes one verdict.

The checks are the SIGIL paper's pre-lowering validation battery (arXiv
2607.27309, Appendix A.2, Table 2), each Sigil check filed under the paper
check it implements:

    G1  source grounding           G1_TRACE (provenance fan-out)
    G2  requirement realization    G2 (structural coverage), G2_ARTIFACT,
                                   G2_EMBODY, G2_OVERLOAD, G2_FLOW, G2_ORDER
    G3  execution preservation     G3_HIL
    G4  type and data flow         G4 (type unification), G4_REACH, G4_INPUT
    G5  reference resolution       G5 (embodied, not pointed at), G5_BLOAT
    G6  binding and control flow   G6_ENV, G6_PAR

COMPILE — lowering plus the target's type check — runs after them, as in the
paper's pipeline.

- classify: gate -> severity. `fatal` means no module exists. `error` means a
  runtime crash or a violated mandate riding a green compile. `warn` is a
  faithfulness or quality note; `info` a missed opportunity.
- status_of: the four-state outcome (failed | degraded | fixed | clean). As the
  paper specifies (§3.3), compilation FAILS when errors remain after the repair
  budget: an error finding that survived the fix-forward ladder fails the lift
  even though a module lowered. SIGIL_GATE_FAIL_ON_ERROR=0 restores the older
  diagnose-don't-veto contract, where only a missing module fails.
- explain: the honest exit note — what failed, what the ladder tried, and the
  next concrete step per finding.

SIGIL_STRICT=1 (or `sigil compile --strict`) additionally fails on warnings.
"""

import os;
import re;
import from .ir_views { LiftResult }

# gate -> severity. G6_ENV is an install-time fact about THIS machine, not a defect
# in the lift — warn by default, hard only when the embedder opts in.
glob _SEVERITY: dict[str, any] = {
    "compile": "fatal", "COMPILE": "fatal",
    # G4_INPUT is a defect the caller feels at the boundary (no way to name the file),
    # and autofix repairs it mechanically — a residual one survived that repair.
    "G2_ARTIFACT": "error", "G3_HIL": "error", "G6_PAR": "error", "G4": "error",
    "G4_REACH": "error", "G2_OVERLOAD": "error", "G4_INPUT": "error",
    # A violated prohibition or ordering constraint is a violated mandate.
    "G2_FLOW": "error", "G2_ORDER": "error",
    "G5": "warn", "G2": "warn", "G6_ENV": "warn", "G1_TRACE": "warn", "G2_EMBODY": "warn",
    # G5_BLOAT is a performance note, not a defect: the artifact is correct, it will
    # just carry more prose per decision than it needs to.
    "G5_BLOAT": "warn",
    "spec": "warn", "spine": "warn", "assemble": "warn",
};

def _env_on(names: list[str]) -> bool {
    for nm in names {
        if os.environ.get(nm, "") not in ["", "0", "false"] { return True; }
    }
    return False;
}

def classify(gate: str, message: str = "") -> str {
    g = str(gate);
    if (g == "G6_ENV") and _env_on(["SIGIL_G6_ENV_HARD", "SIGIL_G7_HARD"]) {
        return "error";
    }
    # G2_EMBODY (artifact embodiment) is precise enough to block once a corpus is clean.
    if (g == "G2_EMBODY") and _env_on(["SIGIL_G2_EMBODY_HARD", "SIGIL_G11_HARD"]) {
        return "error";
    }
    return str(_SEVERITY.get(g, "warn"));
}

def finding(gate: str, message: str) -> dict[str, any] {
    return {"gate": str(gate), "severity": classify(gate, message), "message": str(message)};
}

def auto_gate(message: str, fallback: str = "assemble") -> str {
    # gate name from a self-prefixed issue string ("G2: ...", "G4_REACH: ..."),
    # else the fallback.
    m = re.match(r"^(G\d(?:_[A-Z]+)?|COMPILE):", str(message));
    return str(m.group(1)) if m else fallback;
}

def resolved_by(message: str, fixes: list[any]) -> bool {
    # An issue is superseded when a fix note names one of the same 'quoted'
    # subjects (tool/knowledge/carry/node id). The fix note carries the story
    # forward; keeping the original issue would report a fixed defect as open.
    subjects = re.findall(r"'([^']+)'", str(message));
    if not subjects { return False; }
    for f in fixes {
        for s in subjects {
            if ("'" + str(s) + "'") in str(f) { return True; }
        }
    }
    return False;
}

def fail_on_error() -> bool {
    return gate_enabled("FAIL_ON_ERROR");
}

def blocking(findings: list[any]) -> list[any] {
    # The findings that fail a lift under the paper's contract: an error (or a
    # fatal) that survived the repair ladder.
    return [f for f in findings if str(f.get("severity")) in ["fatal", "error"]];
}

def status_of(compiled: bool, findings: list[any], fixes: list[any], repairs: list[any]) -> str {
    if not compiled { return "failed"; }
    if fail_on_error() and blocking(findings) { return "failed"; }
    residual = [f for f in findings if str(f.get("severity")) in ["fatal", "error", "warn"]];
    if residual { return "degraded"; }
    if fixes or repairs { return "fixed"; }
    return "clean";
}

# Per-gate kill switch, DEFAULT ON. A gate exists to reject a shape the compiler
# cannot lower correctly, so the useful default is always "enforced" — a gate you
# have to remember to turn on is a gate that is off. But a new gate meets corpora
# its author never saw, and the cost of being wrong there is a skill that will not
# compile at all, so every gate keeps a documented way out that does not involve
# editing the compiler:
#
#   SIGIL_GATE_G4_REACH=0               turn one check off
#   SIGIL_GATE_G2=0                     turn a whole paper check off (G2 and G2_*)
#   SIGIL_GATES_OFF=G4_REACH,G2_OVERLOAD turn several off in one variable
#
# The numbered ids before the paper alignment still work where they are not
# ambiguous (G7..G14). G1..G6 now name the paper's checks. Accepts 0/false/no/off,
# case-insensitive.
glob _LEGACY_GATE_IDS: dict[str, str] = {
    "G7": "G6_ENV", "G8": "G6_PAR", "G9": "G4", "G9_REACH": "G4_REACH", "G10": "G1_TRACE",
    "G11": "G2_EMBODY", "G12": "G2_OVERLOAD", "G13": "G5_BLOAT", "G14": "G4_INPUT"
};

def _gate_aliases(name: str) -> list[str] {
    n = str(name).strip().upper();
    names: list[str] = [n];
    grp: any = re.match(r"^(G\d)_[A-Z_]+$", n);
    if grp { names.append(str(grp.group(1))); }
    for old in _LEGACY_GATE_IDS {
        if str(_LEGACY_GATE_IDS[old]) == n { names.append(str(old)); }
    }
    return names;
}

def gate_enabled(name: str) -> bool {
    names = _gate_aliases(name);
    for nm in names {
        one = str(os.environ.get("SIGIL_GATE_" + nm, "")).strip().lower();
        if one in ["0", "false", "no", "off"] { return False; }
    }
    off = str(os.environ.get("SIGIL_GATES_OFF", ""));
    for tok in re.split(r"[,\s]+", off) {
        if str(tok).strip().upper() in names { return False; }
    }
    return True;
}

def strict_mode() -> bool {
    return os.environ.get("SIGIL_STRICT", "") not in ["", "0", "false"];
}

def _sev_rank(f: dict[str, any]) -> int {
    return int({"fatal": 0, "error": 1, "warn": 2, "info": 3}.get(str(f.get("severity")), 3));
}

def sort_findings(findings: list[any]) -> list[any] {
    return sorted(list(findings), key=_sev_rank);
}

def explain(lr: LiftResult) -> str {
    # The exit note — what happened, what the ladder tried, what to do next.
    # Deterministic: every gate already embeds its own "— do X" suggestion, so
    # explaining a failure costs no model call.
    lines: list = [];
    rejected = (lr.status == "failed") and bool(str(lr.module_src).strip());
    if rejected {
        # a module lowered, but the paper's contract fails a compile whose
        # errors outlive the repair budget (§3.3)
        lines.append("lift FAILED — " + str(len(blocking(lr.findings)))
                     + " error finding(s) remained after the repair ladder"
                     + (" (" + str(len(lr.repairs)) + " attempt(s))" if lr.repairs else "") + ".");
        lines.append("A module lowered, but an error is a runtime crash or a violated mandate,"
                     + " so it is not persisted. SIGIL_GATE_FAIL_ON_ERROR=0 keeps it anyway.");
    } elif lr.status == "failed" {
        lines.append("lift FAILED — no runnable agent was produced.");
        lines.append("");
        lines.append("The COMPILE oracle rejected the IR after the repair ladder"
                     + (" (" + str(len(lr.repairs)) + " attempt(s))" if lr.repairs else "") + ":");
        if lr.compile_errors {
            for el in str(lr.compile_errors).strip().splitlines()[:14] { lines.append("  " + el); }
        }
    } elif lr.status == "degraded" {
        lines.append("lift produced a RUNNABLE agent with "
                     + str(len(lr.findings)) + " noted deviation(s) — persisted; review below.");
    } elif lr.status == "fixed" {
        lines.append("lift produced a clean agent after "
                     + str(len(lr.fixes) + len(lr.repairs)) + " fix(es).");
    } else {
        lines.append("lift clean — nothing found, nothing needed.");
    }
    if lr.fixes {
        lines.append("");
        lines.append("fixed along the way:");
        for fx in lr.fixes { lines.append("  + " + str(fx)); }
    }
    if lr.repairs {
        lines.append("");
        lines.append("repair ladder:");
        for rp in lr.repairs { lines.append("  ~ " + str(rp)); }
    }
    if lr.findings {
        lines.append("");
        lines.append("findings (each names its own fix):");
        for f in sort_findings(lr.findings) {
            lines.append("  [" + str(f.get("severity")) + "] " + str(f.get("message")));
        }
    }
    if lr.status == "failed" {
        lines.append("");
        lines.append("next steps:");
        lines.append("  - iterate on the IR against the same oracle:  sigil gate <file.agir> <name>");
        lines.append("  - escalate to an agent repair session:        SIGIL_CLAUDE_REPAIR=1 (or --claude)");
    }
    return "\n".join(lines);
}
