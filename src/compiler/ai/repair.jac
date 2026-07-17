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

import from jaclang.byllm.lib { Model }
import from .lift_types { CompileVerdict }
import from .gates { compile_gate }

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
    return RepairOutcome(verdict=v, ir_text=cur, attempts=attempts);
}
