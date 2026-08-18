"""raise2 — the rearchitected front-end (Layer 1 authoring + Layer 2 verify + Layer 4 control).

The pipeline, faithfulness-first:

    spec loop  →  author (coherent, one pass)  →  FAITHFULNESS closure
                        ▲                                │
                        └──── rule-scoped repair ◀───────┘  (same author, close exactly the gaps)
                                                         │
                                    phase 2: refinement passes  (whole-IR, monotone)
                                                         │
                                       coherence gate (G4) ── a typed PROOF, not just a module

Two things that differ from `lift()`:

1. Severity is split on the faithfulness/coherence axis. A dropped or added rule
   (of ANY kind — prohibition, gate, knowledge, grounding, not just MANDATORY
   STEP/IO) makes the raise `unfaithful` and NOT ok, even if it compiles clean.
   Coherence problems still degrade under fix-forward. This is the reprioritization
   the whole rearchitecture turns on: an agent that silently violates the skill is
   a compliance failure, not a runnable success.

2. The safety net is rule-scoped repair by the SAME coherent author, not a
   wholesale fall-back to a different (seam-producing) pipeline. The closure hands
   back the exact unrealized rule ids + fixes; the author closes only those. One
   author still writes every cross-reference, so coherence is preserved WHILE the
   gap is closed — the property `lift()` could not get from one front-end.

3. Authoring stays ONE call, but refinement is staged after it (`passes.jac`).
   The staged front-end cut the *artifact* by view and had to reconcile the
   cross-references afterward; phase 2 cuts by *dimension* instead — each pass
   sees the whole IR and improves one property. Gated: `--no-phase2` /
   `SIGIL_PHASE2=0` restores the exact pre-phase-2 pipeline.
"""

import time;
import from .spec_loop { extract_spec, pin_lift_llm, pin_adjudge_llm, strip_frontmatter, RuleSet, ClarifyItem, apply_clarifications, resolve_ambiguous_default, adjudicate_spec }
import from .author_direct { author_direct, pin_direct_llm }
import from .faith { faithfulness_report, FaithReport, proof_lines, fold_untraced_prohibitions, gap_score }
import from .gates { compile_gate }
import from .passes { run_passes }
# The same progress seam the legacy lift uses: compile_skill installs the CLI's
# (or chat's) renderer via set_lift_progress BEFORE dispatching here, so raise2
# narrates through the identical hook. Without these events the DEFAULT compile
# ran its whole multi-minute pipeline in total silence.
import from .lift { _emit }

obj RaiseResult {
    has ok: bool = False;           # faithful AND compiles
    has status: str = "failed";     # failed | unfaithful | uncompilable | faithful
    has ir_text: str = "";
    has module_src: str = "";
    has proof: FaithReport = FaithReport();
    has rounds: int = 0;
    has repairs: list[str] = [];
    has compile_errors: str = "";
    has warnings: list[str] = [];        # skill-quality warnings (assumed-Maybe) or clarify notes
    has clarify: list[ClarifyItem] = []; # the underspecified obligations (for --clarify / the report)
}

def pin_raise2_llms(m: any) -> None {
    pin_lift_llm(m);
    pin_direct_llm(m);
    pin_adjudge_llm(m);
}

glob _DIRECTIVE_CAP: int = 20;

def _directives(fr: FaithReport) -> str {
    # A leading instruction that closes the systemic gap in one stroke (every node
    # needs traces_to), THEN a capped list of specific rule gaps — a small model
    # cannot act on 50 simultaneous directives, but it can add provenance and fix
    # the top handful, and the loop re-runs on what remains.
    lines: list[str] = [
        "REALIZATION GAPS — close these, change NOTHING else:",
        "FIRST, systemically: give EVERY node/tool/knowledge a `traces_to` naming the"
        + " rule id(s) it realizes (all kinds — prohibitions, knowledge, gates, not just steps);"
        + " remove any node that realizes no rule.",
        "THEN realize each of these specific gaps in its required shape:"
    ];
    all_gaps: list = fr.dropped + fr.added;
    for g in all_gaps[:_DIRECTIVE_CAP] { lines.append("- " + str(g.message)); }
    if len(all_gaps) > _DIRECTIVE_CAP {
        lines.append("- ... and " + str(len(all_gaps) - _DIRECTIVE_CAP)
                     + " more of the same shapes — apply the systemic fix above to all of them.");
    }
    return "\n".join(lines);
}

def raise2(skill: str, name: str, max_repair: int = 2, skill_dir: str = "", ask: any = None,
           pre: any = None, adjudicate: bool = True, phase2: str = "") -> RaiseResult {
    # Full entry: extract the grounded spec, resolve any underspecified modality,
    # then raise. By the time we get here the spec loop's deterministic pass has
    # already settled every obligation whose heading or list intro stated a force,
    # so `sr.clarify` holds only what the document left genuinely open. The policy
    # for THAT residue, in descending order of authority:
    #   ask given (--clarify)  -> HIL: ask the human, bind Do/Maybe/Don't per answer.
    #                             The author's own word; nothing outranks it.
    #   adjudicate (DEFAULT)   -> answer each one from the skill's own text, with
    #                             every answer required to cite a verbatim span;
    #                             ungrounded answers are dropped to the line below.
    #   adjudicate=False       -> (--no-adjudicate) assume MAYBE + WARN for all.
    #                             No model in the loop: the reproducible choice.
    # Every tier WARNS about what it decided, so --strict fails on an
    # underspecified skill no matter which one ran.
    skill = strip_frontmatter(skill);
    # `pre`: a SpecResult the lint pre-pass already extracted from this same
    # (stripped) text — reuse it instead of paying for the spec loop twice.
    # Only valid when the source was NOT amended after extraction.
    _t0 = time.time();
    _emit({"stage": "spec", "state": "start"});
    sr = pre if pre else extract_spec(skill, name);
    _emit({"stage": "spec", "state": "done", "secs": time.time() - _t0,
           "rules": len(sr.spec.rules), "rounds": sr.verdict.rounds,
           "sound": sr.verdict.sound, "complete": sr.verdict.complete,
           "drift": sr.verdict.drift});
    warnings: list[str] = [];
    if sr.clarify {
        if ask {
            answers: dict[str, str] = {};
            for c in sr.clarify {
                resp = "";
                try { resp = str(ask(c.question)); } except Exception { resp = ""; }
                if resp.strip() { answers[c.rule_id] = resp.strip(); }
            }
            for n in apply_clarifications(sr.spec, answers) { warnings.append("clarified: " + n); }
        } elif adjudicate {
            warnings = adjudicate_spec(skill, sr);
        } else {
            warnings = resolve_ambiguous_default(sr.spec, sr.clarify);
        }
    }
    rr = raise_from_spec(skill, name, sr.spec, max_repair, phase2);
    rr.warnings = warnings;
    rr.clarify = sr.clarify;
    return rr;
}

def _j_names(xs: list[str]) -> str {
    return ", ".join([str(x) for x in xs]);
}

def _constraint_drop_ids(fr: FaithReport) -> list[str] {
    out: list[str] = [];
    for f in fr.dropped {
        if str(f.shape) == "CONSTRAINT" { out.append(str(f.rule)); }
    }
    return out;
}

def raise_from_spec(skill: str, name: str, spec: RuleSet, max_repair: int = 2,
                    phase2: str = "") -> RaiseResult {
    _t = time.time();
    _emit({"stage": "author", "state": "start"});
    au = author_direct(skill, spec, name);
    ir: str = str(au["ir_text"]).strip();
    _emit({"stage": "author", "state": "done", "secs": time.time() - _t,
           "lines": len(ir.splitlines()) if ir else 0});
    repairs: list[str] = [str(x) for x in list(au["notes"])];
    if not ir {
        repairs.append("author produced no IR");
        return RaiseResult(status="failed", repairs=repairs);
    }

    _t = time.time();
    _emit({"stage": "faith", "state": "start"});
    fr = faithfulness_report(spec, ir);
    _emit({"stage": "faith", "state": "done", "secs": time.time() - _t,
           "dropped": len(fr.dropped), "added": len(fr.added)});
    rounds = 0;

    # Mechanical rung FIRST (autofixes land before model repair): fold any
    # untraced prohibition into the model nodes it governs, adopt on
    # improvement. What remains goes to the model ladder.
    ids = _constraint_drop_ids(fr);
    if ids {
        irf: str = str(fold_untraced_prohibitions(ir, spec, ids));
        if irf {
            frf = faithfulness_report(spec, irf);
            if gap_score(frf) < gap_score(fr) {
                ir = irf; fr = frf;
                repairs.append("autofix: folded " + str(len(ids))
                               + " untraced prohibition(s) into model-node docs");
            }
        }
    }
    # rule-scoped repair: the SAME coherent author closes exactly the gaps.
    while (not fr.ok) and (rounds < max_repair) {
        rounds += 1;
        before = gap_score(fr);
        _t = time.time();
        _emit({"stage": "repair", "state": "start", "round": rounds,
               "issues": before, "target": "faithfulness"});
        au2 = author_direct(skill, spec, name, _directives(fr));
        ir2: str = str(au2["ir_text"]).strip();
        if not ir2 {
            repairs.append("repair round " + str(rounds) + ": author returned empty — keeping prior");
            _emit({"stage": "repair", "state": "done", "secs": time.time() - _t,
                   "round": rounds, "before": before, "after": before, "adopted": False});
            break;
        }
        fr2 = faithfulness_report(spec, ir2);
        after = gap_score(fr2);
        _emit({"stage": "repair", "state": "done", "secs": time.time() - _t,
               "round": rounds, "before": before, "after": after, "adopted": after < before});
        # monotone: adopt only if it closes gaps without opening new ones.
        if after < before {
            ir = ir2; fr = fr2;
            repairs.append("repair round " + str(rounds) + ": " + str(before) + " -> " + str(after) + " faithfulness gap(s)");
        } else {
            repairs.append("repair round " + str(rounds) + ": no improvement (" + str(before) + " -> " + str(after) + ") — keeping prior");
            break;
        }
    }

    # The model ladder can itself stall on a fresh untraced prohibition (an
    # adopted round that closed other gaps but opened this one) — one more
    # mechanical pass before the verdict.
    ids2 = _constraint_drop_ids(fr);
    if ids2 {
        irf2: str = str(fold_untraced_prohibitions(ir, spec, ids2));
        if irf2 {
            frf2 = faithfulness_report(spec, irf2);
            if gap_score(frf2) < gap_score(fr) {
                ir = irf2; fr = frf2;
                repairs.append("autofix: folded " + str(len(ids2))
                               + " untraced prohibition(s) into model-node docs");
            }
        }
    }

    # PHASE 2 — refinement passes over the whole IR. Each is adopted only if it
    # still lowers and does not regress faithfulness, so the phase is pure upside
    # per pass; the revert below makes the PHASE as a whole equally safe.
    ir_pre_phase2: str = ir;
    ph = run_passes(ir, spec, name, phase2);
    ir = str(ph.ir_text);
    for n in ph.notes { repairs.append(str(n)); }
    if ph.adopted { fr = faithfulness_report(spec, ir); }

    # Coherence gate LAST — faithfulness first, compilability second (the inverse of
    # today's _finalize, which compiles before it checks coverage).
    _t = time.time();
    _emit({"stage": "gates", "state": "start"});
    v = compile_gate(ir, name);
    if (not v.ok) and ph.adopted {
        # Per-pass acceptance uses the cheap structural lowering; the real
        # `jac check` runs only here. If the full gate rejects what the phase
        # produced, fall back to the pre-phase IR rather than let a refinement
        # cost us a runnable module — phase 2 must never be why a compile fails.
        v_pre = compile_gate(ir_pre_phase2, name);
        if v_pre.ok {
            repairs.append("phase2: reverted " + _j_names(ph.adopted)
                           + " — the full compile gate rejected the refined IR");
            ir = ir_pre_phase2;
            fr = faithfulness_report(spec, ir);
            v = v_pre;
        }
    }
    _emit({"stage": "gates", "state": "done", "secs": time.time() - _t,
           "g4": v.ok, "g1_issues": 0, "repairs": 0});
    if not fr.ok { status = "unfaithful"; }
    elif not v.ok { status = "uncompilable"; }
    else { status = "faithful"; }
    return RaiseResult(
        ok=(fr.ok and v.ok), status=status, ir_text=ir, module_src=v.module_src,
        proof=fr, rounds=rounds, repairs=repairs, compile_errors=v.errors
    );
}

def explain2(rr: RaiseResult) -> str {
    compiles = bool(rr.module_src) and ("def run(" in rr.module_src);
    lines: list[str] = ["raise2: " + rr.status.upper() + ("  · compiles" if compiles else "  · does NOT compile")];
    for l in proof_lines(rr.proof) { lines.append(l); }
    if rr.repairs {
        lines.append("repair ladder:");
        for r in rr.repairs { lines.append("  ~ " + str(r)); }
    }
    if (not rr.ok) and rr.compile_errors {
        lines.append("compile errors:");
        for e in str(rr.compile_errors).splitlines()[:8] { lines.append("  " + e); }
    }
    return "\n".join(lines);
}
