# The Sigil compiler — two halves

The SKILL-compilation pipeline (`SKILL.md → agent.ir → agent.jac`) split as a
classic compiler:

```
src/compiler/
  mechanical/        the LOWER back-end — deterministic, judgment-free
    compiler.jac       transpile_ir(ir_text, name) -> .jac source
    assets/            runtime helpers injected verbatim into generated modules
  ai/                the LIFT front-end — authors the AG-IR under a faithfulness constraint
    types.jac          Rule / RuleSet / verdicts — the typed vocabulary
    spec_loop.jac      Stage 1: SKILL.md -> frozen RuleSet (the convergence loop)
    gates.jac          the gate battery (seeded with G4, the compile oracle)
```

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
