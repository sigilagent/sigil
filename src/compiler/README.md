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
    ir_views.jac       the four AG-IR views (nodes/edges, carries, residency, tools, HIL)
    spec_loop.jac      Stage 1: SKILL.md -> frozen RuleSet (the convergence loop)
    workflow.jac       Stage 2: the WorkFlow spine (CFG view) + its code validator
    flows.jac          Stage 3: IO/Context/Knowledge/HIL flows — flow/wait SPAWN fan-out
    assemble.jac       Stage 4: the rule-id join + reflexive 5d -> AG-IR YAML
    gates.jac          G1 standalone · G4 compile oracle · G5 STRUCT-COV
    repair.jac         per-error-class repair (view repair + scoped repair_ir loop)
    lift.jac           the public entrypoint: lift(skill, name) -> LiftResult
```

Opt-in wiring: `SIGIL_AI_LIFT=1 sigil register-skill ./SKILL.md` routes the md
path through the gated LIFT (a gate failure raises — fail loud — rather than
persisting an unfaithful skill); unset, the legacy one-shot `lift_skill` runs.

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
