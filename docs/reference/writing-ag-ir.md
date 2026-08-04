# Writing an AG-IR

A comprehensive, standalone guide to hand-authoring the **AG-IR** — the typed
intermediate representation Sigil lowers into a runnable object-spatial agent.
Read this whether you are a person writing an `.agir` by hand or a frontier model
authoring one against the compile oracle.

This guide describes the **fix-forward compiler** (the one shipped on the
`compiler-fix-forward` line). If a claim here disagrees with the two legacy
authoring contracts (`contracts/agir-template.md`, `contracts/writing-agir/SKILL.md`),
those predate the fix-forward rearchitecture and this guide wins.

---

## 1. What an AG-IR is, and why it exists

You are the front-end of a compiler. Your output is one YAML document — an
`.agir` — that the mechanical back-end lowers, node for node, into a runnable Jac
program. No model reads your AG-IR at run time; a model only fills the specific
`GEN-*` slots you place. Everything else is code.

The point of the AG-IR is that **it removes the model's discretion**. In a
prompt-based harness a skill is advice the model may follow. Here every mandatory
step becomes a node the run *must visit*, every prohibition becomes a property of
a node, and every verification becomes a code gate with a typed verdict. Your job
is to build that structure faithfully — not to improve the task, not to summarize
it.

The single test that governs everything: **if the source material were deleted,
would the AG-IR still lower to a working agent that does the task?** If the answer
depends on prose that lives only outside the IR, that prose has to move *into* the
IR — as a tool body, a knowledge item, or a node's `doc`.

---

## 2. The mental model: fix-forward, not fail-loud

This is the one thing to internalize, and the one thing the legacy contracts get
wrong. The gates **diagnose**; they do not veto. The compiler's job is not to
reject your draft — it is to lower the most faithful runnable agent it can, and
tell you exactly where it had to compromise.

Concretely, when you hand the compiler an AG-IR it runs a ladder:

1. **Mechanical autofix** — pure code, re-checked through the compile oracle. It
   mints a missing lane, inlines a sibling file a node reads, re-owns a dead code
   node to a model slot, adopts an agreeing carry type. A fix that fails to
   compile is dropped; the original is kept.
2. **Scoped repair** — a bounded model pass over just the failing view.
3. **Faithful degradation** — when it can't fix, it takes the weaker-but-real
   lowering and *records it*.
4. **A typed report** — everything left over rides `findings`, each with a
   severity and the exact action to take.

A lift **fails** only when no runnable module exists at all — the compile oracle
still rejects the IR after the whole ladder. Everything runnable persists, with
its findings attached. The four outcomes:

| status | meaning |
|---|---|
| `clean` | runnable; nothing found, nothing needed |
| `fixed` | runnable and clean, but only because autofixes/repairs landed |
| `degraded` | runnable, with residual findings riding the report |
| `failed` | no runnable module — the only real failure |

What this means for you as an author: **you do not have to be perfect, you have
to be lowerable — and then faithful.** Aim for `clean`. Accept `fixed`. Read
every finding on a `degraded` result, because a degradation is the compiler
telling you it kept the agent alive by making it weaker than you wrote it.

---

## 3. The document skeleton

An AG-IR is one YAML document with a small, fixed set of top-level keys. Here is
the whole shape, in the order it reads best:

```yaml
---
name: <slug>                # frontmatter — becomes the skill signature
description: <trigger>      # "use when …" — becomes the MCP tool description
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}                   # named object/enum types (usually empty)

knowledge:                  # embodied reference material (optional)
  <key>:
    resident_on: [<node id>, ...]
    template: |             # or: pattern / body / value — content, verbatim
      ...

tools:                      # deterministic code tools (optional)
  <name>:
    sig: "(a, b) -> t"
    surface: SENSE | ACT·artifact
    serves: [<node id>, ...]   # or bind 1:1 by naming the tool == node id
    doc: "..."
    body: |                 # python, OR:
      def <name>(a, b): ...
    # command: "pandoc {in} -o {out}"   # a shell tool instead of a body

walker:
  name: <CamelCaseAgent>
  carries:                  # the typed slots that flow through the run
    task:
      type: str
      role: input
    <lane>:
      type: <t>
      produced_by: <node id>

nodes:                      # the pipeline steps, in no required order here
  - id: <id>
    type: GEN-RAW | GEN-ENUM | GEN-FILL | GEN-EDIT | SENSE | ACT | CODE | ROUTE | TERMINAL
    owner: model | code
    reads:  [<lane>, ...]
    writes: [<lane>, ...]
    doc: "..."
    # op/tool/surface/traces_to as needed

edges:                      # REQUIRED — the visit order
  - {from: <id>, to: <id>, modality: mandatory}
```

Two keys are load-bearing and easy to forget:

- **`edges` is required.** Without edges the walker visits the first node and
  stops. The edges are the control flow — list them in visit order.
- **`walker.carries` is the dataflow.** Every value a node reads or writes is a
  carry. `role: input` means it is seeded from the invocation (the task, and any
  other invocation inputs); `produced_by: <node>` means a node writes it.

The rest of this guide is about filling `nodes`, `tools`, `knowledge`, and
`carries` correctly.

---

## 4. The node alphabet

Every node has a `type` and an `owner`. The type says what kind of work it is;
the owner says who does it — `model` (a slot the run fills with a generation) or
`code` (a function of its inputs, run for free, guaranteed by construction).

**Mind nodes — `owner: model`.** A model slot is *observable* but not guaranteed:
the model executes it, and you can read the result, but nothing forces it to be
correct. Use a model node only where the task genuinely needs a guess or open
generation.

| type | use it for |
|---|---|
| `GEN-ENUM` | choose from a fixed set — the tightest Mind form. "Classify the operation." |
| `GEN-FILL` | fill a typed object from context (schema-validated) |
| `GEN-EDIT` | mutate existing content, touching only what must change |
| `GEN-RAW` | free-form generation — reserve for genuinely open-ended output |

**Code nodes — `owner: code`.** A code node is *guaranteed by construction* — it
is a pure function of its inputs and cannot be skipped or done wrong. Prefer code
wherever the step is mechanical.

| type | use it for |
|---|---|
| `SENSE` | pull world-state in — read a file, grep, fetch. Idempotent. |
| `ACT` | push an effect out — write a file, emit the deliverable. Give it `surface: artifact` when it writes the deliverable. |
| `CODE` | a pure function of inputs — no guess, runs for free |

**Flow and boundary nodes.**

| type | use it for |
|---|---|
| `ROUTE` | a branch / applicability gate. `owner: code` when it consumes a decision that must be honored exactly (e.g. a human's answer). |
| `LOOP` | iterate until a condition (advanced — see the primitives contract) |
| `SPAWN` | fan out concurrent sub-runs (advanced) |
| `TERMINAL` | the single exit node; serializes the produced carries into the report |

The compiler emits `GEN-ENUM` / `GEN-FILL` / `GEN-RAW` / `GEN-EDIT` with a hyphen,
and `ACT` / `SENSE` / `CODE` / `ROUTE` / `TERMINAL` bare — write them exactly as
shown. Every AG-IR ends in exactly one `TERMINAL`.

**The gated-vs-slotted rule.** For any obligation, prefer `owner: code` — it is a
gate, guaranteed. A model slot is only observable. Reserve slots for real
judgment. A step realized by a code node is `gated`; the same step folded into a
model slot is `slotted` (observable), and several steps folded into *one* slot is
`monolithic` — the weakest realization, no better than prose. The G5 gate reports
monolithic realizations so you can split them.

---

## 5. Carries and dataflow (the lanes)

Every value that flows through the run is a **carry** — a typed slot on the
walker. A node's `reads` and `writes` name carries. There are two kinds:

- **Input carries** — `role: input`. Seeded from the invocation. `task` (the user
  request, verbatim) is always one; declare others (`context`, a config value)
  when the run needs them.
- **Produced carries** — `produced_by: <node id>`. Written by exactly one node,
  read by later ones.

Two rules make the dataflow legible:

1. **Every read must have a lane.** A node that reads `rows` requires a `rows`
   carry (or `knowledge` key, or `task`). *Autofix note:* if a read names a file
   that sits next to the source (`templates/viewer.html`), the compiler inlines
   that file as knowledge; if it names nothing resolvable, the compiler mints an
   input carry so the reference is at least seedable. Both are recorded. **Declare
   the lane yourself** — relying on the mint means the value arrives as an empty
   seed, not a produced result.

2. **Type your carries — especially across a model→code boundary.** An untyped
   carry lowers the walker field to `any`, and the compile oracle is then *blind*
   to a type mismatch. If a model slot writes a carry and a code tool then reads
   it, the tool's parameter type is ground truth: type the carry to match. This is
   the G9 gate, and an untyped model→code carry is an **error** (a runtime crash
   with a green compile), not a warning.

Types are `str`, `int`, `float`, `bool`, `list`, `dict`, `list[str]`, `any`, a
`path`, or a name you define under top-level `types:`. When in doubt about a
scalar, `str` is safe; for structured data flowing into code, match the tool.

---

## 6. Tools — the embodied code

A code node (`SENSE` / `ACT` / `CODE`) lowers *through a tool*. A tool carries the
actual implementation, one of two forms:

- **`body: |`** — a self-contained Python function whose name matches the tool
  name and whose signature matches `sig`.
- **`command: "..."`** — a shell command (pandoc, qpdf, soffice, …), with
  `{placeholders}` for its inputs.

```yaml
tools:
  assemble_plan:
    sig: "(header_md, tasks_md) -> str"
    surface: ACT·artifact
    doc: "Join the header and task sections into one document."
    body: |
      def assemble_plan(header_md: str, tasks_md: str) -> str:
          return (header_md or "").rstrip() + "\n\n" + (tasks_md or "").strip() + "\n"
```

Bind a tool to a node either by listing the node in the tool's `serves:`, or by
naming the tool exactly the node's `op`/`tool` (as in §11's example). `surface` is
`SENSE` for reads or `ACT·artifact` for writes.

### The builtin tool library — bind by name, skip the body

The compiler ships a standard tool library (`toolib`). If your node's work is one
of these common operations, **declare a tool with that exact name and no body** —
the compiler splices the standard implementation at lower time. Writing your own
body for these is wasted effort, and (in the legacy contracts' mental model) used
to get flagged as a "prose pointer"; the fix-forward gates know these names are
the ladder's own rung and skip them.

| builtin | signature | surface |
|---|---|---|
| `read_file` | `(path) -> str` | SENSE |
| `list_dir` | `(path) -> str` | SENSE |
| `glob_files` | `(pattern, path) -> str` | SENSE |
| `grep` | `(pattern, path) -> str` | SENSE |
| `write_file` | `(path, content) -> str` | ACT·artifact |
| `run_command` | `(command) -> str` | ACT·artifact |
| `http_get` | `(url) -> str` | SENSE |

```yaml
tools:
  write_file:            # no body — the compiler supplies it
    surface: ACT·artifact
    serves: [emit_report]
```

Also bind any **registered MCP tool** by its exact name, as a `SENSE`/`ACT` node —
do not re-script it.

---

## 7. The binding rules you must know

The single most common way a hand-authored AG-IR runs green but produces garbage
is a **misbound argument** — the tool got called with the wrong value in the wrong
slot. The compiler binds a tool's parameters to carries by three rules, in order.
Author to them.

1. **By name.** A parameter named `rows` binds to a carry named `rows`.

2. **By role (content vs path).** For a write tool like `write_file(path, content)`
   or `save(content, path)`, the compiler binds by *role*, not position:
   - a **content** parameter (`content`, `text`, `data`, `body`, `code`, `source`,
     `markdown`, `html`, `payload`) takes the node's first non-pathish read carry;
   - a **path** parameter (`path`, `out`, `dest`, `filename`, `file`, …) takes a
     pathish read carry (one whose name ends `_path`/`_file`/… or is `path`) if
     one exists.

   This is why `save_plan(plan_md, path)` reading only `[plan_md]` works: `plan_md`
   is content, `path` is a destination with no carry — see the next rule.

3. **The task filename fallback.** A path parameter with no carry to bind is
   resolved from the **task string**:
   - an **ACT** (write) path → `_outname(self.task)` — the filename following a
     save/output/write verb ("save as `out.csv`"), else the first bare filename;
   - a **SENSE** (read) path → `_inname(self.task)` — the filename following a
     read/open/load/parse/clean/from verb ("clean `data.csv`"), skipping any
     save-claimed name.

   So for the task *"clean data.csv and save as out.csv"*, a SENSE reader binds
   `data.csv` and an ACT writer binds `out.csv`, automatically. You do not declare
   a carry for either filename — the task carries them.

The practical takeaway: **name your content and path carries clearly** (a content
carry is a plain noun like `plan_md`; a path carry ends in `_path`/`_file`), and
let input/output filenames that live only in the task fall to the fallback. Do not
hand a write tool a single positional carry and hope — that is the misbinding the
role rule exists to prevent.

---

## 8. Knowledge — embody, never point

Reference material the skill supplies (a required output format, a template, a set
of rules, a code scaffold) goes in `knowledge`, embodied **verbatim**, resident on
the nodes that use it:

```yaml
knowledge:
  header_format:
    resident_on: [draft_header]
    template: |
      Every plan MUST open with exactly this header:

      # [Feature Name] Implementation Plan
      **Goal:** [one sentence]
      ...
```

The content field can be `template`, `pattern`, `body`, or `value` — all are
rendered into the resident node's slot prompt in full. The rule is the same
"delete the source" test from §1: knowledge must carry its content, never "see the
section above" or "follow the format in FORMS.md".

*Autofix note:* if a knowledge body *is* a pointer ("See FORMS.md") and `FORMS.md`
sits in the skill directory, the compiler inlines the file. But this only works
when the file is present at compile time — **embody it yourself** and the agent is
self-contained regardless.

---

## 9. Realizing obligations faithfully

Translate the source's obligations into structure, each in its strongest form:

- **A step** ("summarize the data") → a node. Give it its own node when it is its
  own obligation; do not fold three steps into one `GEN-RAW` slot (that is the
  monolithic realization G5 flags).

- **A prohibition** ("never modify the input", "always lowercase before counting")
  is *not a step* — it is a property the run must have. Realize it, in order of
  preference: (1) **in code**, inside the tool body where it cannot be skipped;
  (2) **by construction**, e.g. a read-only read, and say so in the node's `doc`;
  (3) **in the `doc`** of every model node it constrains — the compiler folds
  `doc` into the slot's prompt, which is where a prohibition binds at run time.

- **A verification** ("check the output has a header row") → a `SENSE` code node
  that returns a `bool`, written to a carry. A code gate is guaranteed; a model
  "please double-check" is not.

- **A human-in-the-loop gate** ("confirm before proceeding") → an `owner: code`
  `ROUTE` that consumes the human's answer with explicit guards. A model-owned
  route that reads a human's "not approved" and decides for itself is the G6
  failure — make it `owner: code`.

**The hollow-node trap.** An `owner: code` `CODE`/`SENSE`/`ACT` node with *no tool
serving it and no inline body* has nothing to lower to. The mechanical half writes
a marker comment: the walker visits the station and does nothing. The fix-forward
compiler catches this and **re-owns the node to a `GEN-RAW` model slot** so the
step at least executes — but that is a *degradation* it records, not a silent
pass. Avoid it: bind a tool (a body, a `command`, or a builtin name) to every code
node, or make it a model node deliberately.

---

## 10. The gate battery — feedback, not veto

Each gate answers one question about your draft. Read them as a checklist, not a
tribunal. Only G4 can make a lift `failed`; the rest attach findings.

| gate | question | severity of a residual finding |
|---|---|---|
| **G1** standalone | is every tool/knowledge embodied (not a pointer)? | warn |
| **G3** artifact boundary | does every mandatory output actually get written by an ACT? | error |
| **G4** compile oracle | does the IR lower and type-check with zero errors? | **fatal** (the only one) |
| **G5** struct-cov | is each mandatory rule realized by a node (not monolithic/missing)? | warn |
| **G6** HIL | are human-feedback routes `owner: code` with guards? | error |
| **G7** env | do tool imports/binaries resolve in this runtime? | warn (advisory; `SIGIL_G7_HARD=1` to harden) |
| **G8** concurrency | is any claimed parallelism real? | error (false parallelism); opportunities are advisory |
| **G9** type unification | do carry types match the tools that consume them? | error |

`error` findings are runtime crashes or violated mandates riding a green compile —
fix them. `warn` findings are faithfulness/quality notes — worth addressing, but
the agent runs. `fatal` (G4) means there is no agent.

---

## 11. The authoring loop

Draft, then run the compile oracle, then fix exactly what it names:

```bash
sigil gate agent.ir <name>
```

This lowers your IR and type-checks the result — the same oracle the pipeline
uses. It exits nonzero while the IR is broken and prints the exact diagnostic
(errors first). The loop:

1. **Draft** the AG-IR.
2. **Gate** it. Read the *first* error — the compiler tails to real `error[E…]`
   blocks, so the first block is usually the cause.
3. **Fix only what the diagnostic requires.** Do not add, drop, reword, or
   re-modalize any step, tool, or rule while fixing a compile error — this IR is a
   compiled skill, and changing its meaning is worse than failing to compile.
4. **Repeat** until it prints `gate: ok`.
5. Then read the **findings** (G1/G3/G5/G6/G7/G8/G9). Resolve the `error`s; decide
   on the `warn`s. Aim to land on `clean` or `fixed`, not `degraded`.

Here is a complete, gate-clean example — a plan writer that drafts with two model
slots, then assembles / verifies / saves with code tools. Note that `save` reads
only `[plan_md]`, so its `path` parameter falls to `_outname(self.task)` (§7):

```yaml
---
name: writing_plans
description: Create a detailed implementation plan with bite-sized TDD tasks.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}

knowledge:
  task_format:
    resident_on: [write_tasks]
    template: |
      Break the work into bite-sized tasks. Each task is one component; each
      step inside it is one 2-5 minute action. Exact file paths always; complete
      code, never "add validation"; exact commands with expected output.

tools:
  assemble_plan:
    sig: "(header_md, tasks_md) -> str"
    surface: ACT·artifact
    doc: "Join the header and the task sections into one plan document."
    body: |
      def assemble_plan(header_md: str, tasks_md: str) -> str:
          return (header_md or "").rstrip() + "\n\n" + (tasks_md or "").strip() + "\n"
  verify_has_tasks:
    sig: "(plan_md) -> bool"
    surface: SENSE
    doc: "True when the plan actually contains task sections with code."
    body: |
      def verify_has_tasks(plan_md: str) -> bool:
          import re
          text = plan_md or ""
          return bool(re.search(r'^###\s+Task\s', text, re.M)) and "```" in text
  save_plan:
    sig: "(plan_md, path) -> str"
    surface: ACT·artifact
    doc: "Write the finished plan to a markdown file and return its path."
    body: |
      def save_plan(plan_md: str, path: str) -> str:
          import os
          d = os.path.dirname(path)
          if d:
              os.makedirs(d, exist_ok=True)
          with open(path, "w", encoding="utf-8") as f:
              f.write(plan_md or "")
          return path

walker:
  name: WritingPlans
  carries:
    task:      { type: str,  role: input }
    header_md: { type: str,  produced_by: draft_header }
    tasks_md:  { type: str,  produced_by: write_tasks }
    plan_md:   { type: str,  produced_by: assemble }
    plan_ok:   { type: bool, produced_by: verify }
    plan_file: { type: str,  produced_by: save }

nodes:
  - id: draft_header
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [header_md]
    doc: "Write the plan's header: a real feature name, a one-sentence goal, a 2-3 sentence architecture, and the tech stack. Output only the header markdown."
  - id: write_tasks
    type: GEN-RAW
    owner: model
    reads: [task, header_md]
    writes: [tasks_md]
    doc: "Write the bite-sized, test-driven task sections. Follow the task format exactly. Output only the task markdown, no header."
  - id: assemble
    type: ACT
    owner: code
    op: assemble_plan
    tool: assemble_plan
    reads: [header_md, tasks_md]
    writes: [plan_md]
  - id: verify
    type: SENSE
    owner: code
    op: verify_has_tasks
    tool: verify_has_tasks
    reads: [plan_md]
    writes: [plan_ok]
  - id: save
    type: ACT
    owner: code
    op: save_plan
    tool: save_plan
    reads: [plan_md]
    writes: [plan_file]
  - id: done
    type: TERMINAL

edges:
  - {from: draft_header, to: write_tasks, modality: mandatory}
  - {from: write_tasks,  to: assemble,    modality: mandatory}
  - {from: assemble,     to: verify,      modality: mandatory}
  - {from: verify,       to: save,        modality: mandatory}
  - {from: save,         to: done,        modality: mandatory}
```

---

## 12. Common failure modes → fixes

| symptom | cause | fix |
|---|---|---|
| Walker stops after the first node | no `edges` | add the edge chain in visit order |
| `lowered module has no nodes` | empty/unparseable YAML, or an unquoted `:` in a value | quote the value or use a `body: |` block scalar |
| A code node "does nothing" (marker comment) | `owner: code` node with no tool/body (**hollow**) | bind a tool (body/command/builtin name) or make it a model node |
| 0-byte file named after its own content | content carry misbound to a `path` param | name content and path carries by role (§7); don't pass one positional carry |
| First node crashes: `'path' must be a non-empty string` | a SENSE read path with no source | let it fall to `_inname(self.task)` (name the file in the task), or add an input carry |
| `node reads 'X' which is neither a carry nor knowledge` | dangling read | declare the carry (or knowledge key), or let §5's autofix mint it and accept the seed |
| G9 error: carry crosses model→code untyped | a `GEN-*` writes a carry a tool reads, untyped | set the carry `type` to the tool parameter's type |
| G5: rule realized MONOLITHICALLY | several obligations folded into one slot | split into one node per obligation, or add a code gate |
| G1: knowledge is a prose-pointer | `body: "see FORMS.md"` | embody the referenced content verbatim |
| G3: IO mandate has no embodied write | a deliverable authored into a carry, never written | add an ACT node served by a write tool (or a builtin `write_file`) |

---

## 13. Where to go next

- **`docs/reference/agir-cookbook/`** — a small library of gate-clean golden
  AG-IRs, one per archetype (a code pipeline, a model-judgment pipeline, a
  SENSE→transform→ACT read/writer, an HIL gate, a tool-belt unit, a
  knowledge-heavy skill). Each is a worked example you can copy and adapt, and
  each is registrable directly: `sigil register-skill <file>.agir agir`.
- **`contracts/agir-primitives.md`** — the full node-type alphabet, including the
  advanced flow primitives (`LOOP`, `SPAWN`, `CALL`) this guide only sketches.
- **`examples/writing-plans/`** — the hand-authored AG-IR this guide's §11 example
  is drawn from, with its compiled `.jac` and a run trace.
