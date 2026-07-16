"""AI compiler — the public LIFT entrypoint.

SKILL.md text -> frozen Spec -> WorkFlow spine -> {IO, Context, Knowledge, HIL}
views (SPAWN fan-out) -> assembled AG-IR -> G4 compile oracle. Every stage's
verdict rides the LiftResult — `ok` is true only when the spec converged, the
spine validated, the join was lossless, AND the IR round-trips through the
mechanical half with zero errors. Anything less is reported, never swallowed.

The per-class repair loop (gate battery PR) hooks in after G4; until then a
failed gate is an honest failure the caller can inspect.
"""

import from .lift_types { RuleSet }
import from .ir_views { LiftResult, ViewBundle }
import from .spec_loop { extract_spec, pin_lift_llm }
import from .workflow { workflow_spine, pin_workflow_llm }
import from .flows { gather_views, spine_digest, pin_flows_llm }
import from .assemble { assemble }
import from .gates { compile_gate }

def pin_all_lift_llms(m: any) -> None {
    # one model for every LIFT stage (tests pin a shared MockLLM; production
    # binds the frontier tier here, mirroring sigil's awaken())
    pin_lift_llm(m);
    pin_workflow_llm(m);
    pin_flows_llm(m);
}

def lift(skill: str, name: str, parallel: bool = True) -> LiftResult {
    sr = extract_spec(skill, name);
    spec_issues: list = [];
    if not sr.verdict.sound { spec_issues.append("spec not sound: dropped " + ", ".join(sr.verdict.ungrounded)); }
    if not sr.verdict.complete { spec_issues.append("spec incomplete: uncovered " + " | ".join(sr.verdict.uncovered)); }
    if sr.verdict.drift { spec_issues.append("modality drift: " + " | ".join(sr.verdict.drift_notes)); }

    spine = workflow_spine(sr.spec, skill);
    vb = gather_views(sr.spec, spine_digest(spine.view, skill), parallel);
    asm = assemble(sr.spec, spine.view, vb, name);
    g4 = compile_gate(asm.ir_text, name);

    ok = g4.ok and (not spec_issues) and (not spine.issues) and (not asm.issues);
    return LiftResult(
        ok=ok, ir_text=asm.ir_text, module_src=g4.module_src, compile_errors=g4.errors,
        spec_issues=spec_issues, spine_issues=spine.issues, assemble_issues=asm.issues
    );
}
