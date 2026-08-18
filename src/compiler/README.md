# The Sigil compiler — two halves

The SKILL-compilation pipeline (`SKILL.md → agent.ir → agent.jac`) split as a
classic compiler:

```
src/compiler/
  mechanical/        the LOWER back-end — deterministic, judgment-free
    compiler.jac       transpile_ir(ir_text, name) -> .jac source
    assets/            runtime helpers injected verbatim into generated modules
  ai/                the LIFT front-end — authors the AG-IR under a faithfulness constraint
    lift_types.jac     Rule / RuleSet / verdicts — the typed vocabulary
    passes.jac         PHASE 2: whole-IR refinement passes after the coherent author
    ir_views.jac       the four AG-IR views (nodes/edges, carries, residency, tools, HIL)
    spec_loop.jac      Stage 1: SKILL.md -> frozen RuleSet (the convergence loop)
    workflow.jac       Stage 2: the WorkFlow spine (CFG view) + its code validator
    flows.jac          Stage 3: IO/Context/Knowledge/HIL flows — flow/wait SPAWN fan-out
    assemble.jac       Stage 4: the rule-id join + reflexive 5d -> AG-IR YAML
    gates.jac          G1 standalone · G4 compile oracle · G5 STRUCT-COV
    autofix.jac        mechanical fix-forward: lanes / pointer inlining / hollow re-own
    repair.jac         per-error-class repair (view repair + scoped repair_ir loop)
    report.jac         severity classification · status (failed|degraded|fixed|clean) · explain
    lift.jac           the public entrypoint: lift(skill, name, skill_dir) -> LiftResult
```

Wiring: there is ONE compile pathway. `sigil compile` and `sigil register-skill
<SKILL.md>` both run `compile_skill` (raise2 by default; `SIGIL_FRONTEND=legacy|staged`
selects the older front-ends), and `sigil relearn` recompiles a skill's stored
source through the same engine at a bumped version.

**The raise contract is fix-forward.** The gates DIAGNOSE; they do not veto. A
lift fails only when no runnable module exists (G4 rejects the IR after the
whole repair ladder) — and a failure raises the `explain()` note (what failed,
what the ladder tried, the next concrete step), never a bare error. Everything
runnable persists: mechanical autofixes land first (each re-gated through G4),
scoped model repair second, faithful degradation third, and whatever remains
rides `LiftResult.findings` as typed `{gate, severity, message}` entries —
errors are runtime crashes / violated mandates (G3/G6/G8/G9), warnings are
faithfulness audits (G1/G5/G7/spec/spine/assemble). `--strict` / `SIGIL_STRICT=1`
restores fail-on-any-finding for CI.

The first-class entry is the CLI:

```bash
sigil compile ./SKILL.md                 # gated AI lift -> TaskGraph on the graph
sigil compile ./SKILL.md -e agent.jac    # ...and EJECT one runnable program:
./agent.jac "extract the tables"         #    shebang'd, self-contained, executable
SIGIL_MODEL=ollama_chat/qwen3:8b ./agent.jac "..."   # pick the execution model
```

`eject.jac` packages the compiled module (which already embeds the full runtime
helper library) with a `jac run` shebang + a CLI shim — one file, no sigil, no
session, no graph needed to run it. The AG-IR provenance stays on the graph.

**Authoring is one call; refinement is staged after it.** `author_direct` writes
the whole AG-IR in a single frontier pass, because the IR is a mutually
referential graph — carries, edges, `traces_to`, tool→node bindings — and the old
staged front-end, which cut the *artifact* by view (spine → flows → assemble), had
to reconcile those cross-references mechanically afterward. That cut maximized
coupling; the seams were the cut expressing itself, not a bug in it.

What one-call authoring gave up is that the staged pipeline emitted *data*
(`yaml.safe_dump`) and so was well-formed by construction, while a single author
emits *text* — and text can be malformed. `passes.jac` recovers that without
re-staging the authoring: phase 2 cuts by **dimension** instead of by view, so each
pass sees the whole IR and improves one property of it, the way a compiler pass
sees the whole program rather than a shard.

```
author (one coherent call) → faith → repair ladder → PHASE 2 passes → G4
```

A pass is adopted only if its output still lowers AND does not regress
faithfulness, and the phase as a whole reverts if the full `jac check` gate rejects
what it produced. So a pass is pure upside or a no-op; it can never be why a
compile fails. Switchable end to end — `--no-phase2` / `SIGIL_PHASE2=0` restores
the exact pre-phase-2 pipeline, `--passes <a,b|all>` / `SIGIL_PASSES` runs a chosen
subset.

**The mechanical half** lowers an AG-IR exactly as written — every IR construct
has one Jac form; if lowering ever needs a judgment call, the IR was
underspecified and the *front-end* is at fault.

**The AI half** is where judgment lives, structured so it cannot silently drift:

- **The Spec loop** (`spec_loop.jac`): *the model proposes, code disposes.*
  A frontier slot extracts candidate rules; a deterministic grounding check
  drops any rule whose quote is not verbatim in the skill (anti-hallucination —
  the loop can never declare victory over an ungrounded spec); three coverage
  critics hunt for dropped obligations, self-filtered by the same grounding
  check; a code audit catches modality drift and conditional-inflation. Loops
  until sound ∧ complete ∧ no-drift (with dry-detection + a hard cap), then
  freezes the RuleSet — the anchor every later stage is audited against.
- **The gates** (`gates.jac`): typed, routed verdicts — never a silent success.
  G4 round-trips a candidate IR through `mechanical.transpile_ir` + `jac check`
  and rejects empty lowerings; the remaining gates (standalone / C1 /
  determinization / STRUCT-COV / grounding-integrity) land beside it.

Architecture + the finding→design rationale: `agentic-voodoo/docs/agir-lift-harness.md`.

Tests: `jac test src/compiler/ai/spec_loop.jac` (MockLLM-driven convergence) and
`jac test src/compiler/ai/gates.jac` (live compile-oracle round-trip).
