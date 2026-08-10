"""raise2 — the rearchitected front-end (Layer 1 authoring + Layer 2 verify + Layer 4 control).

The pipeline, faithfulness-first:

    spec loop  →  author (coherent, one pass)  →  FAITHFULNESS closure
                        ▲                                │
                        └──── rule-scoped repair ◀───────┘  (same author, close exactly the gaps)
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
"""

import from .spec_loop { extract_spec, pin_lift_llm, strip_frontmatter, RuleSet, ClarifyItem, apply_clarifications, resolve_ambiguous_default }
import from .author_direct { author_direct, pin_direct_llm }
import from .faith { faithfulness_report, FaithReport, proof_lines, fold_untraced_prohibitions }
import from .gates { compile_gate }

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

def raise2(skill: str, name: str, max_repair: int = 2, skill_dir: str = "", ask: any = None, pre: any = None) -> RaiseResult {
    # Full entry: extract the grounded spec, resolve any underspecified modality,
    # then raise. The ambiguity policy:
    #   ask given (--clarify)  -> HIL: ask the human, bind Do/Maybe/Don't per answer.
    #   ask None (default)     -> assume MAYBE (optional) + WARN, so a runnable,
    #                             faithful-to-what-was-stated agent is produced and
    #                             the author is told exactly what to re-run with
    #                             --clarify if an assumption is wrong.
    skill = strip_frontmatter(skill);
    # `pre`: a SpecResult the lint pre-pass already extracted from this same
    # (stripped) text — reuse it instead of paying for the spec loop twice.
    # Only valid when the source was NOT amended after extraction.
    sr = pre if pre else extract_spec(skill, name);
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
        } else {
            warnings = resolve_ambiguous_default(sr.spec, sr.clarify);
        }
    }
    rr = raise_from_spec(skill, name, sr.spec, max_repair);
    rr.warnings = warnings;
    rr.clarify = sr.clarify;
    return rr;
}

def _constraint_drop_ids(fr: FaithReport) -> list[str] {
    out: list[str] = [];
    for f in fr.dropped {
        if str(f.shape) == "CONSTRAINT" { out.append(str(f.rule)); }
    }
    return out;
}

def raise_from_spec(skill: str, name: str, spec: RuleSet, max_repair: int = 2) -> RaiseResult {
    au = author_direct(skill, spec, name);
    ir: str = str(au["ir_text"]).strip();
    repairs: list[str] = [str(x) for x in list(au["notes"])];
    if not ir {
        repairs.append("author produced no IR");
        return RaiseResult(status="failed", repairs=repairs);
    }

    fr = faithfulness_report(spec, ir);
    rounds = 0;

    # Mechanical rung FIRST (autofixes land before model repair): fold any
    # untraced prohibition into the model nodes it governs, adopt on
    # improvement. What remains goes to the model ladder.
    ids = _constraint_drop_ids(fr);
    if ids {
        irf: str = str(fold_untraced_prohibitions(ir, spec, ids));
        if irf {
            frf = faithfulness_report(spec, irf);
            if (len(frf.dropped) + len(frf.added)) < (len(fr.dropped) + len(fr.added)) {
                ir = irf; fr = frf;
                repairs.append("autofix: folded " + str(len(ids))
                               + " untraced prohibition(s) into model-node docs");
            }
        }
    }
    # rule-scoped repair: the SAME coherent author closes exactly the gaps.
    while (not fr.ok) and (rounds < max_repair) {
        rounds += 1;
        au2 = author_direct(skill, spec, name, _directives(fr));
        ir2: str = str(au2["ir_text"]).strip();
        if not ir2 {
            repairs.append("repair round " + str(rounds) + ": author returned empty — keeping prior");
            break;
        }
        fr2 = faithfulness_report(spec, ir2);
        before = len(fr.dropped) + len(fr.added);
        after = len(fr2.dropped) + len(fr2.added);
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
            if (len(frf2.dropped) + len(frf2.added)) < (len(fr.dropped) + len(fr.added)) {
                ir = irf2; fr = frf2;
                repairs.append("autofix: folded " + str(len(ids2))
                               + " untraced prohibition(s) into model-node docs");
            }
        }
    }

    # Coherence gate LAST — faithfulness first, compilability second (the inverse of
    # today's _finalize, which compiles before it checks coverage).
    v = compile_gate(ir, name);
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
