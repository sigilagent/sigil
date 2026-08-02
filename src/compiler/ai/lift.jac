"""AI compiler — the public LIFT entrypoint.

SKILL.md text -> frozen Spec -> WorkFlow spine -> {IO, Context, Knowledge, HIL}
views (SPAWN fan-out) -> assembled AG-IR -> fix-forward gate battery ->
compiled module + report.

The gates DIAGNOSE; they do not veto. A lift FAILS only when no runnable
module exists (G4 rejects the IR after the whole repair ladder). Everything
else follows the fix-forward ladder, in order of preference:

  1. mechanical autofix (autofix.jac + autofix_carry_types — pure code,
     re-gated through G4; a patch the oracle rejects is never adopted),
  2. scoped model repair (view repair one pass; the bounded repair_ir loop),
  3. degrade with a note (a hollow code gate re-owned to a model slot),
  4. report the residual as a typed finding (report.jac: severity + the fix).

Gates in play: the spec loop's own grounding/coverage/modality audits, the
spine validator, the assemble join (reflexive 5d + cross-refs), G1 standalone
(embody-don't-point, builtin-aware), G4 the compile oracle, G5 STRUCT-COV
(per-mandate realization on the COMPILED module), G7-ENV (install-time facts —
advisory by default, SIGIL_G7_HARD=1 to harden), G8-PAR (false parallelism =
error; opportunities ride par_report), G9-TY (type unification; fixable
mismatches patched mechanically). `status` carries the four-state outcome
(failed | degraded | fixed | clean); `ok` keeps its historical meaning —
runnable AND nothing left to report. Nothing is ever swallowed: residuals ride
`findings`, applied fixes ride `fixes`, model repairs ride `repairs`.
"""

import from .ir_views { LiftResult }
import os;
import time;
import from .spec_loop { extract_spec, pin_lift_llm }
import from .workflow { workflow_spine, pin_workflow_llm }
import from .flows { gather_views, spine_digest, pin_flows_llm }
import from .assemble { assemble }
import from .gates { compile_gate, gate_standalone, gate_artifact_boundary, gate_hil_gates, gate_struct_cov, gate_env_binding, gate_concurrency, gate_type_unification, autofix_carry_types }
import from .repair { repair_compile_loop, pin_repair_llm }
import from .autofix { autofix_ir }
import from .report { finding, auto_gate, resolved_by, status_of }

def pin_all_lift_llms(m: any) -> None {
    # one model for every LIFT stage (tests pin a shared MockLLM; production
    # binds the frontier tier here, mirroring sigil's awaken())
    pin_lift_llm(m);
    pin_workflow_llm(m);
    pin_flows_llm(m);
    pin_repair_llm(m);
}

# Optional progress hook: the CLI attaches a renderer; None = silent. Guarded —
# a renderer bug must never kill a compile.
glob lift_progress: any = None;

def set_lift_progress(cb: any) -> None {
    lift_progress = cb;
}

def _emit(ev: dict) -> None {
    if lift_progress {
        try { lift_progress(ev); } except Exception {  }
    }
}

def lift(skill: str, name: str, parallel: bool = True, skill_dir: str = "") -> LiftResult {
    # skill_dir: the directory SKILL.md came from, when the caller has one —
    # lets the autofix passes embody sibling files ("See FORMS.md") at compile
    # time instead of reporting them as pointers.
    repairs: list = [];

    _t0 = time.time();
    _emit({"stage": "spec", "state": "start"});
    sr = extract_spec(skill, name);
    _emit({"stage": "spec", "state": "done", "secs": time.time() - _t0,
           "rules": len(sr.spec.rules), "rounds": sr.verdict.rounds,
           "sound": sr.verdict.sound, "complete": sr.verdict.complete,
           "drift": sr.verdict.drift});
    spec_issues: list = [];
    if not sr.verdict.sound { spec_issues.append("spec not sound: dropped " + ", ".join(sr.verdict.ungrounded)); }
    if not sr.verdict.complete { spec_issues.append("spec incomplete: uncovered " + " | ".join(sr.verdict.uncovered)); }
    if sr.verdict.drift { spec_issues.append("modality drift: " + " | ".join(sr.verdict.drift_notes)); }

    _t1 = time.time();
    _emit({"stage": "spine", "state": "start"});
    spine = workflow_spine(sr.spec, skill);
    _emit({"stage": "spine", "state": "done", "secs": time.time() - _t1,
           "nodes": len(spine.view.nodes), "edges": len(spine.view.edges),
           "rounds": spine.rounds, "issues": len(spine.issues)});
    ctx = spine_digest(spine.view, skill);
    _t2 = time.time();
    _emit({"stage": "flows", "state": "start"});
    vb = gather_views(sr.spec, ctx, parallel);
    _emit({"stage": "flows", "state": "done", "secs": time.time() - _t2,
           "carries": len(vb.io.carries), "tools": len(vb.kn.tools),
           "knowledge": len(vb.kn.knowledge), "hil": len(vb.hil.points)});
    _t3 = time.time();
    _emit({"stage": "assemble", "state": "start"});
    asm = assemble(sr.spec, spine.view, vb, name);
    g1 = gate_standalone(vb) + gate_artifact_boundary(sr.spec, spine.view, vb) + gate_hil_gates(spine.view, vb);
    _emit({"stage": "assemble", "state": "done", "secs": time.time() - _t3,
           "issues": len(asm.issues) + len(g1)});

    # VIEW repair — route assemble/G1/G3 issues back to the owning flows, one pass:
    # each flow re-emits its own view with the exact issues to fix in its ctx.
    if asm.issues or g1 {
        all_issues = asm.issues + g1;
        ctx2 = ctx + "\nFIX EXACTLY THESE ISSUES (change nothing else):\n- " + "\n- ".join([str(i) for i in all_issues]);
        _emit({"stage": "repair", "state": "start", "round": 1,
               "issues": len(all_issues), "target": "views"});
        vb2 = gather_views(sr.spec, ctx2, parallel);
        asm2 = assemble(sr.spec, spine.view, vb2, name);
        g1_2 = gate_standalone(vb2) + gate_artifact_boundary(sr.spec, spine.view, vb2) + gate_hil_gates(spine.view, vb2);
        if (len(asm2.issues) + len(g1_2)) < (len(asm.issues) + len(g1)) {
            vb = vb2; asm = asm2; g1 = g1_2;
            repairs.append("view repair: " + str(len(all_issues)) + " -> " + str(len(asm.issues) + len(g1)) + " issue(s)");
        } else {
            repairs.append("view repair attempted, no improvement — keeping first pass");
        }
    }

    # COMPILE repair — the G4 oracle drives the scoped repair_ir loop, bounded.
    _t4 = time.time();
    _emit({"stage": "gates", "state": "start"});
    ro = repair_compile_loop(asm.ir_text, name);
    _emit({"stage": "gates", "state": "done", "secs": time.time() - _t4,
           "g4": ro.verdict.ok, "g1_issues": len(g1), "repairs": len(ro.attempts)});
    for a in ro.attempts { repairs.append(a); }
    g4 = ro.verdict;
    ir_text = ro.ir_text;

    # MECHANICAL FIX-FORWARD on the compiled IR — the autofix chain (lanes /
    # pointers / hollow re-own, then G9 carry-type unification), each patch
    # re-gated through G4: the oracle stays the authority, a chain it rejects
    # falls back to the narrower candidate, then to the original.
    fixes: list = [];
    if g4.ok {
        _ta = time.time();
        _emit({"stage": "autofix", "state": "start"});
        af = autofix_ir(ir_text, skill_dir);
        base: str = str(af["ir_text"]);
        af_fixes: list[str] = [str(f0) for f0 in list(af["fixes"])];
        fx = autofix_carry_types(base);
        ty_fixes: list[str] = ["G9 autofix: " + str(f9) for f9 in list(fx["fixes"])];
        # widest candidate first (chain + types), then chain-only, then original
        cand_irs: list[str] = [];
        cand_fixes: list[list[str]] = [];
        if ty_fixes { cand_irs.append(str(fx["ir_text"])); cand_fixes.append(af_fixes + ty_fixes); }
        if af_fixes { cand_irs.append(base); cand_fixes.append(af_fixes); }
        ci = 0;
        while ci < len(cand_irs) {
            vfx = compile_gate(cand_irs[ci], name);
            if vfx.ok {
                ir_text = cand_irs[ci];
                g4 = vfx;
                for fn0 in cand_fixes[ci] { fixes.append(fn0); }
                break;
            } else {
                repairs.append("autofix candidate (" + str(len(cand_fixes[ci])) + " fix(es)) failed the G4 re-gate — narrowed");
            }
            ci += 1;
        }
        _emit({"stage": "autofix", "state": "done", "secs": time.time() - _ta,
               "fixes": len(fixes)});
    }

    # RESIDUAL GATES on the final IR/module — findings, not vetoes. Severity
    # lives in report.jac: G9/G8(false-par) are errors (runtime crashes with a
    # green compile), G5/G7 and the view-level audit notes are warnings.
    findings: list = [];
    if g4.ok {
        for i9 in gate_type_unification(ir_text) { findings.append(finding("G9", str(i9))); }
        sc = gate_struct_cov(sr.spec, spine.view, g4.module_src);
        for i2 in sc.issues { findings.append(finding("G5", str(i2))); }
    }

    # G7-ENV + G8-PAR (the SkillRT-inspired mechanical passes) on the FINAL IR.
    # G7 missing deps are install-time facts about THIS machine — warnings by
    # default (SIGIL_G7_HARD=1 to harden); they always ride env_report. G8
    # false parallelism is an error; opportunities / DLP ride par_report.
    env_report: list = [];
    par_report: list = [];
    if g4.ok {
        _t5 = time.time();
        _emit({"stage": "bind", "state": "start"});
        g7 = gate_env_binding(ir_text);
        for i3 in g7 {
            env_report.append(str(i3));
            findings.append(finding("G7", str(i3)));
        }
        g8 = gate_concurrency(ir_text);
        g8_issues = list(g8["issues"]);
        g8_opps = list(g8["opportunities"]);
        g8_dlp = list(g8["dlp"]);
        for i4 in g8_issues { findings.append(finding("G8", str(i4))); }
        for o4 in g8_opps { par_report.append(str(o4)); }
        for d4 in g8_dlp { par_report.append(str(d4)); }
        _emit({"stage": "bind", "state": "done", "secs": time.time() - _t5,
               "g7_issues": len(g7), "g8_issues": len(g8_issues),
               "par_opps": len(g8_opps) + len(g8_dlp)});
    }

    # View-level audit notes -> findings, minus what the autofix chain already
    # resolved (the fix note carries the story; keeping the issue would report
    # a fixed defect as open).
    for s0 in spec_issues { findings.append(finding("spec", str(s0))); }
    for s1 in spine.issues { findings.append(finding("spine", str(s1))); }
    for s2 in asm.issues {
        if not resolved_by(str(s2), fixes) { findings.append(finding("assemble", str(s2))); }
    }
    for s3 in g1 {
        if not resolved_by(str(s3), fixes) { findings.append(finding(auto_gate(str(s3), "G1"), str(s3))); }
    }

    status = status_of(g4.ok, findings, fixes, repairs);
    residual = [str(f["message"]) for f in findings if str(f["severity"]) != "info"];
    ok = g4.ok and (not residual);
    return LiftResult(
        ok=ok, ir_text=ir_text, module_src=g4.module_src, compile_errors=g4.errors,
        spec_issues=spec_issues, spine_issues=spine.issues, assemble_issues=asm.issues,
        gate_issues=residual, repairs=repairs,
        env_report=env_report, par_report=par_report,
        status=status, findings=findings, fixes=fixes
    );
}
