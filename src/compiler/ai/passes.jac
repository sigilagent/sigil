"""raise2 phase 2 — refinement passes over the whole authored IR.

`author_direct` authors the AG-IR in ONE frontier call, and that is the right
shape: the IR is a mutually referential graph (carries, edges, `traces_to`,
tool->node bindings), so cutting the *authoring* into per-view calls — what the
staged front-end did — maximizes coupling and produces seams a machine assembly
step then has to reconcile.

But one-call authoring emits TEXT, and text can be malformed. The staged pipeline
emitted DATA (`yaml.safe_dump`), so its output was well-formed by construction;
this is the one structural property the direct author gave up. A real shipped IR
in this repo carries `pdftotext_command:{ type: str, ... }` — a column-aligned key
that lost its space — and it only survived because `load_agir` relaxes.

Phase 2 recovers that property without re-staging the authoring. Each pass takes
the WHOLE IR and improves one dimension, the way a compiler pass sees the whole
program rather than a shard of it. The discipline is the one the autofix rung
already used, made uniform:

    a pass is adopted only if it still lowers AND does not regress faithfulness

so a pass is pure upside or a no-op. It can never make a compile worse.

Gated end to end — see `phase2_selection`: `--no-phase2` / `SIGIL_PHASE2=0`
restores the exact pre-phase-2 behavior, and `SIGIL_PASSES=<names>` runs a chosen
subset, so an implementation can be switched or bisected without a rebuild.
"""

import os;
import time;
import from src.compiler.mechanical.compiler { _load_ir }
import from src.sigil_agir_yaml { dump_agir, strict_parses }
import from .spec_loop { RuleSet }
import from .faith { FaithReport, faithfulness_report, gap_score, fold_untraced_prohibitions }
import from .gates { compile_gate }
import from .lift { _emit }

obj PassResult {
    has pass_name: str = "";
    has ir_text: str = "";
    has changed: bool = False;
    has notes: list[str] = [];
}

obj PhaseResult {
    has ir_text: str = "";
    has notes: list[str] = [];
    has adopted: list[str] = [];   # passes whose output was taken
    has declined: list[str] = [];  # passes that produced a candidate the guard rejected
}

# The registry IS the order — a pass may only depend on passes before it.
# PASS_NAMES is everything available; DEFAULT_PASSES is what runs unasked.
#
# `fold_prohibitions` is available but NOT default: raise2 still calls
# fold_untraced_prohibitions directly, once BEFORE the repair loop and once
# after, and the first of those positions is load-bearing — landing the
# mechanical fix before model repair is what stops a repair round being spent on
# a gap code can close for free. Migrating the whole ladder into this registry
# means re-deciding that ordering, which is its own change with its own
# evidence. Registered here so it can be exercised via SIGIL_PASSES, and so the
# registry demonstrably holds a real rung and not only new code.
glob PASS_NAMES: list[str] = ["canonicalize", "fold_prohibitions"];
glob DEFAULT_PASSES: list[str] = ["canonicalize"];

# ---------------------------------------------------------------------------
# Gating — one place decides which implementation runs.
#
#   phase2 arg  ""        -> read the environment (the default path)
#               "off"     -> no passes at all; byte-identical to pre-phase-2
#               "all"     -> every registered pass, including non-default ones
#               "a,b"     -> exactly these passes, in registry order
#   SIGIL_PHASE2=0|false  -> off
#   SIGIL_PASSES=a,b      -> subset, or "all" (ignored when phase 2 is off)
#
# The explicit argument always outranks the environment, so `--no-phase2` beats
# an exported SIGIL_PHASE2=1 rather than racing it.
# ---------------------------------------------------------------------------
def phase2_selection(phase2: str = "") -> list[str] {
    sel = str(phase2 or "").strip();
    if sel in ["off", "0", "false", "none"] { return []; }
    if not sel {
        if str(os.environ.get("SIGIL_PHASE2", "")).strip() in ["0", "false", "off", "no"] { return []; }
        sel = str(os.environ.get("SIGIL_PASSES", "")).strip();
    }
    if sel == "all" { return list(PASS_NAMES); }
    if (not sel) or (sel in ["1", "true", "on"]) { return list(DEFAULT_PASSES); }
    want = [str(x).strip() for x in sel.split(",") if str(x).strip()];
    # Registry order, not the caller's order — a pass may depend on an earlier one.
    return [p for p in PASS_NAMES if p in want];
}

# ---------------------------------------------------------------------------
# The passes.
# ---------------------------------------------------------------------------

def pass_canonicalize(ir_text: str, spec: RuleSet, name: str) -> PassResult {
    # Authored text -> canonical data. Fires ONLY when the document needed the
    # relaxer to parse, so on a well-formed IR this is a no-op and the blast
    # radius is exactly the defect class.
    r = PassResult(pass_name="canonicalize", ir_text=ir_text);
    if strict_parses(ir_text) { return r; }
    ir: any = {};
    try { ir = _load_ir(ir_text); } except Exception { return r; }
    if (not isinstance(ir, dict)) or (not ir.get("nodes")) { return r; }
    out = str(dump_agir(ir));
    # Re-emitting must actually FIX it. If the canonical form still needs the
    # relaxer, the document was broken in a way this pass does not understand —
    # keep the original rather than trade one malformation for another.
    if (not out.strip()) or (not strict_parses(out)) { return r; }
    # The pass's OWN correctness criterion, checked at runtime rather than only
    # in tests: re-emitting may change the document's form and must not change
    # what it lowers to. The relaxer already understood this text, so an
    # identical module is the proof that the canonical reading IS the reading
    # the compiler was going to use anyway. If they differ, the round-trip
    # reinterpreted something — decline, and leave the original text for a human
    # to look at rather than persist a changed meaning.
    a = compile_gate(ir_text, name + "__canon_a", False);
    b = compile_gate(out, name + "__canon_b", False);
    if (not a.ok) or (not b.ok) or (a.module_src != b.module_src) {
        r.notes = ["canonicalize: declined — re-emitting this document would change what it lowers to"];
        return r;
    }
    r.ir_text = out;
    r.changed = True;
    r.notes = ["canonicalize: authored YAML parsed only via the relaxer — re-emitted as strict YAML"];
    return r;
}

def pass_fold_prohibitions(ir_text: str, spec: RuleSet, name: str) -> PassResult {
    # The mechanical rung raise2 used to hand-roll twice: a prohibition with no
    # node of its own is folded into the docs of the model nodes it governs.
    r = PassResult(pass_name="fold_prohibitions", ir_text=ir_text);
    fr = faithfulness_report(spec, ir_text);
    ids: list[str] = [];
    for f in fr.dropped {
        if str(f.shape) == "CONSTRAINT" { ids.append(str(f.rule)); }
    }
    if not ids { return r; }
    out = str(fold_untraced_prohibitions(ir_text, spec, ids));
    if not out.strip() { return r; }
    r.ir_text = out;
    r.changed = True;
    r.notes = ["fold_prohibitions: folded " + str(len(ids))
               + " untraced prohibition(s) into the model nodes they govern"];
    return r;
}

def _run_one(pass_name: str, ir_text: str, spec: RuleSet, name: str) -> PassResult {
    # Explicit dispatch rather than a table of function refs: the registry stays
    # a plain list of names the gate can validate, and `jac check` keeps types.
    if pass_name == "canonicalize" { return pass_canonicalize(ir_text, spec, name); }
    if pass_name == "fold_prohibitions" { return pass_fold_prohibitions(ir_text, spec, name); }
    return PassResult(pass_name=pass_name, ir_text=ir_text);
}

# ---------------------------------------------------------------------------
# The adoption guard — the reason a pass can never make a compile worse.
# ---------------------------------------------------------------------------
def _accepts(cand: str, spec: RuleSet, name: str, before_score: int) -> bool {
    if not str(cand or "").strip() { return False; }
    # Structural lowering only (check=False): the transpile + run()/node liveness
    # checks catch a pass that broke the IR, without paying a full `jac check`
    # subprocess per pass. raise_from_spec still runs the real G4 after the phase,
    # and reverts the whole phase if that fails.
    v = compile_gate(cand, name, False);
    if not v.ok { return False; }
    return gap_score(faithfulness_report(spec, cand)) <= before_score;
}

def run_passes(ir_text: str, spec: RuleSet, name: str, phase2: str = "") -> PhaseResult {
    out = PhaseResult(ir_text=ir_text);
    names = phase2_selection(phase2);
    if not names { return out; }
    _t = time.time();
    _emit({"stage": "passes", "state": "start"});
    cur = str(ir_text);
    for pn in names {
        cand = PassResult(pass_name=pn, ir_text=cur);
        try { cand = _run_one(pn, cur, spec, name); }
        except Exception as e {
            out.notes.append(str(pn) + ": pass raised, skipped — " + str(e)[:160]);
            continue;
        }
        if (not cand.changed) or (str(cand.ir_text).strip() == cur.strip()) { continue; }
        before_score = gap_score(faithfulness_report(spec, cur));
        if _accepts(str(cand.ir_text), spec, name, before_score) {
            cur = str(cand.ir_text);
            out.adopted.append(str(pn));
            for n in cand.notes { out.notes.append(str(n)); }
        } else {
            out.declined.append(str(pn));
            out.notes.append(str(pn) + ": candidate declined — it did not lower cleanly"
                             + " or it regressed faithfulness; kept the prior IR");
        }
    }
    out.ir_text = cur;
    _emit({"stage": "passes", "state": "done", "secs": time.time() - _t,
           "ran": len(names), "adopted": len(out.adopted), "declined": len(out.declined)});
    return out;
}
