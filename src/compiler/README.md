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

## Field lessons (SkillsBench pilot, 2026-08-13)

A paired benchmark (OpenHands agent, six tasks, three delivery baselines and
six compiled-arm variants) measured where compiled skills actually fail in an
agent's hands. Each lesson below is enforced in code where marked; the rest
are design obligations for the authoring/gate layers.

**Delivery (enforced in this tree):**
- Emit a structured calling convention from the IR's input carries
  (`--<input>=<value>` → `params` → spawn binding, `_EJ_PARAM_KEYS` manifest).
  Free-text-only invocation forces a lossy NL round-trip that small models
  fail (`<field>=task` stuffing). — `mechanical/compiler.jac`, `ai/eject.jac`
- Bound inputs imply a runnable call: never block on the interactive
  ask-prompt when params were provided. — `ai/eject.jac`
- Every ejected artifact is also an MCP tool (`--mcp` stdio serve mode,
  schema from the manifest, description from the skill's imperative surface,
  in-process `run()`, stdout kept protocol-clean). Delivered as native tools,
  the pilot's artifacts went 6/6 where prose delivery scored 0–2/6.
  — `ai/eject.jac`
- A served tool's outputs must land in the caller's workspace
  (`SIGIL_CALLER_CWD`), not the tool's private workdir. — `ai/eject.jac`
- A tool param no rescue rung can bind must never silently lower to a null
  argument; pathish names are shape-matched (`*_path`, `*_file`, …) and the
  residue warns at compile time. — `mechanical/compiler.jac`

**Obligation classification (partly enforced):**
- ASSUMED-optional obligations that are INPUT/OUTPUT steps get an elevated
  warning: an agent that may skip loading its inputs cannot be faithful in
  practice. — `ai/spec_loop.jac`
- Clarify questions about already-negated quotes ("Avoid X") carry a
  double-negation note so 'do'/'dont' answers cannot flip the rule.
  — `ai/spec_loop.jac`
- Open: register mining (rules living in code comments, ❌/DO markers, and
  narrative sequence get demoted); a library-style skill with no imperative
  procedure compiles SILENTLY into an invented workflow and should warn.

**Emitted-tool robustness (design obligations, validated by hand-tunes):**
- Callers improvise parameter dialects (lists vs scalars, object sources,
  renamed keys) and workflows (batch, incremental append, prose-only);
  a tool needs one authoritative accumulated spec that every input shape
  normalizes into — the artifact's internal model is the right engine for
  the prose case.
- Destructive fallbacks must be structurally impossible (never demo data
  over an existing file); errors must be actionable (name available vs
  requested columns and the fixing move).
- Skills whose success criteria are structural (grammars, spreadsheets,
  lexical scoring) should compile to deterministic code, not `by llm`
  stages — cheaper and correct; the pilot's tool-model sweep showed the
  internal model then becomes a price knob (gpt-4o-mini internals: 5/6).
