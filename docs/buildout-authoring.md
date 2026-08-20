# Skeleton-first build-out authoring

Status: design + implementation in progress on `buildout-authoring`.
Motivation comes from measured v0.5.1 behavior on a 33-skill benchmark.

## The two faults being fixed

v0.5.1 authors an AG-IR in **one LLM pass over the whole rule set**
(`author_direct.jac::author_direct` → `author_agir_direct`, and the agent
front-end in `author_agent.jac`). The repair loop re-emits the *entire* IR each
round with gap directives appended. Two failure modes follow from that, and both
are visible in the bench data:

### Fault 1 — capacity ceiling → refusal (big skills)

The faithfulness gate refuses to eject when MANDATORY rules have no realization.
Drops scale with skill size:

| skill | mandatory rules | dropped |
|---|---|---|
| gh-issues | ~39 | 35 STEP, 6 IO, 2 KNOWLEDGE, … (46 total) |
| claude-api | ~27 | 24 STEP, 15 GROUNDING, 1 HIL (40 total) |
| subagent-driven-development | ~25 | 9 |
| test-driven-development | ~18 | 7 |

8 of 33 skills refused to eject. Retrying flips them nondeterministically
(7 skills converted on a second/third attempt) — the signature of a
context/attention ceiling, not a systematic lowering bug.

### Fault 2 — trace inflation → hollow "faithful" agents (medium skills)

Where authoring *does* fit, it satisfies coverage the cheap way: a few generic
nodes/tools carrying fat `traces_to` lists. The gate checks that every rule has
a shape-correct realization; it does **not** check that the realization does
what the rule says, nor that one claimer isn't absorbing dozens of unrelated
mandates.

Measured structure (`ir_stats.py` — max rules claimed by one node/tool, and that
claimer's share of all claims):

| skill | version | nodes | max claim | inflation |
|---|---|---|---|---|
| docx | v0.3.5 | 98 | 2 | **0.02** |
| docx | v0.5.1 | 14 | 50 | **0.62** |
| soc2 | v0.5.1 | 76 (37 ACT + 36 GEN-RAW) | 37 (`append_file`) | — |
| algorithmic-art | v0.5.1 | 10 | 91 | 0.61 |

Consequences at runtime, measured two independent ways:

* **Bundle-artifact embodiment** (`embodiment_check.py`, model-free: does the
  ejected program reference the scripts/references the SKILL.md names?)
  — v0.3.5 **69%** (41/59) vs v0.5.1 **36%** (17/46).
  soc2 goes 64% → **0%**: the v0.3.5 agent ran
  `scripts/completeness_checker.py` and `scripts/control_coverage_validator.py`
  via real subprocess calls; the v0.5.1 agent mentions neither, anywhere.
* **AMC** — soc2 AMC2 100 → 70, iso27001 80 → 69, docx strict 33 → 13,
  internal-comms 100 → 33 (never loads its `examples/` guideline).

## Design

### Phase 0 — mechanical skeleton (no LLM, or one tiny call for ordering)

Emit exactly one stub per MANDATORY rule, keyed by rule kind. The gate's own
DROP messages already specify the required shape, so this is a direct inversion
of the completeness check:

| rule kind | stub |
|---|---|
| STEP | NODE with `traces_to: [rN]` |
| IO | ACT (write surface) bound to the named deliverable |
| GROUNDING | live-source tool/SENSE bound to the named source |
| KNOWLEDGE | knowledge item, content copied **verbatim** from the rule's skill evidence |
| HIL | ask/confirm node |

Completeness then holds **by construction** — Fault 1 cannot occur, regardless
of skill size. The only global decision left is spine ordering, taken once over
rule summaries (small context).

**Binding is specific, not generic**: when a rule's text names a concrete
artifact (`scripts/completeness_checker.py`, `references/common_saas_controls.md`),
the stub is bound to *that* artifact mechanically — the name is right there in
the rule text. This is what makes embodiment provable rather than hoped-for.

### Phases 1..n — region-scoped build-out (bounded context)

Chunk the spine into regions (skill sections / phases). Each round sees:
frozen skeleton + current IR + **only that region's rules**, and returns edits
that fill its own region. Context per call is bounded by region size, not skill
size, so the size cliff disappears. Each round inherits the previous round's IR
— build-out, never re-derivation.

### Gates (mechanical, no LLM)

1. **G-MONO — no-deletion.** After each round, every (rule → realization) edge
   that existed before must still exist. A round that deletes coverage is
   rejected and re-run. Coverage is monotonic by enforcement.
2. **G-INFL — anti-inflation.** A single node/tool may not claim more than
   `k` mandates unless they are siblings under one spine step (tunable; the
   v0.3.5 healthy baseline is max-claim ≤ 2–4, the v0.5.1 pathology is 37–91).
3. **G-EMBODY — artifact binding.** If a rule names a bundle artifact, its
   realization must actually touch that artifact (run the script / read the
   file). Same provenance machinery as the existing IO checks; closes the exact
   hole that certified soc2 as faithful while it ran nothing.

## Evaluation plan

Falsification test on the two failure classes, comparing baseline v0.5.1 vs
`--buildout` on the same skills, same model tiers:

* refusal class: `gh-issues`, `claude-api` (expect: eject, coverage complete)
* hollow class: `soc2-system-description`, `docx`, `internal-comms`
  (expect: embodiment ↑ toward v0.3.5 levels, inflation ↓, AMC-strict/AMC2 ↑)

Metrics: eject rate, gate drops, `ir_stats.py` inflation, `embodiment_check.py`
percentage, then AMC1-strict + AMC2 on the bench.

Cost expectation: more calls, each much smaller; repair rounds stop re-emitting
200-rule IRs. The skeleton-first mcp-builder experiment was 1.38× *cheaper* at
parity, so this is not assumed to be a cost regression — it is measured.

## Measured so far

### Unit level

`jac test src/compiler/ai/` — **1880 passed**, 18 of them new. The load-bearing
ones assert the claim rather than the code:

* a skeleton built from a rule set covering every `RuleKind` reports **zero
  DROPPED and zero ADDED** through the real faithfulness closure — completeness
  without a model call;
* a round that quietly deletes the deliverable is **rejected**, and the prior
  document survives with coverage intact;
* G11 flags a graph that never touches the scripts its rules name, and passes a
  skeleton; G10 flags one element claiming many procedures, and does not punish
  folded prohibitions.

### First live compile — `hipaa-compliance`

```
buildout hipaa-compliance rc=0 secs=1053 [status: faithful]
  skeleton: 30 required rules stubbed of 48 extracted, 30 realized at phase 0
  region 1/3: filled 12 rule(s), 30 realized
  region 2: REJECTED — dropped 1 realization(s) (r31)
  region 3/3: filled 6 rule(s), 30 realized
  buildout: 1 stub(s) still unfilled
```

Completeness held from phase 0, before any model call. The monotonicity guard
fired on the first live compile, unprompted: a region round tried to remove a
realization and was discarded. The cost of that rejection is visible and honest
— one stub stayed unfilled and the notes say so, instead of shipping a graph
that claims coverage it does not have.

Structure follows the design: 14 nodes / 8 SENSE (reading the reference files
the rules name) against the single-pass author's 8 nodes / 4 CODE, with stubs
named after the rule they realize (`r16_load_references_security_rule`).

### Compliance — AMC2, 9 cells per arm

AMC2 is the branch-aware metric: N/A survives only for a verifiably untaken
branch, and absence of evidence is MISSED. (`hipaa`'s reference encodes no
conditional edges, so every N/A is correctly coerced.)

| arm | AMC2 |
|---|---|
| single-pass (v0.5.1) | 60 |
| **build-out** | **80** |

The judge also had far less to guess about: 6 N/A stamps across the build-out
cells against 16 for the single-pass agent, which is what embodiment buys — when
the agent actually performs the procedure, the trace shows it.

### Not yet measured

`soc2-system-description` and `docx` — the two skills where the single-pass
author went hollow (soc2 bundle-artifact embodiment 64% -> 0%, docx 2/15
mandates followed in every rep) — are compiling under `--buildout` now. They are
the cases this design exists for, and the numbers above should not be read as
the result until those land. Likewise the refusal class (`gh-issues`,
`claude-api`), where the prediction is that completeness-by-construction removes
the refusal entirely.
