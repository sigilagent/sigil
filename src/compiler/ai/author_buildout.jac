"""Skeleton-first build-out authoring — Phases 1..n.

Same contract as `author_direct.author_direct` — `(skill, spec, name, gaps) ->
{"ir_text", "notes"}` — so it drops into `raise2.raise_from_spec` unchanged and
inherits the whole downstream ladder (faithfulness closure, autofix rungs, G4,
persist, eject).

What differs is where completeness comes from. `author_direct` asks one model
call to hold every rule at once and emit a complete IR; past a few dozen rules
it silently trades completeness for a smaller answer. Here Phase 0 emits a
mechanically complete skeleton (`skeleton.skeleton_ir`) and the model never has
to achieve coverage at all — it only FILLS, one bounded region at a time, and
each round inherits the previous round's document.

Two invariants make that safe, both mechanical:

  * MONOTONIC COVERAGE — a round may add realizations, never remove one. Any
    round whose result drops a rule the previous document realized is rejected
    and the prior document is kept. Coverage can only go up.
  * BOUNDED CONTEXT — a round sees the current IR plus only its own region's
    rules, so the prompt does not grow with skill size. This is the failure the
    single-pass author hits, and it is designed out rather than tuned around.
"""

import os;

import from jaclang.byllm.lib { Model }

import from .lift_types { Modality, RuleKind }
import from .spec_loop { Rule, RuleSet }
import from .faith { check_completeness, parse_ir, required_shape }
import from .skeleton { coverage, skeleton_ir }


glob buildout_llm: any = Model(model_name="gpt-4o-mini");
glob _BUILDOUT_PINNED: bool = False;


def pin_buildout_llm(m: any) -> None {
    # Tests and the compile driver pin the tier; a live default is a test hazard.
    buildout_llm = m;
    _BUILDOUT_PINNED = True;
}


sem fill_region = """You are filling in ONE REGION of an AG-IR that is ALREADY
STRUCTURALLY COMPLETE. Every obligation already has a correctly-shaped stub, and
stubs that still need content are marked `[TODO: ...]` inside their `doc`.

Your ONLY job is to fill the stubs for the rules listed in REGION RULES:
 - replace each `[TODO: ...]` marker in those stubs with real content — a slot
   prompt for a model node, a real body/command for a code tool, a real guard
   for a gate;
 - keep every `id`, every `traces_to`, every edge, every tool binding and every
   other region EXACTLY as given.

HARD RULES, enforced mechanically after you answer:
 - NEVER delete a node, tool, knowledge item, edge, or traces_to entry. A round
   that drops any realization is discarded entirely.
 - NEVER widen a `traces_to` list to cover rules that already have their own
   stub — one element per obligation is the point.
 - NEVER replace a bound script/file command with a generic one: if a tool runs
   `scripts/x.py`, it must still run `scripts/x.py`.
 - Leave `[TODO: ...]` markers belonging to OTHER regions untouched.

Output ONLY the complete raw AG-IR YAML (starting with the '---' frontmatter) —
no prose, no markdown fences.""";
sem fill_region.guide = "The AG-IR authoring guide — obey it for shape and idiom.";
sem fill_region.skill = "The SKILL.md being compiled, for the domain content.";
sem fill_region.ir_so_far = "The current AG-IR: complete in structure, partly filled.";
sem fill_region.region_rules = "The rules whose stubs you must fill in this round, verbatim.";
def fill_region(guide: str, skill: str, ir_so_far: str, region_rules: str) -> str by buildout_llm();


def _region_md(spec: RuleSet, ids: list[str]) -> str {
    lines: list[str] = ["# REGION RULES — fill the stubs for exactly these", ""];
    for r in spec.rules {
        if r.id not in ids { continue; }
        lines.append("- **" + r.id + "** · " + str(r.kind.name) + " · " + str(r.modality.name)
                     + (" · when: " + r.condition if r.condition else ""));
        lines.append("  > " + r.quote.replace("\n", " "));
        if r.statement { lines.append("  = " + r.statement.replace("\n", " ")); }
    }
    return "\n".join(lines);
}


def regions(spec: RuleSet, size: int = 0) -> list[list[str]] {
    # Ordered chunks of REQUIRED rule ids. Order follows the spec, which follows
    # the skill's own narrative, so a chunk is a contiguous stretch of procedure.
    n = size if size > 0 else int(os.environ.get("SIGIL_BUILDOUT_REGION", "12"));
    cov = coverage(spec);
    ids: list[str] = cov["required_ids"];
    out: list[list[str]] = [];
    i: int = 0;
    while i < len(ids) {
        out.append(ids[i:i + n]);
        i += n;
    }
    return out;
}


def realized_ids(spec: RuleSet, ir_text: str) -> list[str] {
    # The rules an IR actually realizes, by the gate's own reckoning.
    try { pir = parse_ir(ir_text); } except Exception { return []; }
    dropped = set([f.rule for f in check_completeness(spec, pir)]);
    out: list[str] = [];
    for r in spec.rules {
        if str(required_shape(r.kind, r.modality, r.binds).name) == "OPTIONAL" { continue; }
        if r.id not in dropped { out.append(r.id); }
    }
    return out;
}


def monotonic(spec: RuleSet, before: str, after: str) -> list[str] {
    # Rules the candidate LOST relative to the incumbent. Empty = safe to adopt.
    was = set(realized_ids(spec, before));
    now = set(realized_ids(spec, after));
    return sorted(list(was - now));
}


def _guide_text() -> str {
    import from .author_direct { _guide_text as _gt }
    return _gt();
}


def _strip_fence(s: str) -> str {
    t = str(s or "").strip();
    if t.startswith("```") {
        parts = t.split("\n");
        if len(parts) > 2 { t = "\n".join(parts[1:]); }
        if t.rstrip().endswith("```") { t = t.rstrip()[:-3]; }
    }
    return t.strip();
}


def author_buildout(skill: str, spec: RuleSet, name: str, gaps: str = "") -> dict {
    # Phase 0 (mechanical) + Phases 1..n (one bounded model call per region).
    notes: list[str] = [];
    ir: str = skeleton_ir(spec, name);
    cov = coverage(spec);
    notes.append("skeleton: " + str(cov["n_required"]) + " required rules stubbed of "
                 + str(cov["n_rules"]) + " extracted, "
                 + str(len(realized_ids(spec, ir))) + " realized at phase 0");

    guide = _guide_text();
    regs = regions(spec);
    if not regs {
        notes.append("buildout: no required rules — skeleton is the whole answer");
        return {"ir_text": ir, "notes": notes};
    }

    # `gaps` (the repair ladder's rule-scoped directives) becomes one extra
    # region appended to the end, so repair reuses the same fill path.
    round_no: int = 0;
    for ids in regs {
        round_no += 1;
        region_md = _region_md(spec, ids);
        if gaps.strip() { region_md = region_md + "\n\n" + gaps.strip(); }
        try {
            cand = _strip_fence(fill_region(guide, skill, ir, region_md));
        } except Exception as e {
            notes.append("region " + str(round_no) + "/" + str(len(regs)) + ": call failed ("
                         + str(e)[:120] + ") — keeping prior document");
            continue;
        }
        if not cand {
            notes.append("region " + str(round_no) + ": empty answer — keeping prior document");
            continue;
        }
        pir = parse_ir(cand);
        if not pir.nodes {
            notes.append("region " + str(round_no) + ": candidate did not parse — keeping prior document");
            continue;
        }
        lost = monotonic(spec, ir, cand);
        if lost {
            notes.append("region " + str(round_no) + ": REJECTED — dropped "
                         + str(len(lost)) + " realization(s) (" + ", ".join(lost[:4]) + ")");
            continue;
        }
        ir = cand;
        notes.append("region " + str(round_no) + "/" + str(len(regs)) + ": filled "
                     + str(len(ids)) + " rule(s), " + str(len(realized_ids(spec, ir))) + " realized");
    }
    left = ir.count("[TODO:");
    if left { notes.append("buildout: " + str(left) + " stub(s) still unfilled"); }
    return {"ir_text": ir, "notes": notes};
}
