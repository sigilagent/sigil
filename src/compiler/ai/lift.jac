"""AI compiler — the public LIFT entrypoint.

SKILL.md text -> frozen Spec -> WorkFlow spine -> {IO, Context, Knowledge, HIL}
views (SPAWN fan-out) -> assembled AG-IR -> gate battery -> compiled module.

Gates in play: the spec loop's own grounding/coverage/modality audits, the
spine validator, the assemble join (reflexive 5d + cross-refs), G1 standalone
(embody-don't-point), G4 the compile oracle, and G5 STRUCT-COV (per-mandate
realization on the COMPILED module). Repair is per error class and bounded:
assemble/G1 issues route back to the owning flows (view repair, one pass); G4
failures run the scoped repair_ir loop. `ok` is true only when every gate is
clean — anything less rides the LiftResult, never swallowed.
"""

import from .ir_views { LiftResult }
import from .spec_loop { extract_spec, pin_lift_llm }
import from .workflow { workflow_spine, pin_workflow_llm }
import from .flows { gather_views, spine_digest, pin_flows_llm }
import from .assemble { assemble }
import from .gates { compile_gate, gate_standalone, gate_struct_cov }
import from .repair { repair_compile_loop, pin_repair_llm }

def pin_all_lift_llms(m: any) -> None {
    # one model for every LIFT stage (tests pin a shared MockLLM; production
    # binds the frontier tier here, mirroring sigil's awaken())
    pin_lift_llm(m);
    pin_workflow_llm(m);
    pin_flows_llm(m);
    pin_repair_llm(m);
}

def lift(skill: str, name: str, parallel: bool = True) -> LiftResult {
    repairs: list = [];

    sr = extract_spec(skill, name);
    spec_issues: list = [];
    if not sr.verdict.sound { spec_issues.append("spec not sound: dropped " + ", ".join(sr.verdict.ungrounded)); }
    if not sr.verdict.complete { spec_issues.append("spec incomplete: uncovered " + " | ".join(sr.verdict.uncovered)); }
    if sr.verdict.drift { spec_issues.append("modality drift: " + " | ".join(sr.verdict.drift_notes)); }

    spine = workflow_spine(sr.spec, skill);
    ctx = spine_digest(spine.view, skill);
    vb = gather_views(sr.spec, ctx, parallel);
    asm = assemble(sr.spec, spine.view, vb, name);
    g1 = gate_standalone(vb);

    # VIEW repair — route assemble/G1 issues back to the owning flows, one pass:
    # each flow re-emits its own view with the exact issues to fix in its ctx.
    if asm.issues or g1 {
        all_issues = asm.issues + g1;
        ctx2 = ctx + "\nFIX EXACTLY THESE ISSUES (change nothing else):\n- " + "\n- ".join([str(i) for i in all_issues]);
        vb2 = gather_views(sr.spec, ctx2, parallel);
        asm2 = assemble(sr.spec, spine.view, vb2, name);
        g1_2 = gate_standalone(vb2);
        if (len(asm2.issues) + len(g1_2)) < (len(asm.issues) + len(g1)) {
            vb = vb2; asm = asm2; g1 = g1_2;
            repairs.append("view repair: " + str(len(all_issues)) + " -> " + str(len(asm.issues) + len(g1)) + " issue(s)");
        } else {
            repairs.append("view repair attempted, no improvement — keeping first pass");
        }
    }

    # COMPILE repair — the G4 oracle drives the scoped repair_ir loop, bounded.
    ro = repair_compile_loop(asm.ir_text, name);
    for a in ro.attempts { repairs.append(a); }
    g4 = ro.verdict;
    ir_text = ro.ir_text;

    # G5 STRUCT-COV on the compiled module: how is each mandate realized?
    gate_issues: list = list(g1);
    if g4.ok {
        sc = gate_struct_cov(sr.spec, spine.view, g4.module_src);
        for i2 in sc.issues { gate_issues.append(i2); }
    }

    ok = g4.ok and (not spec_issues) and (not spine.issues) and (not asm.issues) and (not gate_issues);
    return LiftResult(
        ok=ok, ir_text=ir_text, module_src=g4.module_src, compile_errors=g4.errors,
        spec_issues=spec_issues, spine_issues=spine.issues, assemble_issues=asm.issues,
        gate_issues=gate_issues, repairs=repairs
    );
}
