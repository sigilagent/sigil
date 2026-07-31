"""AI compiler — Stage 6: repair (one slot per error class, bounded, routed).

Per the verify/repair-loop findings (pipeline B.9.1): never one overloaded
repair sem — a repair slot written for one error class produces confident no-op
repairs when fed another. Two classes land here:

- COMPILE repair (`repair_ir`): the G4 oracle rejected the assembled IR — a
  tight GEN-EDIT over (ir_text, diagnostic) that fixes ONLY what the error
  requires. The loop re-gates after every attempt and is bounded.
- VIEW repair happens in lift(): assemble/gate issues route BACK to the owning
  flows (their ctx gains a 'FIX EXACTLY THESE' digest) — the flow that owns a
  view repairs it; nothing repairs a view it doesn't own.

Every attempt is recorded; exhaustion returns the last verdict WITH its errors
— an honest failure, never a silent success.
"""

import os;
import shutil;
import tempfile;
import from pathlib { Path }
import from jaclang.byllm.lib { Model }
import from .lift_types { CompileVerdict }
import from .gates { compile_gate }
# absolute imports (main.jac / gates.jac style): parent-relative `..` breaks here
import from src.sigil_claude_cc { agent_run }
import from src.sigil_runtime { repo_root, default_contract }

glob repair_llm: any = Model(model_name="gpt-4o-mini");
glob _REPAIR_PINNED: bool = False;

def pin_repair_llm(m: any) -> None {
    repair_llm = m;
    _REPAIR_PINNED = True;
}

sem repair_ir = """The AG-IR YAML failed to compile with the given diagnostic.
Return the COMPLETE corrected AG-IR YAML (frontmatter included) fixing ONLY
what the diagnostic requires — do not add, drop, or re-modalize anything else.
Output raw YAML only: no prose, no explanation, no markdown fences.""";
sem repair_ir.ir_text = "The full AG-IR YAML that failed.";
sem repair_ir.diagnostic = "The compile-oracle error to fix — and nothing else.";
def repair_ir(ir_text: str, diagnostic: str) -> str by repair_llm();

obj RepairOutcome {
    has verdict: CompileVerdict = CompileVerdict();
    has ir_text: str = "";
    has attempts: list[str] = [];
}

def repair_compile_loop(ir_text: str, name: str, max_attempts: int = 2) -> RepairOutcome {
    cur = ir_text;
    v = compile_gate(cur, name);
    attempts: list = [];
    n = 0;
    while (not v.ok) and (n < max_attempts) {
        n += 1;
        cur = str(repair_ir(cur, v.errors)).strip();
        if cur.startswith("```") {
            # strip an accidental fence despite the sem
            lines = cur.splitlines();
            lines = lines[1:];
            if lines and lines[-1].strip().startswith("```") { lines = lines[:-1]; }
            cur = "\n".join(lines);
        }
        v = compile_gate(cur, name);
        attempts.append("repair_ir attempt " + str(n) + ": " + ("fixed" if v.ok else "still failing"));
    }
    if (not v.ok) and claude_repair_enabled() {
        # The slot loop is out of attempts. A slot only ever sees (ir, diagnostic)
        # once per try; what is left to add is an AGENT that can run the oracle
        # itself and iterate against it. Escalate, then re-gate — the oracle stays
        # the authority, the agent is only allowed to propose.
        esc = claude_repair(cur, name, v.errors);
        attempts.extend(esc["attempts"]);
        if esc["ir_text"] {
            ev = compile_gate(str(esc["ir_text"]), name);
            if ev.ok { cur = str(esc["ir_text"]); v = ev; }
        }
    }
    return RepairOutcome(verdict=v, ir_text=cur, attempts=attempts);
}

# ---------------------------------------------------------------------------
# Escalation — hand the failing IR to a tool-using Claude Code session.
#
# Off unless SIGIL_CLAUDE_REPAIR=1 (which `--claude` sets): this spends a real
# agent session, not one slot call, so it is never the silent default. Read via
# env rather than importing sigil's flag, to keep the compiler free of a back-
# edge to the runtime that imports it.
# ---------------------------------------------------------------------------

def claude_repair_enabled() -> bool {
    return bool(os.getenv("SIGIL_CLAUDE_REPAIR", ""));
}

def _repair_brief(name: str, diagnostic: str) -> str {
    return (
        "The AG-IR in `agent.ir` does not compile.\n\n"
        + "Fix `agent.ir` IN PLACE until this passes:\n\n"
        + "    " + _sigil_bin() + " gate agent.ir " + name + "\n\n"
        + "Run that command yourself after every edit; it is the same compile "
        + "oracle the pipeline uses, and it exits nonzero while the IR is broken. "
        + "Keep going until it prints `gate: ok`.\n\n"
        + "The failing diagnostic was:\n\n" + str(diagnostic)[:3000] + "\n\n"
        + "Rules:\n"
        + "- `contract.md` is the AG-IR authoring contract. The IR must obey it.\n"
        + "- Fix ONLY what the diagnostic requires. Do not add, drop, reword or "
        + "re-modalize any step, rule, tool or check — this IR is a compiled "
        + "SKILL and changing its meaning is worse than failing to compile.\n"
        + "- Edit `agent.ir` only. Do not create other files.\n"
        + "- When `gate: ok` prints, stop and reply with the single word DONE."
    );
}

def _sigil_bin() -> str {
    import shutil;
    found = shutil.which("sigil");
    if found { return str(found); }
    local = os.path.join(repo_root(), "sigil");
    return local if os.path.exists(local) else "sigil";
}

def claude_repair(ir_text: str, name: str, diagnostic: str) -> dict {
    # Run a Claude Code agent over the failing IR in a scratch workspace. Returns
    # {"ir_text": the IR the agent left behind (or ""), "attempts": [...]}. Never
    # raises into the compile: an escalation that fails is simply no repair.
    work = tempfile.mkdtemp(prefix="sigil_repair_");
    ir_path = os.path.join(work, "agent.ir");
    attempts: list = [];
    out: str = "";
    try {
        with open(ir_path, "w") as f { f.write(ir_text); }
        with open(os.path.join(work, "contract.md"), "w") as f { f.write(default_contract()); }
        r = agent_run(
            prompt=_repair_brief(name, diagnostic),
            cwd=work,
            model=os.getenv("SIGIL_CLAUDE_FRONTIER", "claude-cc/opus"),
            max_turns=int(os.getenv("SIGIL_CLAUDE_REPAIR_TURNS", "40"))
        );
        out = Path(ir_path).read_text();
        changed = out.strip() != ir_text.strip();
        attempts.append(
            "claude escalation: " + str(r.get("num_turns", "?")) + " turns, "
            + ("IR rewritten" if changed else "IR unchanged")
            + (", $" + ("%.3f" % float(r.get("total_cost_usd") or 0.0)))
        );
        if not changed { out = ""; }
    } except Exception as e {
        attempts.append("claude escalation failed: " + str(e)[:200]);
        out = "";
    } finally {
        try { shutil.rmtree(work); } except Exception {  }
    }
    return {"ir_text": out, "attempts": attempts};
}
