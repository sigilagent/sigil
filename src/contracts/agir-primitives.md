# AG-IR — Components & Primitives (the reference card)

> The single catalog of *what an `agent.ir` is made of*. The **concepts** live in
> [agir-methodology.md](agir-methodology.md), the **how-to** in
> [skill-to-agent-pipeline.md](skill-to-agent-pipeline.md), the **byLLM/OSP patterns** in
> [skill-to-osp-playbook.md](skill-to-osp-playbook.md), the **measurements** in
> [agir-bench-results.md](agir-bench-results.md). This doc is the vocabulary those
> three assume — the alphabet, the annotations, the component sections, the
> composite primitives, and the lowering map — in one place.

AG-IR is the analyzable middle between fuzzy prose and an executable agent: a
typed, annotated graph of every move the agent makes, each move attributed to
*code* or *model*. You author it by hand/model (the **LIFT**), and it lowers
mechanically to a Jac/OSP walker program (the **LOWER**). It is a **compile-time
artifact — never injected into a prompt at runtime** (the IR-in-prompt arm was
the most expensive thing measured).

---

## 0. One graph, four views

An AG-IR is **a single graph** read four ways. The four are not separate
artifacts — they are four readings of the same nodes and edges, and that is why
the graph lowers onto OSP with no impedance mismatch.

| View | What you read off the graph | Lowers to (OSP) |
|------|------------------------------|-----------------|
| **Flowchart** | boxes + arrows — the human-legible shape | `node`/`edge` topology, 1:1 |
| **CFG** (control) | traversal order: next / branch / loop / fork | the **walker's** `visit`/`spawn` order over edges |
| **Dataflow** | which datum is produced where, consumed where | the **static/moving partition** (§5) |
| **Knowledge graph** | the skill's domain facts (typed `sem`, library maps, constraints) | data resident **on nodes/edges** |

---

## 1. The node alphabet (the *what*)

Every node is **exactly one action-type**. The type answers *what kind of move*;
the orthogonal `owner` axis (§3) answers *who makes it*.

### Mind — produce/transform tokens (owner: **model**, always)

Ordered most-constrained → least. **P2 says: always pick the tightest form the
intent allows.**

| Node | Meaning | Output shape | Jac form |
|------|---------|--------------|----------|
| `GEN-ENUM` | choose from a fixed set | one enum member | `def f(x) -> SomeEnum by llm();` |
| `GEN-FILL` | fill a typed object from context | schema-validated struct | `def f(x) -> SomeObj by llm();` |
| `GEN-EDIT` | mutate existing content, touching only what must change | diff over prior state | typed `Diff` slot + `verify_diff` + `apply_diff` |
| `GEN-RAW` | free-form generation (last resort) | string / stream | `def f(x) -> str by llm();` |

> Tightening preference: `GEN-ENUM > GEN-FILL > GEN-EDIT > GEN-RAW`. "Classify the
> operation" is `GEN-ENUM` over a taxonomy, **not** `GEN-RAW`. Reserve `GEN-RAW`
> for genuinely open-ended output (a created document body, the NL reply).

### Flow — direct what happens next (owner: **code or model**)

| Node | Meaning | Jac form |
|------|---------|----------|
| `ROUTE` | branch on a condition | code: `if … { visit [-->][?:Target]; }` · model: `visit [-->] by llm(intent=…, incl_info=…)` |
| `LOOP` | repeat/pipeline until a guard holds | walker `while` + an `EXTRACT` verdict + revise body |
| `SPAWN` | launch a subagent in an independent context (parallel) | `spawn` additional walkers; `flow … spawn …` + `wait task` |
| `CALL` | expand another AG-IR inline, same context (composition) | same walker visiting a sub-region / a named sub-walker |

### Boundary — move information across the context/world line (owner: **code or model**)

| Node | Meaning | Semantics |
|------|---------|-----------|
| `SENSE` | pull world-state in (read file, grep, query, fetch) | idempotent, reversible, retry-safe |
| `ACT·artifact` | push out a **deliverable the user interacts with** (named file, stdout, email, PR) | **must be a tool**; modality + confirmation gates live here; params usually **task-variant** |
| `ACT·workspace` | scratch inside the sandbox (temp files, intermediates) | **free & ungated** — disposable |

> The `ACT` split line is the **user-interaction line, not the filesystem**. Rule
> of thumb: *if deleting the workspace would lose it and the user would care, it
> crossed the boundary — make it a tool.*

### Code — deterministic compute (owner: **code**, always)

| Node | Meaning |
|------|---------|
| `CODE` | output is a pure function of inputs: parse, route-key, math, bind a value onto the graph |

`CODE` is the `owner=code` counterpart to the `GEN-*` family — the thing the Mind
taxonomy deliberately excludes. A non-deterministic `CODE` node (clock, network,
`random()`) is a *smell*: either make it deterministic or admit it's a `SENSE`/model node.

---

## 2. The edge primitives (the *how-much*)

An edge is `(from → to, modality, guard?)`. **Modality is read straight from the
prose's deontic vocabulary** — it is the load-bearing annotation, because OSP
makes it *structural* rather than asserted.

| Modality | Prose signal | Lowered as |
|----------|--------------|------------|
| `mandatory` | "must", "always", "follow its instructions" | a walker `can X with NodeType entry` ability — **fires by construction, model can't skip it** |
| `discretionary` | "if needed", "for advanced… see", "may" | code consumes a typed verdict from an `EXTRACT` slot |
| `forbidden` | "never", "do not" | **omitted entirely** — the model can't route to a code path that doesn't exist (attaches as a node `constraints:` entry, not a transition) |

**Enforceability is structural, not asserted.** "Required" → ability; "NEVER" →
absent path. That is the whole point of lowering modality to OSP.

---

## 3. The two per-node annotations

A node is fully specified by `(action-type, owner, payload)` + the modality of its
in/out edges.

- **`owner`** — `code` or `model`. `GEN-*` is always model; `CODE` is always code;
  `SENSE`/`ACT`/`ROUTE`/`LOOP`/`SPAWN`/`CALL` can be either. Set by the **Owner test**
  (§4, P1).
- **`modality`** — on the node's edges (§2).

### Nodes are typed holes, not forward passes

A `GEN-*` node is **a contract, not a procedure**. `owner` splits *within* a
cognitive node:

> **code owns the envelope** — output type, in-scope tools, step budget, the
> modality of any acts the node may perform.
> **model owns the body** — which may itself be a ReAct loop, terminating only
> when it yields a schema-valid output.

You audit the *envelope*, not the *body* — exactly like a typed function signature
is checkable while its body is free. This is what keeps a compiled agent
un-brittle when input diverges from the shape the compiler assumed (P3, §4).

---

## 4. The principles (the *why*) — three principles + one constraint

The LIFT is an **optimization over the prose, bounded by faithfulness**.

| | Name | The test | Effect |
|---|------|----------|--------|
| **P1** | Determinize maximally | **Owner test:** *is the output a function of the inputs — mechanizable without a guess?* yes → `owner=code` | reclaims steps from model to code — where the cost win is born |
| **P2** | Type the cognition | for every surviving model node, assign the **tightest** Mind type (`ENUM>FILL>EDIT>RAW`) | even surviving cognition is verifiable, not a hoped-for parse |
| **P3** | Preserve an autonomy floor | reintroduce freedom *only in the discretionary interior* (intra-node ReAct; outward typed cannot-satisfy → code handler) | un-brittle without breaking the modality skeleton |
| **C1** | Faithfulness (constraint) | P1/P2 may **re-attribute and tighten**; they may **not add, drop, or re-modalize** a step vs the prose | makes the IR a *measurement* of the skill, not a rewrite of it |

> **The invariant that makes P3 safe:** the modality skeleton is fixed; autonomy
> lives only in the discretionary interior. A fallback loop may roam anywhere not
> nailed down, but it can never skip a `mandatory` node or take a `forbidden` edge.

### The snippet sort (P1 applied to a prose skill's code blocks)

A prose skill is *mostly code snippets*; each is dual-use, sorted by the Owner test:

- **snippet → `tool`** (`owner=code`): the op is a function of its inputs (merge,
  split, rotate, encrypt — only args vary). The **body becomes the tool**, run
  verbatim. *More* faithful than `GEN-RAW` (runs the prescribed code, can't drift),
  and it **collapses the library map** (the tool *is* the library choice).
- **snippet → `knowledge`** (resident on a node): a *pattern that grounds a judgment*
  (build-a-report with reportlab; content open-ended). Stays reference text a
  surviving `GEN-RAW` node reads.

---

## 5. The data partition (the dataflow view's payoff)

For each datum the graph touches: **does it sit still or travel?**

| | Where it goes | OSP form | Examples |
|---|---|---|---|
| **Static** (read by many, not mutated per run) | on a **node/edge** → the knowledge-graph layer | node `has` data / `knowledge:` | skill prose, library maps, op taxonomy, constraints |
| **Moving** (produced at one node, consumed downstream) | carried by the **walker** | `walker.carries` with a `produced_by` | the chosen op, the plan, the script, verifier results |

This is what decides the OSP layout. **Concurrency is just "more than one walker":**
wherever two branches share no moving data, a `SPAWN` forks subagent-walkers that
traverse in parallel and rejoin.

### SPAWN isolation — read-shared, write-isolated

Parallel siblings share a race surface. The rule:

- each sibling **writes/deletes only its own** workspace (own worktree / scratch dir / namespace);
- siblings may freely **read** fork-immutable shared state;
- any multi-writer state is hoisted to the **orchestrator** and applied **at the barrier**.

Declare it on the SPAWN node: `isolation: { private_write, shared_read, orchestrator_owned }`.
A SPAWN with shared *writable* state and no isolation is a bug, not a design.

---

## 6. The `agent.ir` component sections (the file anatomy)

An `.ir` is YAML. Frontmatter is copied verbatim from `SKILL.md`; the body has
fixed top-level sections, produced by running the phases in order.

| Section | Holds | View / phase |
|---------|-------|--------------|
| `types` | typed cognitive outputs — `enum`s & `obj`s | Phase 1 / P2 |
| `tools` | crystallized snippets (`owner=code`), **bodies VERBATIM** | the snippet sort (P1) |
| `knowledge` | static data resident on nodes (the knowledge-graph view) | Phase 4 |
| `walker` | moving state the agent carries (the dataflow view) | Phase 4 |
| `nodes` | one entry per action (the flowchart view) | Phase 1/2 |
| `edges` | control flow + modality + guards (the CFG view) | Phase 3 |
| `concurrency` | SPAWN points, or `spawn: none` **with a reason** | Phase 4 |
| `faithfulness` | the C1 audit record + deviations/extensions | Phase 5 |
| `standalone` / `shape` | self-containment flag; topology label (flat-router / dispatch-router / pipeline / …) | header |

### The embodiment rule (`prose:` is provenance only)

Every load-bearing artifact is embodied **verbatim** in the IR — tool bodies →
`tools[].body`, sub-agent prompts → `knowledge.<x>.template`, exact commands /
endpoints / user-facing strings → embedded, patterns grounding a `GEN-RAW` →
`knowledge.<x>.pattern`. A `prose:`/`library:`/`doc:` pointer *in place of* content
is the **prose-pointer anti-pattern**: the graph looks complete but the bytes still
live in `SKILL.md`, forcing LOWER to re-derive them (reintroducing the per-run cost
the IR exists to remove).

---

## 7. The four acceptance gates (the LIFT is not done until these pass)

| Gate | Question | Guards the seam |
|------|----------|-----------------|
| **C1 audit** (Phase 5) | no hallucinated / dropped / re-modalized / owner-overreach nodes? | IR ↔ prose **structure** |
| **5b — delete-SKILL.md** (Standalone) | delete `SKILL.md` — can the IR still lower to a working agent? | IR ↔ prose **embodiment** |
| **5c — bundle-depth** | recurse every sibling resource: local know-how embodied, sub-skills are standalone sub-IRs, web stays live | IR ↔ the rest of the **bundle** |
| **5d — determinization-completeness** | given only the typed carrier (not the raw task), can every required artifact still be produced? | every **intra-agent** `task → Plan` projection |

> 5b makes "standalone" **two-tier**: *bundle-independent* (all local know-how
> embodied) vs *world-independent* (impossible whenever the skill fetches live web
> — and that's correct, not a defect). 5d is the *intra-agent analog* of 5b: tight
> scoping is the source of the cost win, and the same tightness clips any deliverable
> a loose loop covered incidentally — fix by **widening the typed carrier**
> (`Plan.deliverables: list[FileSpec]` + an emitter), not by loosening back up.

---

## 8. Composite / derived primitives (the patterns worth a name)

These are not new atoms — they are load-bearing *shapes* over the alphabet, each
earned from a measured failure.

### `EDIT` (the safe-edit primitive) — `GEN-EDIT` lowered with code-owned safety

Cognitive output is a typed `Diff`; `verify_diff` (BASIC) rejects diffs that exceed
a deletion budget or break byte-identity of untouched ranges; `apply_diff` (BASIC)
applies deterministically. **Its value is in what it makes impossible:** a
`(source, intent) -> new_source` `GEN-RAW` slot can silently truncate / drop
siblings / collapse a multi-component file; EDIT cannot.

- **Rule:** if a slot's signature is `(existing_artifact, intent) -> new_artifact`,
  the right primitive is **EDIT, not GENERATE**.
- **Counter-rule:** *EDIT for surgical, GENERATE for architectural.* EDIT's safety
  is exactly what stops it expressing "restructure the data flow." Always pair EDIT
  with a **GENERATE-after-EDIT fallback — triggered by STALL** (blocker count didn't
  strictly decrease on re-verify), not just by rejection.

### Skeleton-first build (the decl/impl seam) — for "author a whole multi-part artifact"

Don't lower a big multi-file authoring step as one open `INVOKE` ReAct loop (the
mcp-builder negative result). Lower it as:

```
plan_skeleton  GEN-FILL : task/plan -> typed Skeleton (decl-only scaffold + per-part stubs)
GATE 1 (code)           : write scaffold, compile/type-check it ALONE  (cheap structural red-check)
fill_part  LOOP         : per stub, GENERATE ONE part bound to (its signature + its slice) — localized
GATE 2 (code)           : assemble + compile, capped repair
```

Two paired moves make it pay: **owned-research** (stable reference is a
deterministic owned read, not a live-web ReAct loop — only world-varying data stays
a single bounded `WebFetch`) and **localized fills** (each fill sees only its
stub + the immutable scaffold + its data slice → a natural `SPAWN`,
read-shared/write-isolated). Measured: **2.9× cheaper than the original OSP at
parity correctness** on mcp-builder t0. **Mandatory companion:** the 5d gate (tight
scoping silently drops un-typed deliverables).

### `WebFetch`-as-a-node — live grounding is not paraphrasable

A `SKILL.md` `WebFetch <url>` is **not** a stylistic hint; it is a hard claim that
the agent needs the *current bytes* at runtime. It lowers to a code-owned BASIC
fetch (mandatory by construction: `can ground_X with Root entry`) followed by a
typed `EXTRACT` that pins the load-bearing fields. Dropping it "because the model
knows this" is the most common faithfulness bug — and makes the OSP rewrite
*strictly worse* than prose (prose ReAct at least calls the tool when it remembers;
the OSP rewrite has structurally guaranteed it never will).

### Eval/verify grounding — "pass" must be a typed-grounding signal

In any eval/verify loop, *"pass"* must be a function of typed-grounding signals from
the loop body, not just a string match. If the grounding source could have been
bypassed (a tool returned `SERVER_NOT_AVAILABLE` and the model answered from
training memory), either **remove the bypass** (restrict the tool surface) or
**record whether it was used** (`EvalResult { grounded, …, passed }`).

---

## 9. The lowering map (`agent.ir` → `agent.jac`)

LOWER is **mechanical** — one IR construct, one Jac form. If you're making judgment
calls during LOWER, the IR was underspecified; fix the IR, not the Jac.

| `agent.ir` | `agent.jac` |
|------------|-------------|
| `types.<Enum>` / `<Obj>` | `enum`/`obj` + `sem` per member/field (defaults on every field; **no `T \| None`** on graph-resident objs) |
| `nodes[].GEN-*` | module-level `def <slot>(...) -> <T> by llm();` + `sem` |
| `tools[]` | `owner=code` function (native Jac `def`, or `::py::` for byte-exact) + a deterministic dispatcher |
| `nodes[]` | `node <Name> {}` archetype |
| `edges[]` | `++>` connections built in `run()` |
| `walker.carries` | `walker { has <field>: <T> = <default>; }` |
| node action / `mandatory` edge | `can <n> with <Node> entry { … visit [-->]; }` ability |
| `route` (code / model) | `if … { visit [-->][?:Target]; }` / `visit [-->] by llm(intent=…, incl_info=…)` |
| `SPAWN` | `spawn` additional walkers |
| `autonomy.tools` | `by llm(tools=[…])` on the slot |
| the agent / entrypoint | a `walker`; `def run(task, model, skill) -> str { global llm; llm = model; … }` |

### The non-negotiables (each a measured footgun)

- **Model via `glob llm` rebound by `run()`, never as a parameter** — parameter-threading leaks the `Model` spec into the prompt.
- **The IR text never enters a prompt** — it was lowered at build time; runtime sees only slot signatures + `sem` + the task.
- **`by llm()` with parens**; `import from jaclang.byllm.lib { Model }` (byLLM is core to jac).
- **Keep `by llm()` slots at arity ≤3** — byLLM's MTIR mis-extracts params for a complex-first-arg slot at arity 4 (`IndexError` in `mtir.impl.jac:factory`); fold extra inputs into one context string. *(Distinct from the stale-cache `IndexError`, which `jac purge` fixes — if it survives purge, it's the arity bug.)*
- **An enum-return slot must not also carry `tools=[…]`** — the final-turn coercion is fragile.
- **A file-writing tool must `mkdir -p` its parent** — a bare `open()` throws inside a `tools=` loop → silent retry thrash.
- **`visit`/`here` only inside a `can … entry` ability** — never in a plain walker `def` method (compiles, throws `NameError` at runtime).
- **A graceful error-return must be ROUTED** — an unrouted `SCRIPT_ERROR` sentinel is a silent success; guard the verify node too.
- **One repair slot per error CLASS** — never widen a skill-prescribed repair sem to a second error class (P2 applied to handlers).

---

## 10. The decision rule, and the honest scope

> **Convert when failure is *coordination*; keep prose when failure is *authoring
> or knowledge*. In either case, extracting the AG-IR is free leverage — do it
> before deciding.**

What OSP's win actually covers: mechanical coordination ✓, mandatory steps made
structural ✓, verification grounding ✓. What it does **not**: delegated judgment
(when to stop, what's "good enough") stays model-dependent — OSP makes it *typed,
observable, governable* but cannot make it *correct*; artifact quality on
authoring-bottlenecked tasks is dominated by the `GEN-RAW` slot OSP delegates
identically to prose. And the whole win is **contingent on faithful encoding of
external probes** — an OSP rewrite that drops a `WebFetch` is strictly worse than
prose.

> **win ≈ f(mechanism_fraction, 1 / model_capability)** — benchmark on the model
> tier you'll deploy; a frontier-model result measures OSP's worst corner.
