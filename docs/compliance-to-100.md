# Compliance by construction: what it took to reach 100 CMC

Status: measured on the 11-skill compliance suite (soc2, data-privacy, hipaa,
iso27001, dora, analytical-method-validation, clinical-decision-support,
iso-standards-readiness, relsa, clinical-reports, treatment-plans) × 3 runtime
models (llama-3.1-8B, glm-5.2, gpt-4o), scored by CMC with a gpt-5 judge for the
deferred residual. Prose (SKILL.md + ReAct) scores 26 / 50 / 33 mean CMC on
llama / glm / gpt-4o; the compiled arm is at 100 on every cell that has passed
the acceptance audit (see the last section for the exact state).

This document records *which changes to the compiled agent moved cells to 100
and why*, so they can be ported into the compiler as passes rather than
re-discovered. The changes were made in the bench-side generator that emits
AG-IR from a skill's mandate reference (`gen_cc.py` + `flags.py` +
`scrub_gate_body.py`); every one of them is a structural property of the
emitted graph, not a prompt tweak, and every one is checkable at compile time.

## 0. The metric decides what "by construction" means

CMC classifies each mandate of a task's reference procedure:

| class | how it is decided | judge involved |
|---|---|---|
| `CERT_CODE` | an owner=code node cites the mandate and fired in the node trace | no |
| `CERT_MODEL` | a *one-to-one* typed by-llm slot cites the mandate and fired, in an order that respects the reference DAG | no |
| `DEFERRED` | anything else (shared prompt text, wrong order, unrealized site) → judged on the raw slot outputs | yes |

`cr` = certified / applicable. A prohibition is FOLLOWED by default and only
counts when the judge finds the forbidden content. Two consequences drive
everything below:

1. Only `DEFERRED` mandates can be lost to model quality. A cell is 100 *by
   construction* exactly when the deferred residual is empty or vacuous.
2. The judge sees **raw slot outputs**, not the final deliverable. A code node
   that scrubs the deliverable helps only if it makes the prohibition
   `CERT_CODE`; it does nothing for a judged mandate.

## 1. Topological slot order from the reference DAG (the largest single lever)

Slots were emitted in mandate-id order. The certifier's `order_ok` check
compares the firing order against the reference procedure's MUST edges, so a
disclaimer slot S1 emitted before the sections it must follow (S6/S7/S8) failed
`order_ok`, was demoted to `DEFERRED`, and the weak model's text was judged.
The fix is mechanical: topo-sort the positive slots over the **union of the
MUST edges of every task reference** for the skill (`gen_cc._topo_order`).

Why the union: per-task DAGs differ. soc2's t2/t3 references carry
`S21→S7` and `S22→S7` (use specific language / link evidence *before* drafting
the controls section); t1 does not. An order built from one task certified S7
on t3 and deferred it on t2 — which is exactly where llama's un-grounded
Section 5 was judged VIOLATED (llama soc2 93.3 → 100 after the fix).
Applicability selects the fired subset of a branchy DAG; the topological
constraint holds on the whole DAG, so 100 is a property of the graph, not of a
linear chain. The scorer-side `order_ok` rescue uses the same MUST-only rule,
so generator and certifier agree by definition.

## 2. One typed slot per positive mandate, citing the mandate

`CERT_MODEL` needs `one_to_one`, `closed`, `input_parity`, `output_parity`.
A slot that "authors the deliverable" for five mandates certifies none of them.
Each positive mandate gets its own `by llm` slot whose docstring cites the
mandate id and whose typed output is exactly that section; a transcription
guard keeps carried sections from being re-authored downstream. The certifier
is re-sampled per task and is noisy on identical structure (it flipped
`one_to_one` on all dora slots once) — the mandate-cited docstrings are what
made the mapping stable across samples.

## 3. Grounding: the agent's own bundle, nothing else

`load_refs` is an owner=code node that reads `references/*.md` next to
`agent.jac` and carries the text into every slot. Two bugs here produced *false
100s*, which is worse than a low score:

- the original node walked up from the bench cwd (`~/.sigil/app`), whose
  `references/` is the HIPAA skill's bundle — every skill was grounded on HIPAA
  breach-notification text;
- the rewritten node kept a cwd fallback, and a runner that copied the agent
  dir before its parent existed (`cp -r src "$AH" || mkdir -p "$AH"` fails for
  the first skill of a fresh tag) produced an agent without `references/` that
  silently fell through to the same HIPAA bundle again.

Now: `dirname(__file__)` or the loaded agent module only; if neither has
`references/`, the node returns `no references found at run time.` — a visible
failure, never a foreign grounding. Runners assert `references/*.md` exists and
print, per cell, how many slot prompts carry the bundle's own file headers and
how many carry the HIPAA marker. Output-based leak checks are insufficient: the
fin gpt-4o/llama runs never echoed the foreign refs; only a **prompt-level**
phrase audit (`45 CFR` count == `Breach Notification` count == number of calls)
exposed the seven contaminated cells.

## 4. Prohibitions as mechanical scrub-gates (`CERT_CODE`)

A prohibition whose forbidden content has a lexical signature is enforced by an
owner=code node `enforce_mechanical_prohibitions` between `assemble_doc` and
`save_out`. `flags.compute(prohibitions)` matches each prohibition's text
against a rule table so a pass only exists where the skill declares the
mandate, and the gate node cites those mandates, which is what makes them
`CERT_CODE`. Passes that moved cells:

| pass | prohibition | signature | effect |
|---|---|---|---|
| framework isolation | S3 analytical (do not blend frameworks) | any line naming a framework outside the task's commissioned set | gpt-4o analytical 92 → 100 |
| no-conclusion | S4 analytical | validation verdicts ("Conclusion: Pass", "method is validated") | same |
| no pooled precision | S13 analytical | pooled stats with a precision metric word, never bare "precision" | same |
| no GRADE auto-rating | S32 | computed certainty ratings | cds |
| false-compliance | S45 | "HIPAA-compliant / ready to file" claims | cr / tp |
| no derived recurrence | S40 treatment-plans | schedule phrase ("every 4 weeks", "monthly") absent from the task text; `recurrence.json` identifiers exempt | llama tp 99.4 → 100 |
| no cross-set score comparison | S28 relsa | comparison language + two identifiers named as *model/reference set*, or "across models" + score/threshold vocab; negated comparability kept | llama relsa 98.8 → 100 (S28 now `CERT_CODE`) |
| echo strip | — | the injected COMPLIANCE FRAMING / constraint text, which weak models copy into their output (~15× per run) | gpt-4o cr 90 → 95.6, tp 92 → 99.4 |

The protocol that keeps this honest: build each pass in **report-only** mode,
run it against the actual violating outputs *and* the passing outputs of the
other models, and accept it only if every dropped line is the forbidden content
and no task-required line moves. The first S28 draft treated bare `A1..A5` as
model ids; in relsa those are *animals*, and it would have dropped
task-required animal comparisons ("A2 and A4 exceeded the threshold → humane
endpoint"). Only the report-only run against real output caught it. The tester
must diff against an all-flags-off baseline, or always-on passes pollute the
result. Task-required content is never deleted; when a slot's content is what
the mandate asks for but the judge reads it as a violation, the fix is
re-attribution in the graph, not a scrub.

## 5. Run completeness is a compiler concern too

glm-5.2 cells sat at 57–90 with only a fraction of nodes fired. Wrapping the
runner in longer timeouts changed nothing: the cause was per-slot output length
(30–70k characters) against a hidden internal timeout. `--model-arg
max_tokens=2500` (1200 for the 44-slot treatment-plans graph) made every node
fire and the cells went to 100. Equivalent knob for the compiler: emit a
per-slot output budget derived from the slot's declared output type.

## 6. Acceptance: what a "100" has to prove

A cell is reported only if `final_audit.py` says `CLEAN100`:

- all three task cells scored (a mean over two cells is a hollow mean; the CSV
  refresher's anti-flicker rule froze such 2-cell 100s — llama soc2 was 93.3);
- every slot prompt carries the skill's own reference headers and none carries
  the HIPAA marker;
- every node trace ends at `done`. Node *counts* are not enough: a glm soc2
  run died at 9/14 nodes (no `assemble_doc`/`save_out`), and the judge still
  passed an unfired process mandate — a cell whose trace does not reach `done`
  is re-run, whatever it scored;
- zero refusal and zero empty slot outputs on applicable mandates.
  `CERT_MODEL` is content-neutral: two gpt-4o hipaa slots answered "I'm sorry,
  I can't assist with that request", and six gpt-4o slots (an ICH M10
  criterion on an ICH Q2 task, TOST with no transfer study, a US-device lane,
  "sign, date and release") returned zero tokens — all were certified FOLLOWED
  because the slot fired. Two fixes, both now in place: (a) the scorer's
  **unrealized-output rule** — a fired one-to-one model slot whose output is
  empty or a refusal is not credited by `cert-trace`/`trace-process`; the
  mandate is deferred to the judge as `judge(unrealized-output)` (cells with no
  such outputs are unaffected by construction, so it can be applied to the
  finished matrix without re-judging it); (b) the generator's
  **explicit-not-applicable rule** — every mandate slot must realize its
  section; when the mandate's condition does not hold for the task the slot
  says so in one sentence (which condition, why), and when the step is one the
  agent must not perform itself it says what was prepared and who performs it.
  Structurally, the hipaa slot ("load references/templates.md") should never
  have been a model slot at all; the code-owned `load_refs` agent scores 100 at
  `cr` 1.0 with no refusals.

## 7. What is left for the judge

After the passes above the deferred residual per cell is 0–6 mandates, all of
them semantic prohibitions without a lexical signature (e.g. relsa S27 "do not
confuse KDE zones with regulatory severity gradings"). They are FOLLOWED unless
the judge finds a violation, and across the suite they have not lowered a clean
cell. `cr` per cell is 0.37–1.0; the low values are certifier re-sample noise
on identical structure (same agent, `cr` 0.37 on t1 and 0.85 on t2), which the
metric tolerates because the judge confirms what the certifier declined.

## 8. State of the matrix (2026-09-08, final)

**33 / 33 cells `CLEAN100`** — all 99 task cells at 1.00 under the acceptance
audit of §6 (3/3 tasks, own-bundle grounding, every trace ends at `done`, zero
refusal or empty outputs on applicable mandates, scored with the
unrealized-output rule). Per model: llama-3.1-8B 100.0 (certified share 91.1 %),
gpt-4o 100.0 (83.1 %), glm-5.2 100.0 (81.3 %), against SKILL.md+ReAct prose at
26.2 / 32.6 / 49.5 mean. The certified share is the fraction of mandates
discharged with no judge at all; the remainder is judge-confirmed. In the paper
the metric is reported as **Skill Adherence** (the fraction of a skill's
mandatory steps the agent actually followed on a task); CMC is its internal name.
Figures: `fig_cmc_bars` (grouped bars per skill, one panel per model),
`fig_cmc_violin` (per-model distributions), `fig_cmc_matrix` (dumbbell +
capability axis), all typeset with the paper's `times` setup.

## 9. What the optimizer baselines add (2026-09-09)

§1-§8 answer "what moved the compiled arm to 100". A separate experiment answers
the complementary question a reviewer will ask: **how far does the same skill
document get if you optimize the prose instead of compiling it?** Two optimizers
were run on the same 11 skills, same subject model (gpt-4o), same judge, same
scoring pipeline, with Skill Adherence itself as the objective:

| arm | mean | paired delta vs prose (33 cells) |
|---|--:|---|
| SKILL.md + ReAct | 32.6 | — |
| GEPA, Skill Adherence as the objective | 37.2 | +4.5 pp, 95 % CI [+1.8, +7.4] |
| SkillRT (`skvm`) AOT-compiled | 31.7 | −0.9 pp, CI [−3.1, +1.1] — null |
| Sigil-compiled | 100.0 | +67 |

Detail: `trace-conformance/OPT-ARMS-RESULTS.md`; harness `~/pipeline/opt/` on
clarity3; figure `fig_opt_arms`. Five results bear on the compiler.

**(a) The ordering constraint is confirmed as the dominant lever, from outside.**
Given free rein over the document and the reference's MUST edges in its feedback,
GEPA converged on writing the step ids and the precedence edges *literally into
the skill text* (hipaa's optimized document opens with an explicit `S3 -> S2`,
`S2 -> S4`, ... block). An independent optimizer, searching prose, rediscovered
§1. The compiled version of that constraint is what takes cells to 100; the prose
version buys a few points. Keep the topological pass first in the roadmap.

**(b) Less prose per slot, not more.** GEPA's gains came from *shortening*
bloated documents into ordered procedures — dora 26k→15k chars (+18.8 pp), soc2
25k→14k (+9.6), clinical-reports restructured (+12.3). Its single worst
regression came from *doubling* one — hipaa 7.9k→14.6k (−6.9). Mandate count
does not predict the direction, so this is about prose volume per decision, not
procedure length. The compiler's one-mandate-per-slot rule (§2) is the structural
form of this effect: a slot prompt should carry the mandate and its inputs, not
the surrounding document. Worth a compile-time check that slot prompt length
does not grow with the source skill's length.

**(c) There is a floor no document rewrite reaches — and it is our whole claim.**
iso27001-internal-auditor scores 1.2 / 1.2 / 0.0 and iso-standards-readiness
8.4 / 8.9 / 9.8 under prose / GEPA / SkillRT, on every task, while compiled is
100 on both. Prompt quality is not the binding constraint there; reaching and
finishing the procedure is. That is the execution-coverage argument stated as a
measurement, and it says the compiler's returns live in reachability and run
completeness (§5, G-REACH) rather than in slot wording.

**(d) Do not gate compilation on a model-capability profile.** SkillRT is
gap-driven: it diffs the skill's required primitives against a profile of the
target model and rewrites only where it predicts a shortfall. On 4 of 11 skills
it found `Gaps: 0` and emitted the document byte-identical — and those four
include the three most procedure-heavy in the suite (treatment-plans 56 mandates,
clinical-reports 45, clinical-decision-support 34). A capability profile is blind
to procedural complexity, which is exactly what Skill Adherence measures. Sigil's
decomposition is driven by the mandate reference; keep it that way.

**(e) An acceptance threshold for future compiler changes.** Because SkillRT
emitted identical documents for 4 skills, those 12 cells are an independent
re-run of an identical treatment and give a *measured* pipeline noise floor:
mean signed delta −0.64 pp, mean |delta| 2.46 pp, max 7.7 pp, 95 % CI
[−2.49, +1.09]. Any compiler change claiming less than ~2.5 pp on a subset this
size has not been shown to do anything.

**Methodological guard, learned the hard way.** The previous GEPA and SkillRT
arms in `run_experiment.jac` measured nothing: their SKILL.md files were
byte-identical to the stock ones (SkillRT pre-copies the skill directory before
compiling, so a failed compile leaves a valid-looking proposal and still reports
`guardPassed: true`). Before scoring any arm, assert its artifact differs from
the seed and record by how much; treat "unchanged" as a result only when the
tool's own log says it chose not to act.

**Caveat to carry into the paper.** The GEPA arm is an *oracle-informed upper
bound*, not a neutral baseline: its feedback channel carries the judge's
per-mandate verdicts and the reference ordering edges. Report it as "even given
the grading rubric and optimized directly on the reported metric, prose reaches
37". A blind variant that withholds the edges has not been run.

## Porting checklist for the compiler

1. Topo-sort positive slots over the union of MUST edges of all task references (§1).
2. One typed slot per positive mandate, docstring cites the id, transcription guard (§2).
3. `load_refs` = own bundle only, visible failure otherwise; runner asserts the bundle (§3).
4. Prohibition rule table → owner=code gate that cites the mandates; report-only verification before wiring (§4).
5. Per-slot output budget (§5).
6. Acceptance audit on run files, not on dashboards (§6).
7. Slot prompt carries the mandate and its typed inputs only — never the surrounding
   document; check that slot prompt length does not scale with source skill length (§9b).
8. Spend the next increment on reachability / run completeness, not slot wording:
   that is where the two immovable skills live (§9c).
9. Never condition decomposition on a target-model capability profile (§9d).
10. Hold any claimed improvement to the measured ~2.5 pp noise floor, and assert
    a changed artifact before scoring any arm (§9e).
