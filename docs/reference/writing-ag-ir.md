# Writing an AG-IR

A comprehensive, standalone guide to hand-authoring the **AG-IR** — the Agent
Intermediate Representation Sigil lowers into a runnable object-spatial agent. An
AG-IR is a program in the **Agent Instruction Set (AIS)**, as defined by the SIGIL
paper (arXiv 2607.27309): thirteen opcodes, where the opcode decides whether code
or a model executes the step.
Read this whether you are a person writing an `.agir` by hand or a frontier model
authoring one against the compile oracle.

This guide follows the SIGIL paper's AIS and the normative specification in
`docs/reference/ais-spec.md`. If a claim here disagrees with the legacy authoring
contracts under `contracts/`, those predate the paper alignment and this guide
wins.

---

## 1. What an AG-IR is, and why it exists

You are the front-end of a compiler. Your output is one YAML document — an
`.agir` — that the mechanical back-end lowers, node for node, into a runnable Jac
program. No model reads your AG-IR at run time; a model only fills the semantic
instructions (`SELECT` / `EXTRACT` / `MUTATE` / `GENERATE`) and the `DELEGATE`d
subtasks you place. Everything else is code.

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

This is the one thing to internalize. The gates **diagnose first**: the compiler's
job is to repair what it can, lower the most faithful runnable agent it can, and
tell you exactly where it had to compromise. What it will not do is ship an agent
whose *errors* survived the repair ladder.

Concretely, when you hand the compiler an AG-IR it runs a ladder:

1. **Mechanical autofix** — pure code, re-checked through the compile oracle. It
   mints a missing lane, inlines a sibling file a node reads, turns a dead
   `COMPUTE` into a `GENERATE`, adopts an agreeing carry type. A fix that fails to
   compile is dropped; the original is kept.
2. **Scoped repair** — a bounded model pass over just the failing view.
3. **Faithful degradation** — when it can't fix, it takes the weaker-but-real
   lowering and *records it*.
4. **A typed report** — everything left over rides `findings`, each with a
   severity and the exact action to take.

A lift **fails** when no runnable module exists — the compile oracle still
rejects the IR after the whole ladder — or when an `error` finding remains after
it: an error is a runtime crash or a violated mandate, and an agent that carries
one is not shipped. Everything else persists, with its findings attached. The
four outcomes:

| status | meaning |
|---|---|
| `clean` | runnable; nothing found, nothing needed |
| `fixed` | runnable and clean, but only because autofixes/repairs landed |
| `degraded` | runnable, with residual *warnings* riding the report |
| `failed` | no runnable module, or an error the ladder could not repair |

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
agir_version: 0.2
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
    surface: OBSERVE | ACT·artifact
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

nodes:                      # the AIS instructions; the first one is the entry
  - id: <id>
    type: SELECT | EXTRACT | MUTATE | GENERATE | DELEGATE | COMPUTE | OBSERVE | ACT | BRANCH | LOOP | PARALLEL | CALL | RETURN
    reads:  [<lane>, ...]
    writes: [<lane>, ...]
    doc: "..."
    # op/tool/surface/autonomy/procedure/traces_to as needed

edges:                      # REQUIRED — the visit order
  - {from: <id>, to: <id>, modality: mandatory}

constraints:                # prohibitions and orderings the program must satisfy (optional)
  - {id: <id>, kind: forbid_flow, from: [<lane>], to: [<node id>], traces_to: [<rule>]}
  - {id: <id>, kind: require_before, before: <node id>, after: <node id>}
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

## 4. The instruction set

Every node is one AIS instruction, and its `type` — the opcode — decides who
executes it. There is no separate owner to choose: the semantic opcodes and
`DELEGATE` run on the model, everything else runs as code. (`owner:` may still
appear in older documents; the compiler derives it from the opcode.)

**Semantic instructions — the model produces the result.** A semantic step is
*observable* but not guaranteed: the model executes it, and you can read the
result, but nothing forces it to be correct. Use one only where the skill leaves
the result to judgment and supplies no implementation.

| type | use it for |
|---|---|
| `SELECT` | choose among a specified set of alternatives — the tightest semantic form. "Classify the operation." |
| `EXTRACT` | derive typed or structured information (a declared object) from semantic input |
| `MUTATE` | modify an existing value according to instructions, touching only what must change |
| `GENERATE` | produce new open-ended content — reserve for genuinely open-ended output |

**Delegated — a bounded subtask whose inner steps the skill leaves open.**

| type | use it for |
|---|---|
| `DELEGATE` | an adaptive activity the skill deliberately does not decompose ("explore the data until…", "iterate until the tests pass"). Give it its tools in `autonomy: {tools: [...]}`, its context in `reads`, and its output contract in `writes`/`output`. It runs as one tool-using agent loop. Never shred it into fixed steps. |

**Executable instructions — a supplied implementation runs.** An executable step
is *guaranteed by construction*: it runs code and cannot be skipped or done
wrong. Prefer one wherever the skill or its resources supply an implementation,
or the step is mechanical.

| type | use it for |
|---|---|
| `OBSERVE` | obtain a value from outside — read a file, grep, fetch, *check*. Idempotent. |
| `ACT` | cause an externally visible effect — write a file, emit the deliverable. Give it `surface: artifact` when it writes the deliverable. |
| `COMPUTE` | a local computation — a pure function of its inputs, no guess |

**Control and termination.**

| type | use it for |
|---|---|
| `BRANCH` | select an explicit successor from guards over a value an earlier instruction produced. A choice that needs judgment is a `SELECT` whose result the `BRANCH` tests. |
| `LOOP` | repeat an explicitly represented region, with a verdict carry and a cap |
| `PARALLEL` | run independent regions concurrently (advanced) |
| `CALL` | invoke another named procedure: `procedure: <tool or compiled skill>` |
| `RETURN` | the single exit; serializes the produced carries into the report |

Write the opcodes exactly as shown. Every AG-IR ends in exactly one `RETURN`.

**The gated-vs-slotted rule.** For any obligation, prefer an executable or
control instruction — it is a gate, guaranteed. A semantic step is only
observable. Reserve semantic steps for real judgment. A step realized by code is
`gated`; the same step given its own semantic instruction is `slotted`
(observable), and several steps folded into *one* semantic instruction is
`monolithic` — the weakest realization, no better than prose. The G2 gate reports
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
   the G4 gate, and an untyped model→code carry is an **error** (a runtime crash
   with a green compile), not a warning.

Types are `str`, `int`, `float`, `bool`, `list`, `dict`, `list[str]`, `any`, a
`path`, or a name you define under top-level `types:`. When in doubt about a
scalar, `str` is safe; for structured data flowing into code, match the tool.

---

## 6. Tools — the embodied code

An executable node (`OBSERVE` / `ACT` / `COMPUTE`) lowers *through a tool*. A tool carries the
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
`OBSERVE` for reads or `ACT·artifact` for writes.

### The builtin tool library — bind by name, skip the body

The compiler ships a standard tool library (`toolib`). If your node's work is one
of these common operations, **declare a tool with that exact name and no body** —
the compiler splices the standard implementation at lower time. Writing your own
body for these is wasted effort, and (in the legacy contracts' mental model) used
to get flagged as a "prose pointer"; the fix-forward gates know these names are
the ladder's own rung and skip them.

| builtin | signature | surface |
|---|---|---|
| `read_file` | `(path) -> str` | OBSERVE |
| `list_dir` | `(path) -> str` | OBSERVE |
| `glob_files` | `(pattern, path) -> str` | OBSERVE |
| `grep` | `(pattern, path) -> str` | OBSERVE |
| `write_file` | `(path, content) -> str` | ACT·artifact |
| `run_command` | `(command) -> str` | ACT·artifact |
| `http_get` | `(url) -> str` | OBSERVE |

```yaml
tools:
  write_file:            # no body — the compiler supplies it
    surface: ACT·artifact
    serves: [emit_report]
```

Also bind any **registered MCP tool** by its exact name, as an `OBSERVE`/`ACT` node —
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
   - an **OBSERVE** (read) path → `_inname(self.task)` — the filename following a
     read/open/load/parse/clean/from verb ("clean `data.csv`"), skipping any
     save-claimed name.

   So for the task *"clean data.csv and save as out.csv"*, an OBSERVE reader binds
   `data.csv` and an ACT writer binds `out.csv`, automatically. You do not declare
   a carry for either filename — the task carries them.

The practical takeaway: **name your content and path carries clearly** (a content
carry is a plain noun like `plan_md`; a path carry ends in `_path`/`_file`), and
let input/output filenames that live only in the task fall to the fallback. Do not
hand a write tool a single positional carry and hope — that is the misbinding the
role rule exists to prevent.

**Never name a carry with a bare tool-parameter name** — `path`, `content`, `text`,
`data`, `file`, `out`, `dest`. Binding rule 1 is by name, so a carry literally
named `path` *hijacks* the `path` parameter of every tool that has one, even when
that carry is the wrong path. A `grep` step whose search directory is a carry named
`path` will silently steer a later `write_file`'s destination to the search
directory instead of the task's output file — a green compile that writes nowhere.
Qualify the name to its role: `search_path`, `input_text`, `csv_row`, `out_file`.
The qualified name still binds correctly (`search_path` is pathish, so it
role-binds a `path` parameter) without colliding.

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

- **A step** ("summarize the data") → an instruction. Give it its own instruction
  when it is its own obligation; do not fold three steps into one `GENERATE`
  (that is the monolithic realization G2 flags).

- **A prohibition on what flows where** ("never place PHI in logs", "never send
  the raw record to the third party") → a `forbid_flow` **constraint**: the
  carries holding the prohibited content in `from`, the instructions that must
  never receive it in `to`, and any instruction that removes the content (a
  redaction step) in `through`. The compiler checks every represented path; a
  violation is an `error`. Then build the graph so no such path exists.

- **An ordering** ("check the BAA before transmitting") → put the check on every
  path to the later step, and state it as a `require_before` constraint so the
  compiler verifies it.

- **Any other prohibition** ("never modify the input", "always lowercase before
  counting") is *not a step* — it is a property the run must have. Realize it, in
  order of preference: (1) **in code**, inside the tool body where it cannot be
  skipped; (2) **by construction**, e.g. a read-only read, and say so in the
  node's `doc`; (3) **in the `doc`** of every semantic instruction it constrains —
  the compiler folds `doc` into the model call's prompt, which is where a
  prohibition binds at run time.

- **A verification** ("check the output has a header row") → an `OBSERVE` that
  returns a `bool`, written to a carry a `BRANCH` tests. A code gate is
  guaranteed; a model "please double-check" is not.

- **A human-in-the-loop gate** ("confirm before proceeding") → a `BRANCH` whose
  guards test a carry a `COMPUTE`/`OBSERVE` produced from the human's answer. A
  `SELECT` that reads a human's "not approved" and decides for itself is the G3
  failure — the human's words must bind the transition directly.

- **An open-ended activity** ("explore…", "iterate until…") → one `DELEGATE` with
  its tools. Splitting it into fixed steps destroys the adaptation the skill asked
  for (G3).

**The hollow-node trap.** A `COMPUTE`/`OBSERVE`/`ACT` with *no tool serving it and
no inline body* has nothing to lower to. The mechanical half writes a marker
comment: the walker visits the station and does nothing. The compiler catches
this and **turns the node into a `GENERATE`** so the step at least executes — but
that is a *degradation* it records, not a silent pass. Avoid it: bind a tool (a
body, a `command`, or a builtin name) to every executable node, or make it a
semantic instruction deliberately.

---

## 10. The gate battery — the paper's validation checks

Each gate answers one question about your draft, filed under the check of the
SIGIL paper it implements (G1 source grounding, G2 requirement realization, G3
execution preservation, G4 type and data flow, G5 reference resolution and
placement, G6 binding and control-flow validity). The compile oracle runs after
them.

| gate | question | severity of a residual finding |
|---|---|---|
| **G1_TRACE** | does any instruction claim far more rules than it can realize? | warn |
| **G2** | is each mandatory rule realized by its own instruction (not monolithic/missing)? | warn |
| **G2_ARTIFACT** | does every mandatory output actually get written by an ACT? | error |
| **G2_OVERLOAD** | does any one semantic instruction fold more than six mandates into one call? | error |
| **G2_FLOW** / **G2_ORDER** | do the `constraints` hold on every represented path? | error |
| **G3_HIL** | does every human-feedback BRANCH test a code-produced carry with guards? | error |
| **G4** | do carry types match the tools that consume them? — and is every node reachable from the entry? | error |
| **G4_INPUT** | is every external input a declared carry, not mined from the task sentence? | error |
| **G5** | is every tool/knowledge item embodied (not a pointer)? | warn |
| **G5_BLOAT** | does a model call's prompt carry the surrounding document rather than its own mandate? | warn |
| **G6_ENV** | do tool imports/binaries resolve in this runtime? | warn |
| **G6_PAR** | is any claimed parallelism real? | error (false parallelism); opportunities are advisory |
| **COMPILE** | does the IR lower and type-check with zero errors? | **fatal** |

`error` findings are runtime crashes or violated mandates riding a green compile —
the lift fails if one survives the repair ladder, so fix them. `warn` findings are
faithfulness/quality notes — worth addressing, but the agent runs. `fatal`
(COMPILE) means there is no agent.

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
5. Then read the **findings** (G1–G6). Resolve every `error` — one that
   survives fails the lift; decide on the `warn`s. Aim to land on `clean` or
   `fixed`, not `degraded`.

Here is a complete, gate-clean example — a plan writer that drafts with two
`GENERATE` instructions, then assembles / verifies / saves with code tools. Note that `save` reads
only `[plan_md]`, so its `path` parameter falls to `_outname(self.task)` (§7):

```yaml
---
name: writing_plans
description: Create a detailed implementation plan with bite-sized TDD tasks.
---
agir_version: 0.2
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
    surface: OBSERVE
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
    type: GENERATE
    reads: [task]
    writes: [header_md]
    doc: "Write the plan's header: a real feature name, a one-sentence goal, a 2-3 sentence architecture, and the tech stack. Output only the header markdown."
  - id: write_tasks
    type: GENERATE
    reads: [task, header_md]
    writes: [tasks_md]
    doc: "Write the bite-sized, test-driven task sections. Follow the task format exactly. Output only the task markdown, no header."
  - id: assemble
    type: ACT
    op: assemble_plan
    tool: assemble_plan
    reads: [header_md, tasks_md]
    writes: [plan_md]
  - id: verify
    type: OBSERVE
    op: verify_has_tasks
    tool: verify_has_tasks
    reads: [plan_md]
    writes: [plan_ok]
  - id: save
    type: ACT
    op: save_plan
    tool: save_plan
    reads: [plan_md]
    writes: [plan_file]
  - id: done
    type: RETURN

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
| An executable node "does nothing" (marker comment) | `COMPUTE`/`OBSERVE`/`ACT` with no tool/body (**hollow**) | bind a tool (body/command/builtin name) or make it a semantic instruction |
| 0-byte file named after its own content | content carry misbound to a `path` param | name content and path carries by role (§7); don't pass one positional carry |
| First node crashes: `'path' must be a non-empty string` | an OBSERVE read path with no source | let it fall to `_inname(self.task)` (name the file in the task), or add an input carry |
| `node reads 'X' which is neither a carry nor knowledge` | dangling read | declare the carry (or knowledge key), or let §5's autofix mint it and accept the seed |
| G4 error: carry crosses model→code untyped | a semantic instruction writes a carry a tool reads, untyped | set the carry `type` to the tool parameter's type |
| G2: rule realized MONOLITHICALLY | several obligations folded into one semantic instruction | split into one instruction per obligation, or add a code gate |
| G5: knowledge is a prose-pointer | `body: "see FORMS.md"` | embody the referenced content verbatim |
| G2_ARTIFACT: IO mandate has no embodied write | a deliverable authored into a carry, never written | add an ACT served by a write tool (or a builtin `write_file`) |
| G2_FLOW: prohibited flow reachable | a constrained value reaches a forbidden sink | remove the read, or route it through a step listed in `through` |

---

## 13. Where to go next

- **`docs/reference/agir-cookbook/`** — a small library of gate-clean golden
  AG-IRs, one per archetype (a code pipeline, a model-judgment pipeline, an
  OBSERVE→transform→ACT read/writer, an HIL gate, a tool-belt unit, a
  knowledge-heavy skill). Each is a worked example you can copy and adapt, and
  each is registrable directly: `sigil register-skill <file>.agir agir`.
- **`docs/reference/ais-spec.md`** — the normative AIS specification, including
  the advanced control instructions (`LOOP`, `PARALLEL`, `CALL`) this guide only
  sketches.
- **`examples/writing-plans/`** — the hand-authored AG-IR this guide's §11 example
  is drawn from, with its compiled `.jac` and a run trace.
