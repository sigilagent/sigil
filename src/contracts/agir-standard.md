# AG-IR Primitive Standard

The contract every AG-IR primitive obeys, and the rule the transpiler uses to lower
it. Standardizing this is what makes the transpile **deterministic and faithful**:
each primitive has a fixed set of settable fields (params / inputs / outputs), and
the three flows (OSP control, Data, Context) join nodes by fixed rules. The
transpiler lowers a node purely from its `type` + these fields — never ad-hoc.

---

## 0. Common node schema

Every node, regardless of family, has:

| field | meaning | settable |
|---|---|---|
| `id` | unique node id (also the walker-ability/arch name) | yes |
| `type` | one of the primitives below | yes |
| `owner` | `model` (cognition) or `code` (mechanism) | yes |
| `reads` | ordered list of **inputs** — carry names and/or knowledge keys | yes |
| `writes` | ordered list of **outputs** — carry names this node produces | yes |
| `doc` / `sem` | the node's semantic prompt (model nodes) | yes |
| `tool` / `serves` | binds a Boundary/Code node to a tool (mechanism) | yes |
| `autonomy.tools` | tool list a model node may ReAct over | optional |

**Lowering invariant (all nodes):** a node reads its `reads` (bound per §4), does its
type-specific work, assigns each `writes[i]` to `self.<carry>`, then emits OSP flow
(§3). No node is ever a comment-only no-op.

---

## 1. Mind primitives (owner = model) — cognition

`GEN-RAW` (free-form), `GEN-FILL` (fill a typed object), `GEN-ENUM` (pick a member),
`GEN-EDIT` (diff over prior state).

**Settable:** `reads`, `writes`, `output` (return type), `sem`, `autonomy.tools`.

**Standard lowering:**
```
def <slot>(<reads bound to typed params>) -> <output|writes[0].type> by llm(tools=[<autonomy.tools>]);
sem <slot> = <doc>  ++  <every knowledge resident here, full body>  ++  <context-flow seeds>;
# in the node ability:
self.<writes[0]> = [str(_strip_fences(...)) if GEN-RAW+str]  <slot>(self.<reads...>);
```
- **Every `reads` entry is a typed parameter** — carries by their type, knowledge keys
  as `str`/typed globs. Never dropped to prose-only. (`task` is never dropped.)
- GEN-RAW whose `writes` includes a `script` + a data/artifact carry runs through its
  run-tool or `_exec_script` (§2 execute rule).

## 2. Boundary & Code primitives (owner = code) — mechanism

`SENSE` (pull world-state in), `ACT·artifact` (write the deliverable),
`ACT·workspace` (scratch effect), `CODE` (pure local code).

**Settable:** `reads`, `writes`, `tool` (or `serves` from the tool side), `body`.

**Standard lowering:** call the bound tool with carry-threaded args, assign the write:
```
self.<writes[0]> = [str(...) if str carry]  _<tool>(<reads bound per §4>);
```
- The bound tool = the IR tool whose `serves` lists this node id (or the node's `tool:`).
- **Tool bodies are synthesized runnable** by a *carrier* keyed on language:
  `.py`→inline, shell/CLI→`subprocess.run(["bash"/exe, …])`, `.js`→`node`, JSON/template→writer.
  Verbatim-snippet bodies (illustrative IR pseudocode) are wrapped param-driven, never pasted raw.
- ACT·artifact with no explicit tool and a `code`/content carry → `_write_artifact(self.<carry>, <app-path>)`.
- Save paths are **app-controlled**: basename into the run dir (never a model-chosen abs/nested path).

## 3. Flow primitives — control

`ROUTE` (branch), `LOOP` (bounded revise/retry), `CALL` (expand a sub-IR), `SPAWN` (fork subagents).

- **ROUTE:** `reads` an enum/predicate carry; each out-edge carries a `guard`. Lowers to
  `if <guard> { visit [-->][?:Target]; } elif … else { visit [-->][?:Default]; }`. A total
  `else` fallback is mandatory. An **owner=model** ROUTE (the branch needs a guess, not a
  code-decidable guard) instead lowers to byLLM LLM-guided traversal —
  `visit [-->] by llm(intent=<node doc>, incl_info={<read carries>})` — where `intent` (the
  node's semantic purpose) steers the choice and `incl_info` supplies the deciding state.
- **LOOP:** a `body` slot + `cap` (max iters, counter carry) + `verdict` (typed pass/fail
  carry) + a back-edge. Lowers to a guarded re-visit: advance when verdict passes or cap hit,
  else back-edge. Never an unconditional self-`++>`.
- **CALL:** `target` sub-IR → a `by llm()` sub-slot (or inlined sub-walker) that writes its carries.
- **SPAWN:** fan-out. Source = a `list[…]` `reads` carry (data-parallel: one sibling per
  element) or a literal `concurrency.spawn: […]`; `isolation`: private_write / shared_read.
  Lowers to `flow`/`wait` over `root spawn <Sib>` — a self-contained sibling walker that runs
  one worker slot (`<node>_worker`, its own scoped `by llm`) per sub-task — with results joined
  back into the `writes` carry (a `list`, or newline-joined for a `str` carry). Real
  parallelism for I/O-bound worker cognition (N finish in ~1× wall-clock); worktree isolation
  is the host runtime's job.

## 3T. TERMINAL

Serializes the **produced carries** into `report` — never a constant.
```
self.report = f"<agent>[{<key carry>}] artifact={self.artifact} <other carries>";
```

---

## 4. The three flows and how they join

A node's behavior is the join of three independent flows. Standard binding precedence
for any `reads` entry `p`:

1. **Data flow (carries).** If `p` is a carry → `self.<p>`. If `p` is a field of an
   object-typed carry → `self.<carry>.<p>` (e.g. `width` → `self.spec.width`). Carries are
   produced by a node's `writes` (`produced_by`) and consumed by a downstream node's `reads`.
   *Join rule:* downstream `reads` ∩ upstream `writes` = a data edge; bind to `self.<carry>`.
2. **Context flow (knowledge).** If `p` is a knowledge key → its `glob` constant, threaded
   as a typed param AND folded (full body) into the slot `sem`. Knowledge `resident_on: [nodes]`
   determines which slots receive it. *Join rule:* a node gets exactly the knowledge whose
   `resident_on` includes it — no more (scoping), no less (no dropping to prose-only).
3. **OSP control flow (edges).** `++>` edges define traversal; `visit` lowers them. Edge
   `modality` (mandatory / discretionary / forbidden) + `guard` decide conditional visits.
   *Join rule:* a guarded/discretionary edge lowers to `if <guard> { visit [?:T] }`, never an
   unconditional fan-out.

Args binding fallbacks after (1)/(2): a field of the `OpArgs` carry → `self.args.<p>`; else
the field's IR **default** (defaults are always emitted onto carry `has` declarations); else `None`.

---

## 5. What the transpiler guarantees from this standard

Given a node, the transpiler emits a body **purely** from `type` + `reads` + `writes` +
`tool/serves` + `guard` + knowledge `resident_on`:

- no comment-only no-ops (every node does its declared work) — closes gap #1
- guards lowered to conditional visits — closes gap #2
- `reads` threaded as params + knowledge as globs (full bodies) — closes gap #3
- TERMINAL serializes carries — closes gap #4
- tool bodies synthesized runnable by language carrier — closes gap #5
- LOOP/CALL/SPAWN lowered, not stubbed — closes gap #6
- carry defaults emitted — closes gap #7
- `writes` → `self.<carry>` assignment, typed-obj carries demoted to `any` for py returns — closes gap #8

---

## 6. Faithful-lowering requirements (co-design with the compiler)

The compiler was silently no-op'ing (`pass`), collapsing pipelines, and lowering only the
happy path — because the IR under-specified. These are the requirements an IR must satisfy so
the lowering is faithful *by construction*. Each is enforced by the compiler and must be
taught to the lowering agent.

### 6.1 Embodiment — never a silent no-op
Every tool must be lowerable to something that RUNS. The compiler applies an **embodiment
ladder**; author the IR so a tool lands as high as possible:

- **rung 0 — live-integration tool** (`read_slack`, `web_fetch`, `*_api`, `gh_get`): declare it
  as a live SENSE. Lowered to a real fetch or an honest "unavailable" sentinel — **never
  scripted** (a Python script can't read Slack).
- **rung 1 — embodied runnable body** (`::py::`/verbatim snippet): preferred; deterministic.
- **rung 2 — `command:` field** (`python scripts/office/unpack.py input.pptx unpacked/`): the IR
  MUST carry the real command; the compiler synthesizes a `subprocess` call (params threaded in
  sig order, literals like `unpacked/` kept). *This is the biggest recovered-faithfulness win.*
- **rung 3 — snippet-only** (last resort): lowered to a scoped GEN-RAW author-run loop, and
  **reported as a C1 faithfulness deviation.** If you see the compiler report a rung-3 fallback,
  embody the tool (add a `command:` or a body) — a snippet-only tool is IR debt.

**Rule:** a tool with neither body nor `command` nor a live-tool signature is IR debt; the
compiler will fall back + report it, never emit `pass`.

### 6.2 Operation = an ordered pipeline, not one tool
When several tools serve one operation (`unpack → add_slide → clean → pack` all `serves:
[EDIT_FROM_TEMPLATE]`), that operation IS a pipeline. Author them in the tools block **in
pipeline order**; the compiler runs them in sequence over the shared workspace and returns the
last. (It no longer emits one `if op==X: return tool()` per tool — which collapsed to dead code —
and never `raise`s on an unknown op.)

### 6.3 Params named to the carrier (binding)
A tool param binds to an `OpArgs` field / carry / command literal. Name params so the join is
unambiguous: `input*`→ the source, `output*`→ `output_spec.path`, `unpacked*`→ the working dir
literal. The compiler fuzzy-matches these, but exact/aligned names are faithful; mismatched
names bind to `None` and the step runs argless.

### 6.4 Authoring-that-executes → declare the runner (author-run atom)
A GEN-RAW node whose product is a *program the agent then runs* (`author pptxgenjs → node
program.js`) must give its run tool a `command: "<runner> <bare-file>"` (e.g. `node program.js`).
The compiler lowers this to **write-the-content → run → non-raising `{ok,error,out}`**, which an
author-loop can re-author from. (Fixes the `node <content>` and discarded-`fix()` bugs.) Do NOT
model this as a bundle-command (rung 2) — the arg is content, not a path.

### 6.5 Verify/QA — declare the grounding input
A verify/QA node must **declare the artifact it inspects** and its modality, so the compiler can
bind the *real* signal — not a proxy:
- **visual** (slide/poster/page render): declare the rendered images; lowered as byLLM `Image`
  inputs to the verify slot. (Was: the render *log* passed as text → blind "assume there are
  issues" QA.)
- **textual/structural** (a written file): declare the file/carry; lowered as its contents.
- `passed` must be a function of that grounding signal, and any verify LOOP must carry a **cap**
  + best-effort exit (no uncapped "repair until clean" → non-termination on weak models).

> The through-line: the IR must carry **step-order, the runnable command, the runner for
> authored programs, and the verify's grounding** — then robustness (non-raising exec, pipelines,
> author-loops, grounded verify, caps) is generated *by construction*, and no agent hand-adds it.
