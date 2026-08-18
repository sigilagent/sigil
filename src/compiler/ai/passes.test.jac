"""Tests — phase 2, the whole-IR refinement passes.

Two properties are worth pinning here, because both are what makes the phase safe
to leave on by default:

  · the GATE: a pass's candidate is taken only when it still lowers and does not
    regress faithfulness, so a bad pass is a no-op rather than a broken compile;
  · the SWITCH: `off` restores the pre-phase-2 pipeline exactly, and a named
    subset runs exactly that subset.
"""

import os;
import from .spec_loop { Rule }
import from .lift_types { RuleKind, Modality }

# The real defect this phase exists for: a column-aligned carry whose key ran
# long enough to swallow the space after its colon. Not strict YAML; the relaxer
# reads it anyway, so nothing downstream ever noticed.
glob MALFORMED_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:       { type: str, role: input }
    drafted_note:{ type: str, produced_by: draft }
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [drafted_note]
    doc: "Write the note the task asks for."
    traces_to: [r1]
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

glob CLEAN_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:
      type: str
      role: input
    drafted_note:
      type: str
      produced_by: draft
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [drafted_note]
    doc: "Write the note the task asks for."
    traces_to: [r1]
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

def _spec() -> RuleSet {
    return RuleSet(skill_name="note_writer", rules=[
        Rule(id="r1", quote="Write the note the task asks for.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY,
             statement="Write the note the task asks for.")
    ]);
}

# ---------------------------------------------------------------------------
# the switch
# ---------------------------------------------------------------------------

test "by default the phase runs its default passes" {
    prev = os.environ.get("SIGIL_PHASE2", "");
    prev2 = os.environ.get("SIGIL_PASSES", "");
    os.environ["SIGIL_PHASE2"] = ""; os.environ["SIGIL_PASSES"] = "";
    assert phase2_selection() == ["canonicalize"];
    os.environ["SIGIL_PHASE2"] = prev; os.environ["SIGIL_PASSES"] = prev2;
}

test "--no-phase2 selects nothing, and outranks the environment" {
    prev = os.environ.get("SIGIL_PHASE2", "");
    os.environ["SIGIL_PHASE2"] = "1";
    assert phase2_selection("off") == [];
    os.environ["SIGIL_PHASE2"] = prev;
}

test "SIGIL_PHASE2=0 turns the phase off" {
    prev = os.environ.get("SIGIL_PHASE2", "");
    os.environ["SIGIL_PHASE2"] = "0";
    assert phase2_selection() == [];
    os.environ["SIGIL_PHASE2"] = prev;
}

test "a named subset runs exactly that subset" {
    assert phase2_selection("fold_prohibitions") == ["fold_prohibitions"];
    assert phase2_selection("canonicalize") == ["canonicalize"];
}

test "'all' includes the registered non-default passes" {
    sel = phase2_selection("all");
    assert "canonicalize" in sel;
    assert "fold_prohibitions" in sel;
}

test "selection is registry order, not the order the caller asked in" {
    assert phase2_selection("fold_prohibitions,canonicalize") == PASS_NAMES;
}

test "an unknown pass name is ignored rather than crashing the compile" {
    assert phase2_selection("no_such_pass") == [];
    assert phase2_selection("no_such_pass,canonicalize") == ["canonicalize"];
}

# ---------------------------------------------------------------------------
# canonicalize
# ---------------------------------------------------------------------------

test "canonicalize is a no-op on an IR that is already strict YAML" {
    r = pass_canonicalize(CLEAN_IR, _spec(), "note_writer_c1");
    assert not r.changed;
    assert r.ir_text == CLEAN_IR;
}

test "canonicalize rewrites an IR that only parsed via the relaxer" {
    assert not strict_parses(MALFORMED_IR);
    r = pass_canonicalize(MALFORMED_IR, _spec(), "note_writer_c2");
    assert r.changed;
    assert strict_parses(r.ir_text);
    assert "canonicalize" in r.notes[0];
}

test "canonicalize preserves the carry the malformed line encoded" {
    r = pass_canonicalize(MALFORMED_IR, _spec(), "note_writer_c3");
    carries = _load_ir(r.ir_text).get("walker").get("carries");
    assert "drafted_note" in carries;
    assert carries["drafted_note"]["produced_by"] == "draft";
}

# ---------------------------------------------------------------------------
# the phase, end to end
# ---------------------------------------------------------------------------

test "the phase adopts a canonicalization and reports it" {
    ph = run_passes(MALFORMED_IR, _spec(), "note_writer_p1", "canonicalize");
    assert ph.adopted == ["canonicalize"];
    assert ph.declined == [];
    assert strict_parses(ph.ir_text);
}

test "the phase off returns the IR untouched, byte for byte" {
    ph = run_passes(MALFORMED_IR, _spec(), "note_writer_p2", "off");
    assert ph.ir_text == MALFORMED_IR;
    assert ph.adopted == [];
    assert ph.notes == [];
}

test "a pass with nothing to do leaves no trace in the report" {
    ph = run_passes(CLEAN_IR, _spec(), "note_writer_p3", "canonicalize");
    assert ph.ir_text == CLEAN_IR;
    assert ph.adopted == [];
    assert ph.declined == [];
}

test "an unlowerable IR cannot be made worse — the phase declines or no-ops" {
    ph = run_passes("::: not yaml {{{", _spec(), "note_writer_p4", "all");
    assert ph.ir_text == "::: not yaml {{{";
    assert ph.adopted == [];
}
