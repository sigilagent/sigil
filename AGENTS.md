# AGENTS

Guidance for automated assistants that read, review or edit the effect gate (`G6_EFFECT`).
`Prefer` and `consider` mark defaults that leave room for judgment;
other directives are requirements within the scope below.

## Scope

This file came with the effect gate pull request and covers only these files:

- `src/compiler/ai/effect_scan.jac`: the scan, the gate's first reader.
- `src/compiler/ai/effect_gate.jac`: findings, the model reader, repair, the ACT fallback,
  the re-lower check, and the re-check after compile repair.
- `src/compiler/ai/effect_scan.test.jac` and `src/compiler/ai/effect_gate.test.jac`.
- The effect rung in `src/compiler/ai/raise2.jac` (`raise_from_spec`) and its model pin in `pin_raise2_llms`.

For every other file, follow the repository's existing conventions; nothing here overrides them.
The maintainers may extend, move or drop this file.

## What the Gate Checks

The compile-time model labels each tool's `surface` (OBSERVE or ACT), and lowering trusts the label:
an ACT tool's path parameters bind write-side, and an OBSERVE tool is dispatched as a sense tool.
The gate compares the label with what the tool's bound code does.

Read the relevant parts before changing it:

- [ais-spec](docs/reference/ais-spec.md) §4.3.1-§4.3.3, for what changes world state,
  the workspace and artifact surfaces, and which opcodes may call an ACT tool; §5.4 for the required `surface`.
- The module docstrings of `effect_scan.jac` and `effect_gate.jac`.
- The pull request description, for what broke, how it was measured, and the open questions.

## Invariants

1. The scan runs nothing. It parses a tool's `body` and the bundled files it names;
   it never imports, executes or spawns skill code. Skill folders are untrusted input.
2. What the scan reads but cannot follow is `unknown`, never clean: a process it cannot see into,
   a library it has no rules for, a bundled file it cannot read.
   A call no pattern names is not seen; that is the scan's stated limit (its module docstring), not a clean verdict.
   A new pattern may move a case from unknown to a write or to a clean read; it must not drop a case.
3. Read a tool the way lowering runs it. A code-less tool named after a builtin is checked against the
   builtin's body (`_as_lowered`), and an instruction is bound to a tool by lowering's own `_node_tool`.
   Do not re-implement either: a gate that binds differently misses writes or warns about calls that never happen.
4. The model reader sees the tool's code only (`tool_source`), with no label and no doc.
   Do not add the label or the doc to its prompt: the reader would echo them.
   Its "no" clears the scan's verdict only when it was shown all the code (`source_complete`).
5. "Writes" follows ais-spec: any change to state outside the process,
   temporary files and a runtime's own bookkeeping included (§4.3.2).
   Do not narrow this, for example to drop `__pycache__` or npm's debug log, without a maintainer decision;
   the pull request asks it as an open question.
6. A model repair is adopted only when it parses and fixes a finding (a rewrite keeps code, which the scan finds clean),
   adds no writing tool below ACT and no instruction calling a writing tool its opcode may not (by the scan alone),
   still lowers (unless the input did not), and, when a spec is given, does not widen the faithfulness gap.
   Before it is judged, each instruction in the candidate gets back the `surface` it had (`_keep_instruction_surfaces`):
   lowering reports what an ACT instruction with an artifact surface writes as a deliverable, so a surface the repair
   set could move the skill's answer out of the terminal report.
   Keep every condition when changing the repair.
7. What the model does not fix is relabeled ACT mechanically, and the relabel is logged in the repair ladder.
   After a mechanical relabel the module is lowered before and after, and every call of the tool is compared;
   a changed call is a warning. When the rung changed the IR, its terminal report line is compared the same way
   (`_report_change`); a change in which carries it shows is a warning.
   Both kinds of warning describe the rung's own change and stay after compile repair.
8. After compile repair replaces the IR, the rung runs again without repair attempts (`effect_after_repair`),
   and a relabel is kept only if `compile_gate` still passes.
   Warnings describe the IR that is kept: one a repair resolved is dropped, since a strict compile fails on any warning.
9. What nobody can settle is a repair-ladder line, not a warning: a strict compile fails on any warning.
   A failed model call leaves the scan's verdict.
10. The gate switches with `gate_enabled("G6_EFFECT")` (`SIGIL_GATE_G6_EFFECT=off`, or `G6_EFFECT` in
    `SIGIL_GATES_OFF`). A finding is `[gate_id, "G6_EFFECT: what is wrong. How to fix it."]`, as for the other gates.
11. Model use stays bounded: at most `_MODEL_MAX_TOOLS` tools per compile (the recheck after compile repair
    shares the rung's budget through `asked`), `_MODEL_MAX_CHARS` characters of code per tool,
    and the rung's own `max_repair` allowance.

## Editing

- Keep `src/` pure Jac. Analyze Python with the standard `ast` module, as `gates.jac` does.
- Pair each new scan pattern with a test it must flag and a read-only twin it must not.
  Keep bug reproducers as regression tests.
- Tests play the model with a scripted `MockLLM`; no test calls a real model.
- Keep `G6_EFFECT` as the id until the maintainers settle the name (open question 1).
- A change to the scan's patterns or the reader's prompt changes which tools are flagged.
  Say in the pull request which reported numbers it invalidates.
  Those numbers come from compiles outside this repository; do not restate them in code comments.

## Validation

While iterating, run the two test files:

```sh
jac test src/compiler/ai/effect_scan.test.jac
jac test src/compiler/ai/effect_gate.test.jac
```

Before pushing, run what `.github/workflows/ci.yml` runs:
`jac test src/*.test.jac src/report_fix_tests.jac src/lowering_fix_tests.jac`,
then `jac test src/compiler/ai/*.test.jac` in a separate process,
then the scenarios under `src/compiler/ai/scenarios/` with `jac run --no-serve`.

A live check, such as a real compile with the gate on or the model reader on real tools,
spends model quota or money. Run one only when the user asks.

## Evaluation

The scan's patterns and the reader's prompt were developed on a fixed set of compiles.
A separate held-out set is evaluated once, with this code frozen.
Do not tune the patterns or the prompt on held-out results.
If either changes afterwards, the held-out numbers no longer describe the code; say so.

## Language and Style

- Use English for identifiers, comments, documentation and commit messages.
  Talk to the user in the user's language.
- A module docstring says why the module exists. A comment explains why, citing the concrete case when there is one.
- A test file opens with a docstring naming the properties it locks in, uses `# --- section ---` dividers,
  and gives each test a full-sentence name.
- Write plain, concrete prose, one point per sentence. Say what was not run.

## Commit Messages

Follow the repository's history: `feat(scope): ...`, `fix: ...` or `test: ...`,
lowercase, on one line with no trailing period.
The body gives the concrete incident with its numbers, then a bullet list of the changes.
