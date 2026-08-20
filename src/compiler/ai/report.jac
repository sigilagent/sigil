"""AI compiler — the fix-forward report layer.

The gate battery's job is not to fail compiles; it is to say, precisely, what
the lowered agent will and will not do. This module is where every gate's
output converges into ONE typed verdict:

- classify: gate -> severity. Only a missing module is `fatal`. A finding that
  means a runtime crash or a violated mandate (G3/G6/G8/G9) is `error`; a
  faithfulness or quality note (spec/spine/assemble/G1/G5/G7) is `warn`;
  par opportunities are `info`.
- status_of: the four-state lift outcome (failed | degraded | fixed | clean).
  `failed` is reserved for "no runnable agent exists" — anything runnable
  persists, and its findings ride the result instead of killing it.
- explain: the honest exit note. A failed lift must never end in a bare
  RuntimeError — it ends in what failed, what the ladder tried, and the next
  concrete step per finding.

Strictness is the embedder's dial, not the compiler's default: SIGIL_STRICT=1
(or `sigil compile --strict`) restores fail-on-any-finding for CI.
"""

import os;
import re;
import from .ir_views { LiftResult }

# gate -> severity. G7 is an install-time fact about THIS machine, not a defect
# in the lift — warn by default, hard only when the embedder opts in.
glob _SEVERITY: dict = {
    "compile": "fatal",
    "G3": "error", "G6": "error", "G8": "error", "G9": "error",
    "G1": "warn", "G5": "warn", "G7": "warn", "G10": "warn", "G11": "warn",
    "spec": "warn", "spine": "warn", "assemble": "warn",
};

def classify(gate: str, message: str = "") -> str {
    g = str(gate);
    if (g == "G7") and (os.environ.get("SIGIL_G7_HARD", "") not in ["", "0", "false"]) {
        return "error";
    }
    # G11 (artifact embodiment) is precise enough to block once a corpus is clean.
    if (g == "G11") and (os.environ.get("SIGIL_G11_HARD", "") not in ["", "0", "false"]) {
        return "error";
    }
    return str(_SEVERITY.get(g, "warn"));
}

def finding(gate: str, message: str) -> dict {
    return {"gate": str(gate), "severity": classify(gate, message), "message": str(message)};
}

def auto_gate(message: str, fallback: str = "assemble") -> str {
    # gate name from a self-prefixed issue string ("G5: ..."), else the fallback.
    m = re.match(r"^(G\d+):", str(message));
    return str(m.group(1)) if m else fallback;
}

def resolved_by(message: str, fixes: list) -> bool {
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

def status_of(compiled: bool, findings: list, fixes: list, repairs: list) -> str {
    if not compiled { return "failed"; }
    residual = [f for f in findings if str(f.get("severity")) in ["fatal", "error", "warn"]];
    if residual { return "degraded"; }
    if fixes or repairs { return "fixed"; }
    return "clean";
}

def strict_mode() -> bool {
    return os.environ.get("SIGIL_STRICT", "") not in ["", "0", "false"];
}

def _sev_rank(f: dict) -> int {
    return int({"fatal": 0, "error": 1, "warn": 2, "info": 3}.get(str(f.get("severity")), 3));
}

def sort_findings(findings: list) -> list {
    return sorted(list(findings), key=_sev_rank);
}

def explain(lr: LiftResult) -> str {
    # The exit note — what happened, what the ladder tried, what to do next.
    # Deterministic: every gate already embeds its own "— do X" suggestion, so
    # explaining a failure costs no model call.
    lines: list = [];
    if lr.status == "failed" {
        lines.append("lift FAILED — no runnable agent was produced.");
        lines.append("");
        lines.append("The G4 compile oracle rejected the IR after the repair ladder"
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
