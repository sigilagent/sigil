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
import from .author_direct { author_direct, _views_from_ir, pin_direct_llm }

def pin_all_lift_llms(m: any) -> None {
    # one model for every LIFT stage (tests pin a shared MockLLM; production
    # binds the frontier tier here, mirroring sigil's awaken())
    pin_lift_llm(m);
    pin_workflow_llm(m);
    pin_flows_llm(m);
    pin_repair_llm(m);
    pin_direct_llm(m);
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

# ---------------------------------------------------------------------------
# The shared fix-forward tail — both front-ends (direct + staged) produce an
# ir_text + a WorkflowView + a G1 issue list, then run this identical ladder:
# compile-repair -> mechanical autofix (re-gated) -> residual gates -> findings.
# ---------------------------------------------------------------------------
def _finalize(sr: any, ir_in: str, wf: any, g1: list, name: str, skill_dir: str,
              repairs: list, spec_issues: list, spine_issues: list, asm_issues: list) -> LiftResult {
    # COMPILE repair — the G4 oracle drives the scoped repair_ir loop, bounded.
    _t4 = time.time();
    _emit({"stage": "gates", "state": "start"});
    ro = repair_compile_loop(ir_in, name);
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
        _emit({"stage": "autofix", "state": "done", "secs": time.time() - _ta, "fixes": len(fixes)});
    }

    # RESIDUAL GATES on the final IR/module — findings, not vetoes.
    findings: list = [];
    if g4.ok {
        for i9 in gate_type_unification(ir_text) { findings.append(finding("G9", str(i9))); }
        sc = gate_struct_cov(sr.spec, wf, g4.module_src);
        for i2 in sc.issues { findings.append(finding("G5", str(i2))); }
    }

    env_report: list = [];
    par_report: list = [];
    if g4.ok {
        _t5 = time.time();
        _emit({"stage": "bind", "state": "start"});
        g7 = gate_env_binding(ir_text);
        for i3 in g7 { env_report.append(str(i3)); findings.append(finding("G7", str(i3))); }
        g8 = gate_concurrency(ir_text);
        g8_issues = list(g8["issues"]);
        g8_opps = list(g8["opportunities"]);
        g8_dlp = list(g8["dlp"]);
        for i4 in g8_issues { findings.append(finding("G8", str(i4))); }
        for o4 in g8_opps { par_report.append(str(o4)); }
        for d4 in g8_dlp { par_report.append(str(d4)); }
        _emit({"stage": "bind", "state": "done", "secs": time.time() - _t5,
               "g7_issues": len(g7), "g8_issues": len(g8_issues), "par_opps": len(g8_opps) + len(g8_dlp)});
    }

    # View-level audit notes -> findings, minus what the autofix chain resolved.
    for s0 in spec_issues { findings.append(finding("spec", str(s0))); }
    for s1 in spine_issues { findings.append(finding("spine", str(s1))); }
    for s2 in asm_issues {
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
        spec_issues=spec_issues, spine_issues=spine_issues, assemble_issues=asm_issues,
        gate_issues=residual, repairs=repairs,
        env_report=env_report, par_report=par_report,
        status=status, findings=findings, fixes=fixes
    );
}

def _coverage_miss(lr: LiftResult) -> bool {
    # A TRUE missing-coverage finding (a mandatory rule with no realization) — not
    # a monolithic one, which is realized-but-weak and still worth keeping. This
    # is the fallback trigger: a direct authoring that dropped an obligation is
    # exactly what the staged pipeline's coverage critics exist to catch.
    for f in lr.findings {
        if str(f.get("gate")) == "G5" {
            m = str(f.get("message"));
            if ("NO realization" in m) or ("structural gap" in m) or ("realized HOLLOW" in m) { return True; }
        }
    }
    return False;
}

def _lift_direct(skill: str, name: str, sr: any, spec_issues: list, skill_dir: str) -> LiftResult {
    # ONE grounded authoring pass (guide + golden few-shot + frozen spec) replaces
    # spine/flows/assemble; the gates read views reconstructed from the authored IR.
    _t1 = time.time();
    _emit({"stage": "author", "state": "start"});
    au = author_direct(skill, sr.spec, name);
    ir: str = str(au["ir_text"]).strip();
    notes: list = list(au["notes"]);
    _emit({"stage": "author", "state": "done", "secs": time.time() - _t1, "lines": len(ir.splitlines())});
    if not ir {
        return LiftResult(ok=False, status="failed", spec_issues=spec_issues,
                          gate_issues=["direct author: produced no AG-IR"],
                          findings=[finding("compile", "direct author produced no AG-IR")], repairs=notes);
    }
    (wf, vb) = _views_from_ir(ir);
    g1 = gate_standalone(vb) + gate_artifact_boundary(sr.spec, wf, vb) + gate_hil_gates(wf, vb);
    return _finalize(sr, ir, wf, g1, name, skill_dir, notes, spec_issues, [], []);
}

def _lift_staged(skill: str, name: str, sr: any, spec_issues: list, parallel: bool, skill_dir: str) -> LiftResult {
    repairs: list = [];
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

    return _finalize(sr, asm.ir_text, spine.view, g1, name, skill_dir,
                     repairs, spec_issues, spine.issues, asm.issues);
}

def lift(skill: str, name: str, parallel: bool = True, skill_dir: str = "") -> LiftResult {
    # DIRECT by default — one grounded authoring pass (guide + golden few-shot +
    # frozen spec) replaces spine/flows/assemble; STAGED is the fallback and the
    # forced mode under SIGIL_STAGED=1. The spec loop runs ONCE and is shared by
    # both front-ends, so grounding is kept whichever authors the IR. Fallback
    # fires when direct fails to compile OR drops rule coverage — exactly what the
    # staged pipeline's coverage critics exist to catch.
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

    staged_forced = os.environ.get("SIGIL_STAGED", "") not in ["", "0", "false"];
    if not staged_forced {
        lr = _lift_direct(skill, name, sr, spec_issues, skill_dir);
        if (lr.status != "failed") and (not _coverage_miss(lr)) {
            lr.repairs = ["front-end: direct"] + list(lr.repairs);
            return lr;
        }
        _reason = "direct " + ("failed to compile" if lr.status == "failed" else "missed rule coverage");
        _emit({"stage": "repair", "state": "start", "round": 1, "issues": 1, "target": "fallback-to-staged"});
        lr2 = _lift_staged(skill, name, sr, spec_issues, parallel, skill_dir);
        lr2.repairs = ["front-end: staged (" + _reason + "; fell back)"] + list(lr2.repairs);
        return lr2;
    }
    lr3 = _lift_staged(skill, name, sr, spec_issues, parallel, skill_dir);
    lr3.repairs = ["front-end: staged (forced)"] + list(lr3.repairs);
    return lr3;
}
