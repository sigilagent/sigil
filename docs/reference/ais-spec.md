# The Agent Instruction Set (AIS)

The instruction set an agent program is written in — twelve opcodes over a typed carry
file, some executed by code and some by a model — and the rules a program, a
validator, and a backend must obey. This is the normative specification of what goes into
an AG-IR.

**Version 0.1 — Draft**

| | |
|---|---|
| **Abstract instruction set** | AIS — this document |
| **Concrete encoding** | AG-IR, a YAML document with the extension `.agir` |
| **Reference producer** | the Sigil AI front end (`src/compiler/ai/`) and hand authors |
| **Reference backend** | the Sigil mechanical compiler (`src/compiler/mechanical/compiler.jac`) |
| **Reference target** | Jac / Object-Spatial Programming — a `walker` over a `node` graph, with `by llm()` slots |

This document specifies the AIS: the instruction repertoire, the operand model, the
calling convention, the static and dynamic semantics, and the conformance rules for
programs and implementations. It is the normative counterpart to the tutorial
[writing-ag-ir.md](writing-ag-ir.md) and the design rationale in
[../../src/contracts/agir-primitives.md](../../src/contracts/agir-primitives.md); where
those disagree with this document on what an implementation must do, this document wins,
and where this document disagrees with the reference backend, §12.3 says which is at
fault.

---

## Contents

| | |
|---|---|
| **0** | [Conformance](#0-conformance) — roles, requirement keywords, determinism disclosure |
| **1** | [Overview and layering](#1-overview-and-layering) — where the AIS sits, and the five design axioms |
| **2** | [The abstract machine](#2-the-abstract-machine) — state, the two execution units, the execution cycle, guarantee classes |
| **3** | [Instruction encoding](#3-instruction-encoding) — the fields common to every instruction |
| **4** | [The instruction set](#4-the-instruction-set) — twelve opcodes: Mind, Boundary, Compute, Flow, Terminus |
| **5** | [The operand planes](#5-the-operand-planes) — data (carries), knowledge, control (edges), tools |
| **6** | [The type system](#6-the-type-system) |
| **7** | [The calling convention](#7-the-calling-convention) — how reads become arguments |
| **8** | [Module format](#8-module-format) — the AG-IR encoding and its sections |
| **9** | [Static semantics](#9-static-semantics) — well-formedness, executability, the validation battery, faithfulness |
| **10** | [Dynamic semantics](#10-dynamic-semantics) — faults, error routing, deviations, budgets |
| **11** | [Conformance levels](#11-conformance-levels) — program, implementation, producer |
| **12** | [Versioning and extension](#12-versioning-and-extension) |
| **A–E** | [Appendices](#appendix-a--reserved-names-and-limits) — reserved names and limits, quick reference, a conforming program, the reference lowering, related documents |

**Reading order.** If you are writing a program, read §4 and §7, then Appendix C. If you are
implementing a backend, read §2, §4, and Appendix D. If you are implementing a validator,
read §9. If you are deciding whether this instruction set is the right shape for something
else, read §1.1 and §2.4 — that is where the design commits.

---

## 0. Conformance

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**, and
**MAY** are to be interpreted as described in RFC 2119.

Three roles are defined, and every requirement in this document is addressed to one of
them:

| Role | Definition |
|---|---|
| **Producer** | anything that emits an AIS program — a human author, a lifting model, a translator from another representation |
| **Validator** | anything that decides whether a program is well-formed and reports diagnostics |
| **Backend** | anything that lowers a program to an executable target |

A **program** is one AIS module: the instruction graph plus its operand planes (§5).

### 0.1 Determinism disclosure

The AIS is a partially non-deterministic instruction set. Instructions dispatched to the
Stochastic Unit (§2.2) have specified *contracts* — types, effects, and control — but
unspecified *bodies*. Every statement in this document about "the value produced" by such
an instruction is a statement about its type and its declared intent, never about a
particular value. Implementations MUST NOT present SU results as guaranteed, and
validators MUST distinguish the two guarantee classes (§2.4) in any diagnostic about
whether an obligation is met.

---

## 1. Overview and layering

The AIS exists because a natural-language skill is *advice*: an agent may follow it. An
AIS program is *structure*: a mandatory step is an instruction the run must visit, a
prohibition is a property of the machine rather than a sentence in a prompt, and a
verification is a typed value produced by code. Compiling from the first form to the
second is the point of the system; this instruction set is the target of that compilation
and the source of the one that follows.

```
   natural-language skill / task            (advice)
              |  LIFT — a model front end, or a human author
              v
   +-----------------------------+
   |   AIS program, encoded as   |          (structure — this specification)
   |        AG-IR (YAML)         |
   +-----------------------------+
              |  LOWER — mechanical, one instruction to one target form
              v
   Jac/OSP walker program + `by llm()` slots   (execution)
              |  RUN
              v
   a report, artifacts, effects
```

The layering matters for one reason above all: **the AIS text is a compile-time artifact
and MUST NOT enter a runtime prompt.** A conforming backend lowers the program to target
code; at run time the Stochastic Unit sees only the individual slot signature, that slot's
semantic operand, and the operand values bound to it. A backend that injects the program
text into a prompt is not implementing this instruction set — it is implementing prose
with extra steps.

### 1.1 Design axioms

These are not requirements; they are the reasons the requirements have the shape they do.

- **A1 — Two units, one graph.** Every instruction executes on either the Deterministic
  Unit (code) or the Stochastic Unit (a model). The unit is a field of the instruction,
  not a property of the program.
- **A2 — Instructions are typed holes.** For SU instructions, code owns the envelope —
  the operand types, the result type, the tool surface, the budget — and the model owns
  the body. The envelope is checkable while the body is free.
- **A3 — Structure over assertion.** An obligation realized as a visited instruction is
  guaranteed; the same obligation realized as a sentence inside a prompt is merely
  observable. Prefer the former; when you take the latter, say so (§9.4).
- **A4 — Totality of lowering.** Every instruction has a defined lowering. There is no
  such thing as an instruction that lowers to nothing: a backend that cannot lower an
  instruction faithfully MUST lower it weakly and record the deviation (§10.3), never
  emit a silent no-op.
- **A5 — Faithfulness.** A producer lifting from a source MAY re-attribute work between
  units and MAY tighten a type; it MUST NOT add, drop, or re-modalize a step relative to
  the source. This makes a program a *measurement* of its source rather than a rewrite of
  it.

---

## 2. The abstract machine

### 2.1 Machine state

| Component | Role | Mutability | Encoded in |
|---|---|---|---|
| **Carry file** | the register file: named, typed slots holding every value that moves through a run | read/write | `walker.carries` |
| **Knowledge** | immutable text bound to specific instructions; the machine's ROM | read-only | `knowledge` |
| **Instruction graph** | the program: instructions (nodes) and transitions (edges); the visit cursor is the program counter | read-only | `nodes`, `edges` |
| **Tool table** | the code bodies the Deterministic Unit executes | read-only | `tools` |
| **Type table** | the named object and enum types operands may take | read-only | `types` |
| **World** | filesystem, network, subprocesses, registered external tools | read/write | reachable **only** through Boundary instructions (§4.2) |
| **Report** | the run's output word, serialized at exit | write-once | `report`, written by `TERMINAL` |

The carry file is flat and global to the run: there are no frames, no stack, and no
scoping. Two instructions that name the same carry name the same slot. This is a
deliberate simplification — the dataflow of an agent run is small and wants to be
inspectable as a whole — and it is why carry naming is load-bearing enough to have its own
rules (§7.4).

### 2.2 Execution units

Every instruction names the unit that executes it, in the field `owner`.

**The Deterministic Unit (DU) — `owner: code`.**
Executes a tool body, a shell command, or a built-in. Its result is a function of its
operands. It cannot be skipped, cannot be persuaded, and cannot be wrong in a way the
program did not specify. A DU instruction MUST resolve to executable code (§5.4); one that
does not is *hollow* and is a fault (§9.3).

**The Stochastic Unit (SU) — `owner: model`.**
Executes a *slot*: a typed hole filled at run time by a language model. Its contract is:

- the **signature** — its operands' types and its result type, enforced by the target's
  structured-generation layer;
- the **semantic operand** — the instruction's `doc` field, plus every knowledge item
  resident on the instruction, compiled into the slot's prompt;
- the **tool surface** — the optional `autonomy.tools` list, the only tools the slot may
  reach for while filling itself.

Within that envelope the SU is unconstrained: it MAY perform an internal reason-act loop,
and it terminates when it yields a schema-valid result. Nothing in the envelope guarantees
the *content* of that result.

**`owner` is a field of every instruction.** Some opcodes fix it (§4); the rest are
genuinely dual, and choosing between them is the highest-leverage decision a producer
makes. The test is: *is the result a total function of the operands, mechanizable without
a guess?* If yes, `owner: code`, always — that is where both the guarantee and the cost
saving come from.

### 2.3 The execution cycle

A run begins by seeding the carry file from the invocation (§7.5) and placing the cursor
on the **entry instruction**, which is `nodes[0]` — the first instruction in program order
(§8.3). Then, repeatedly:

1. **Visit.** The cursor arrives at an instruction. The implementation SHOULD emit a
   progress event naming it.
2. **Bind.** Each entry in `reads` is resolved to a value by the binding rules of §7.
3. **Execute.** The instruction is dispatched to the unit named by `owner` and performs
   its opcode-specific work (§4).
4. **Write back.** The result is assigned to `writes[0]`. When `writes` names more than
   one carry, the remaining carries are recovered from the result's structure by field
   name, then by position; a carry that cannot be recovered retains its default.
5. **Transition.** Control follows the instruction's outgoing edges as specified by its
   opcode. An instruction with outgoing edges and no opcode-specific control rule
   transitions unconditionally.

The cycle ends when a `TERMINAL` executes, when a fault propagates (§10.1), or when the
implementation's step budget is exhausted (§10.4). A single cursor is live at any moment
except during the fan-out of a `SPAWN` (§4.4.4).

### 2.4 Guarantee classes

Every obligation a program is meant to discharge is *realized* by some part of the
instruction graph, and realizations are ordered:

| Class | Realization | Guarantee |
|---|---|---|
| **gated** | a DU instruction whose code performs the obligation | by construction |
| **slotted** | a dedicated SU instruction whose semantic operand states the obligation | observable — the run shows whether it happened |
| **monolithic** | one SU instruction carrying several obligations at once | none beyond prose |
| **hollow** | a DU instruction with nothing to execute | none; a fault |

Producers SHOULD realize every obligation as high in this lattice as its nature allows.
Validators MUST report monolithic realizations (§9.4, G5) and MUST treat hollow
instructions as errors. The lattice, not any single rule, is what makes an AIS program
stronger than the prose it came from: a skill that says "always validate the header" is
advice; a `SENSE` instruction that returns a `bool` is a gate.

---

## 3. Instruction encoding

An instruction is a mapping. These fields are common to all opcodes; opcode-specific
fields are given in §4.

| Field | Type | Presence | Meaning |
|---|---|---|---|
| `id` | identifier | **REQUIRED** | unique within the module; names the instruction in `edges`, `serves`, `produced_by`, and every diagnostic |
| `type` | opcode | **REQUIRED** | one of the mnemonics of §4, spelled exactly |
| `owner` | `code` \| `model` | REQUIRED unless the opcode fixes it | the execution unit (§2.2) |
| `reads` | list of operand names | optional | input operands, in binding order (§7) |
| `writes` | list of carry names | optional | output operands; `writes[0]` receives the result |
| `doc` | text | REQUIRED for SU instructions; RECOMMENDED for all | the **semantic operand**: for an SU instruction it is compiled into the slot prompt and is normative; for a DU instruction it is documentation |
| `tool` | tool name | optional | binds this instruction to a tool table entry (§5.4) |
| `op` | tool name | optional | descriptive: names the operation this instruction performs. It is **not** a binding mechanism — binding is by `tool`, by `serves`, or by name match (§5.4) — and an implementation MUST NOT resolve a tool from `op` alone |
| `surface` | `artifact` \| `workspace` | optional, `ACT` only | whether the effect crosses the user-interaction line (§4.2.2) |
| `output` | type name | optional, SU only | overrides the result type otherwise inferred from `writes[0]` |
| `body` | code | optional, `CODE` only | a single-expression inline body (§4.3) |
| `autonomy` | `{tools: [name, …]}` | optional, SU only | the tool surface the slot may act over |
| `concurrency` | mapping | optional, `SPAWN` only | fan-out source and isolation (§4.4.4) |
| `traces_to` | list of rule ids | optional | provenance: which source obligations this instruction realizes (§9.5) |

An implementation MUST ignore fields it does not recognize, and MUST NOT treat an
unrecognized field as an error. This is what makes §12 possible.

### 3.1 Identifiers

An `id` MUST be a non-empty string. A producer SHOULD restrict identifiers to
`[A-Za-z_][A-Za-z0-9_]*`. A backend MUST sanitize any identifier that is not a valid
target identifier, and MUST apply the same sanitization everywhere the identifier appears,
so that a declaration and its uses cannot diverge. Identifiers in the reserved list of
Appendix A.1 MUST be sanitized even when otherwise well-formed.

---

## 4. The instruction set

Twelve opcodes in five classes.

| Mnemonic | Class | Unit | Produces | Control |
|---|---|---|---|---|
| `GEN-ENUM` | Mind | SU | one member of an enum | fall through |
| `GEN-FILL` | Mind | SU | an instance of an object type | fall through |
| `GEN-EDIT` | Mind | SU | a revision of an existing value | fall through |
| `GEN-RAW` | Mind | SU | free-form text | fall through |
| `SENSE` | Boundary | DU or SU | world state, read in | fall through |
| `ACT` | Boundary | DU or SU | an effect, pushed out | fall through |
| `CODE` | Compute | DU | a pure function of its operands | fall through |
| `ROUTE` | Flow | DU or SU | optionally a value | branch |
| `LOOP` | Flow | DU or SU | a revised value | branch, with a back edge |
| `SPAWN` | Flow | DU | a joined result | fan out, barrier, fall through |
| `CALL` | Flow | SU | a sub-program's result | fall through |
| `TERMINAL` | Terminus | DU | the report | halt |

### 4.1 Mind class — `GEN-ENUM`, `GEN-FILL`, `GEN-EDIT`, `GEN-RAW`

**Unit:** SU, always. A producer MUST NOT set `owner: code` on a Mind instruction.

**Semantics.** The instruction's operands are bound and passed to a slot whose result type
is determined, in order, by: the `output` field if it names a type; else the declared type
of `writes[0]`; else `str`. The slot is filled by the SU and the result is assigned per
§2.3 step 4.

The four Mind opcodes differ only in the *shape* of the result they contract for, ordered
by how much of the result the type system constrains:

| Opcode | Result | Use it when |
|---|---|---|
| `GEN-ENUM` | exactly one member of a declared enum | the decision is a choice from a fixed set |
| `GEN-FILL` | an instance of a declared object type, field-validated | the result is structured and its fields are known |
| `GEN-EDIT` | a revision of a value another instruction already produced | the result is a modification of existing content |
| `GEN-RAW` | unconstrained text | the result is genuinely open-ended |

**Tightening requirement.** A producer MUST select the tightest opcode the intent admits:
`GEN-ENUM` > `GEN-FILL` > `GEN-EDIT` > `GEN-RAW`. "Classify the operation" is a `GEN-ENUM`
over a declared taxonomy, not a `GEN-RAW` whose output some later instruction parses.
`GEN-RAW` is reserved for output that has no smaller shape — a document body, a
natural-language reply, a program's source text.

**`GEN-EDIT` additional semantics.** A `GEN-EDIT` reads the value it revises and writes
the same carry or a successor carry. Backends SHOULD lower `GEN-EDIT` so that the revision
is bounded — expressed as, or checked against, the prior value — rather than as an
unconstrained regeneration. The distinction is load-bearing: a slot with the signature
`(existing, intent) -> replacement` can silently truncate or drop parts of the existing
value, and `GEN-EDIT` exists to make that outcome expressible as a rejection instead of a
result. Conversely, a producer SHOULD NOT use `GEN-EDIT` for a restructuring whose result
does not resemble its input; that is `GEN-RAW`.

**Constraints.**

- A Mind instruction MUST declare `doc`. The `doc` is the instruction's specification; an
  empty one leaves the slot's behavior entirely to the model.
- A Mind instruction whose result type is an enum MUST NOT also declare `autonomy.tools`.
  Constrained decoding of an enum and a tool-use loop are not reliably composable in the
  reference target.
- Backends MUST cap the number of operands passed to a slot (Appendix A.2) and MUST apply
  the identical cap to the slot's declaration and to every call site.
- A `GEN-RAW` whose result is `str` SHOULD have surrounding code-fence decoration stripped
  by the backend before assignment; a `GEN-RAW` whose result is a list SHOULD have
  contentless elements dropped.

**The author-then-run pattern.** A `GEN-RAW` that writes a carry holding a *program*
(conventionally named `script`) is not finished when the text is produced — the program
must run for the instruction's purpose to be served. A producer expressing this pattern
MUST either follow the `GEN-RAW` with an `ACT` that reads that carry (§4.2.2), or give the
instruction an `autonomy.tools` entry whose name contains `run` or `exec`. Backends MUST
lower either form to write-then-execute-then-observe, where the execution result is a
value the program can branch on — never a raised exception, and never the authored text
discarded.

### 4.2 Boundary class — `SENSE`, `ACT`

Boundary instructions are the only instructions that touch the world. Everything else in
the machine operates on the carry file.

#### 4.2.1 `SENSE` — pull world state in

**Unit:** DU (RECOMMENDED) or SU.

**Semantics.** Reads state from outside the machine — a file, a directory listing, a
search, an HTTP resource, an external tool — and writes it to a carry. A `SENSE` MUST be
idempotent and MUST NOT mutate world state; an instruction that does is an `ACT`.

`SENSE` is also the opcode for **verification**. A check ("does the output contain a
header row?") is a `SENSE` whose tool returns a `bool` into a carry that a later `ROUTE`
branches on. This is the difference between a verification that is a gate and one that is
a request; a producer realizing a verification as a sentence inside a Mind instruction's
`doc` has produced advice, not a check.

A DU `SENSE` MUST have a tool (§5.4). An SU `SENSE` with a tool dispatches that tool; an SU
`SENSE` with no tool and a non-empty `writes` becomes a slot; an SU `SENSE` with no tool
and no `writes` performs no computation — its resident knowledge reaches downstream
instructions through their own prompts, and a backend MUST NOT emit a call for it.

#### 4.2.2 `ACT` — push an effect out

**Unit:** DU (RECOMMENDED) or SU.

**Semantics.** Performs an effect: writes a file, runs a command, emits the deliverable.
The `surface` field records which side of the user-interaction line the effect lands on:

| `surface` | Meaning |
|---|---|
| `artifact` | the effect is a deliverable the user interacts with — a named output file, a message, a change outside the run's scratch space |
| `workspace` | the effect is scratch: temporary files, intermediates, anything whose loss the user would not notice |

The line is the *user-interaction* line, not the filesystem line. If deleting the workspace
would lose it and the user would care, the effect crossed the line and the instruction is
`surface: artifact`.

**The no-silent-drop requirement.** An `ACT` MUST NOT lower to nothing. A backend resolving
an `ACT` applies, in order: the tool bound to the instruction; the execute-a-produced-program
form when the instruction reads a program carry; and finally, for an `ACT` with no tool that
reads a text carry, a write of that carry's contents to a path derived from the invocation
(§7.3). Only if none applies MAY the backend record a deviation — and it MUST then record
one (§10.3). The failure this rule exists to prevent is specific and common: a deliverable
authored into a carry by a Mind instruction, and never written anywhere.

**Path control.** The destination of an artifact write is *program-controlled*, derived from
the operands and the invocation by §7.2–§7.3. A backend MUST NOT let a model-produced value
select an absolute or parent-relative destination path.

### 4.3 Compute class — `CODE`

**Unit:** DU, always.

**Semantics.** A pure function of its operands: parsing, arithmetic, key derivation,
projection, assembling one value from several. A `CODE` instruction resolves through a
tool, or through a single-expression `body` field assigning to `writes[0]`.

A `CODE` instruction MUST be deterministic. One that reads the clock, the network, or a
random source is misclassified: make it deterministic, or admit it is a `SENSE`.

A `CODE` instruction served by a tool whose surface is `ACT·artifact` is a write, and its
path operand MUST be resolved write-side (§7.3) rather than read-side. This follows from
the binding rules and is not a separate rule, but it is stated here because getting it
wrong yields an empty destination and a silent failure at run time.

### 4.4 Flow class — `ROUTE`, `LOOP`, `SPAWN`, `CALL`

#### 4.4.1 `ROUTE` — branch

**Unit:** DU or SU. The choice is a semantic one, constrained by §9.4 (G6).

**Semantics, DU.** A DU `ROUTE` first *decides*, then *branches*. If the instruction has a
bound tool and a non-empty `writes`, the tool runs and its result is assigned before any
edge is considered — a `ROUTE` that only branches leaves the carry its guards test at its
default forever, and the branch can never be taken. Then each outgoing edge is examined: an
edge with a `guard` contributes a conditional transition, and an edge without one (or with
a sentinel guard, Appendix A.3) is the default.

Control is: take the first edge whose guard holds; otherwise take the default edge. Three
degenerate cases have specified behavior, because each corresponds to a real failure:

| Case | Required behavior |
|---|---|
| several guarded edges, no default | the run MUST fault, naming the instruction and reporting that the discriminator fell outside the guard set |
| exactly one guarded edge, no default | the edge is taken unconditionally; the guard is a precondition on a transition that must happen anyway |
| no guards at all | transition unconditionally |

A producer SHOULD supply a total default edge on every multi-way `ROUTE`. The fault in the
first case is specified precisely so that a run cannot end silently and successfully having
done nothing.

**Semantics, SU.** An SU `ROUTE` with a `writes` and no bound tool first fills a slot and
assigns it, as a Mind instruction would. It then chooses among its outgoing edges by
model-guided traversal, steered by the instruction's `doc` as the stated intent and by the
values of its `reads` as the deciding state. An SU `ROUTE` with a single outgoing edge
transitions unconditionally.

**The human-in-the-loop constraint.** A `ROUTE` whose decision consumes human feedback — an
approval, a confirmation, a rejection — MUST be `owner: code`, with explicit guards over a
carry produced by a DU instruction that parses the human's answer. A model-owned route that
reads "no" and decides for itself what to do about it has converted a gate into a
suggestion. Validators MUST report this as an error (§9.4, G6).

#### 4.4.2 `LOOP` — bounded repetition

**Unit:** DU or SU.

**Semantics.** A `LOOP` performs its productive work — a tool call or a slot fill — and then
either advances or takes a back edge to an earlier instruction. Continuation is governed by
two operands a conforming `LOOP` MUST carry:

- a **verdict**: a typed carry, produced by a DU instruction, that says whether the work is
  acceptable;
- a **cap**: a bound on iterations, together with a counter carry.

Control advances when the verdict passes *or* the cap is reached; otherwise the back edge is
taken. A `LOOP` with no cap is non-conforming: a repair loop with a stochastic verdict and
no bound does not terminate on a weak model, and a run that does not terminate is worse than
one that stops early with a recorded deviation. A `LOOP` MUST NOT be encoded as an
unconditional self-transition.

#### 4.4.3 `CALL` — expand a sub-program

**Unit:** SU.

**Semantics.** Invokes a sub-program in the *same* carry context: a nested slot that reads
this instruction's operands and writes its result to `writes[0]`. If no operand binds and
the program has a `task` carry, `task` is bound instead, so that a `CALL` is never invoked
with no context at all.

When the module declares a program carry (`script`), a `CALL` that produces one MUST have
its produced program executed, exactly as §4.1's author-then-run pattern requires.

`CALL` is the composition primitive: it shares the caller's state, unlike `SPAWN`, which
does not.

#### 4.4.4 `SPAWN` — fan out

**Unit:** DU — the fan-out and the join are mechanism; the workers are cognition.

**Semantics.** Forks one sibling execution per sub-task, runs them concurrently, waits for
all of them, and joins their results into `writes[0]`. Each sibling runs a single worker
slot over its own sub-task string.

The **fan-out source** is resolved in this order:

1. a `reads` operand whose declared type is a list — one sibling per element (data
   parallelism);
2. a literal list under the instruction's `concurrency.spawn` — one sibling per entry
   (fixed branches);
3. otherwise the invocation's `task` — a degenerate fan-out of one.

The **join** writes a list into a list-typed carry, or the concatenation of the sibling
results into a text carry.

**Isolation.** The instruction MUST declare `concurrency.isolation`, one of:

| Value | Contract |
|---|---|
| `private_write` | each sibling writes only to its own scratch space |
| `shared_read` | siblings may read fork-immutable shared state; they do not write shared state |
| `orchestrator_owned` | multi-writer state is hoisted out of the siblings and applied once, after the barrier |

A `SPAWN` over shared *writable* state with no isolation declaration is a defect in the
program, not a design choice; validators MUST report it (§9.4, G8). Claimed parallelism
that cannot actually run in parallel MUST likewise be reported: a fan-out declared over
sequential, mutually dependent work is a false claim about the program's shape.

### 4.5 Terminus — `TERMINAL`

**Unit:** DU, always.

**Semantics.** Serializes the carries the run produced into the report register and halts.
Every module MUST contain exactly one `TERMINAL`, and it MUST be reachable.

The report MUST be a function of the produced carries. A `TERMINAL` that reports a constant,
or a summary composed by the SU, discards the run's actual result and defeats any caller
that inspects it.

`TERMINAL` takes no `writes`. Its `reads`, when present, are a hint about which carries
matter most in the report.

---

## 5. The operand planes

An instruction's behavior is the join of four independent planes. Each plane has its own
declaration section, its own binding rule, and its own failure mode.

### 5.1 The data plane — carries

A **carry** is a named, typed slot in the carry file. Every value that moves between
instructions is a carry; there is no other channel.

```yaml
walker:
  name: <ProgramName>
  carries:
    task:      { type: str,  role: input }
    plan_md:   { type: str,  produced_by: draft_plan }
    plan_ok:   { type: bool, produced_by: verify }
```

| Field | Presence | Meaning |
|---|---|---|
| `type` | REQUIRED (see §6.3) | the carry's declared type |
| `role` | one of `role` / `produced_by` REQUIRED | `input` — seeded from the invocation |
| `produced_by` | | the `id` of the instruction that writes it |
| `doc` | optional | what the carry holds; may be surfaced to the SU |
| `traces_to` | optional | provenance (§9.5) |

**Rules.**

- Every name in an instruction's `reads` MUST resolve to a carry, a knowledge key, or the
  invocation input. A dangling read is a well-formedness error (§9.2).
- Every name in an instruction's `writes` MUST be a declared carry, and that carry's
  `produced_by` SHOULD name the writing instruction.
- A carry SHOULD be produced by exactly one instruction. Two producers make the value
  order-dependent, and the order is the graph's, not the reader's.
- The carry named `task` is the conventional invocation input and SHOULD be present in
  every module.
- A carry MUST NOT be named with a bare tool-parameter name (§7.4). This is the single
  most damaging naming error in the instruction set.

**Directionality.** A data edge exists between two instructions wherever one's `writes`
intersects the other's `reads`. The data plane is therefore derivable, not declared: the
graph of who-produces-what-for-whom falls out of the instruction list, and a validator
MUST be able to compute it without consulting the control plane.

### 5.2 The knowledge plane

Knowledge is immutable reference material bound to specific instructions: a required output
format, a template, a taxonomy, a set of domain rules, a code scaffold.

```yaml
knowledge:
  header_format:
    resident_on: [draft_header]
    template: |
      Every plan MUST open with exactly this header:
      # [Feature Name] Implementation Plan
      **Goal:** [one sentence]
```

| Field | Presence | Meaning |
|---|---|---|
| `resident_on` | REQUIRED | the instruction ids whose slots receive this item |
| `template` \| `pattern` \| `body` \| `value` | exactly one REQUIRED | the content, verbatim |
| `traces_to` | optional | provenance (§9.5) |

**The residency rule.** An instruction receives exactly the knowledge whose `resident_on`
lists it — no more, which is what makes scoping a cost lever, and no less, which is what
stops content from being silently dropped. Backends MUST fold each resident item's content
*in full* into the instruction's semantic operand; truncating or summarizing knowledge at
lower time is non-conforming.

**The embodiment rule.** Knowledge MUST carry content, never a reference to content. A
knowledge body that reads "see FORMS.md" or "follow the format in the section above" is a
**prose pointer**: the graph looks complete, but the bytes still live outside it, and the
program is no longer self-contained. Validators MUST report prose pointers (§9.4, G1).

The same rule governs everything load-bearing: tool bodies are embodied verbatim, exact
commands and endpoints are embodied, user-facing strings are embodied, sub-agent prompts
are embodied. A `prose:` or `source:` field MAY accompany embodied content as provenance;
it MUST NOT stand in place of it.

### 5.3 The control plane — edges

```yaml
edges:
  - {from: draft, to: verify, modality: mandatory}
  - {from: verify, to: save,  modality: discretionary, guard: "plan_ok == true"}
```

| Field | Presence | Meaning |
|---|---|---|
| `from` | REQUIRED | source instruction id |
| `to` | REQUIRED | target instruction id |
| `modality` | RECOMMENDED | `mandatory` \| `discretionary` \| `forbidden` |
| `guard` | optional | a condition over carries, evaluated by the DU |
| `traces_to` | optional | provenance (§9.5) |

**`edges` is required.** A module with instructions and no edges executes its entry
instruction and halts. There is no implicit fall-through by program order.

**Modality** is the deontic force of the transition, read from the source's own vocabulary,
and it is lowered *structurally* rather than asserted:

| Modality | Source signal | Realization |
|---|---|---|
| `mandatory` | "must", "always", "follow its instructions" | a transition that fires by construction; the SU cannot skip it |
| `discretionary` | "if needed", "may", "for advanced cases see…" | a guarded transition, where the guard is a typed verdict the DU evaluates |
| `forbidden` | "never", "do not" | **no edge at all** — the transition is absent from the program, and it attaches instead as a constraint recorded on the source instruction |

The `forbidden` case is the reason modality belongs in the instruction set rather than in a
comment: a path that does not exist cannot be taken, whereas a prohibition written into a
prompt can be. A producer MUST NOT encode a prohibition as an edge with a discouraging
`doc`.

**Guards.** A guard is a condition over carry values. Producers SHOULD write guards as
comparisons against literals or enum members (`status == "ok"`, `op == Op.MERGE`,
`plan_ok`). A guard whose text is one of the sentinels in Appendix A.3 means
*unconditional* and MUST be treated as a default edge, not lowered as a literal condition.
A guard MUST be evaluable by the DU; a guard that requires a judgment is a sign the branch
belongs on an SU `ROUTE` instead.

### 5.4 The tool plane

A tool is the executable body a DU instruction runs.

```yaml
tools:
  save_plan:
    sig: "(plan_md, path) -> str"
    surface: ACT·artifact
    serves: [save]
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
```

| Field | Presence | Meaning |
|---|---|---|
| `sig` | REQUIRED | `"(param, …) -> type"`; the parameter names are the binding surface (§7) |
| `surface` | REQUIRED | `SENSE` for reads, `ACT·artifact` for writes that cross the user line, `ACT` otherwise |
| `serves` | one of `serves` / instruction `tool` REQUIRED | the instruction ids this tool implements |
| `body` \| `command` | see the embodiment ladder | the implementation |
| `doc` | RECOMMENDED | what the tool does |
| `traces_to` | optional | provenance (§9.5) |

**Binding a tool to an instruction.** Three mechanisms, resolved in this order: the
instruction's `tool` field names the tool; a tool's `serves` lists the instruction's `id`; a
tool's name is identical to the instruction's `id`. When more than one applies they MUST
agree. A producer SHOULD use exactly one, and SHOULD prefer `serves` when a tool serves
several instructions and `tool` otherwise. When several tools serve one instruction, they form an ordered **pipeline**:
they run in declaration order over the shared workspace and the last one's result is the
instruction's result. Declaration order is therefore semantic, and a producer MUST author a
multi-tool instruction's tools in pipeline order.

**The embodiment ladder.** Every tool MUST be reducible to something that runs. Backends
resolve a tool by descending this ladder, and a producer SHOULD author every tool as high
on it as possible:

| Rung | Form | Lowering |
|---|---|---|
| 0 | **live external tool** — a registered tool, an MCP tool, an API client | bound by exact name and called; MUST NOT be re-implemented as a script |
| 1 | **`body`** — a self-contained function whose name and signature match the tool | inlined and called directly |
| 2 | **`command`** — a real shell command with placeholders for its inputs | a subprocess call with the operands threaded in signature order and literals preserved |
| 3 | **neither** | lowered to a scoped author-then-run envelope, and **recorded as a faithfulness deviation** (§10.3) |

A tool that reaches rung 3 is debt in the program, not a feature of the backend. A tool
whose work is genuinely a live integration — reading a chat workspace, fetching a URL, a
service API — MUST be declared at rung 0 and MUST NOT be scripted; a generated Python
script cannot read a chat workspace, and lowering it as one produces a program that
confidently reports success having invented its input.

**The built-in tool library.** A conforming implementation SHOULD provide these tools by
name. A producer declaring one of them MUST omit `body` — the implementation supplies it —
and MUST NOT be reported as a prose pointer for doing so.

| Built-in | Signature | Surface |
|---|---|---|
| `read_file` | `(path) -> str` | SENSE |
| `list_dir` | `(path) -> str` | SENSE |
| `glob_files` | `(pattern, path) -> str` | SENSE |
| `grep` | `(pattern, path) -> str` | SENSE |
| `write_file` | `(path, content) -> str` | ACT·artifact |
| `run_command` | `(command) -> str` | ACT·artifact |
| `http_get` | `(url) -> str` | SENSE |

---

## 6. The type system

### 6.1 Primitive types

`str`, `int`, `float`, `bool`, `list`, `dict`, `any`, and parameterized list forms such as
`list[str]`.

`any` is legal but weak: it disables checking at both ends of the value's life. §7.6 makes
`any` an error in the one position where it costs the most.

### 6.2 Declared types

```yaml
types:
  Op:
    kind: enum
    members: [merge, split, rotate]
  Args:
    kind: object
    fields:
      out:   { type: str, doc: "output file path parsed from the task" }
      width: { type: int, doc: "page width in points" }
```

- An **enum** declares `members`, and is the result type of a `GEN-ENUM`.
- An **object** declares `fields`, each with a `type` and optionally a `doc`. Object fields
  MUST have defaults (or a default MUST be synthesizable) and SHOULD NOT be declared
  optional-or-null: a nullable field in a structured-generation schema is an invitation to
  return nothing.
- A field `doc` is normative for SU instructions: it becomes the field's description in the
  generation schema, and it is often the only thing that makes an ambiguous field fillable.

### 6.3 Typing rules

- Every carry SHOULD declare a `type`. An untyped carry lowers to `any` and the target's
  type checker becomes blind to every mismatch that flows through it.
- A carry read by a tool MUST be typed compatibly with that tool's parameter. The tool's
  signature is ground truth: it is code, and code does not negotiate.
- A carry written by an SU instruction and read by a DU tool **MUST** be typed. This
  crossing is the one place where an untyped value produces a green compile and a runtime
  crash, and validators MUST report it as an error (§9.4, G9).
- A carry with two consumers demanding incompatible types is an error; the program must
  choose, or split the carry.

### 6.4 Type inference for slots

The result type of an SU instruction is, in order: `output` if it names a declared type;
else the declared type of `writes[0]`; else `str`. When that resolves to `any`, an
implementation SHOULD instead adopt the type demanded by the carry's downstream consumer,
and only fall back to `str` when no consumer constrains it — handing a `str` to a tool that
expects a `dict` is a crash, and it is avoidable at compile time.

---

## 7. The calling convention

This section is the ABI. It specifies how an instruction's `reads` become the arguments of
the tool or slot it dispatches to. It exists because the most common way a well-formed
program produces garbage is not a bad instruction — it is a *correctly executed* tool call
with the right values in the wrong parameters.

### 7.1 Binding order

For each parameter of the tool's signature, in signature order, resolve the first rule that
applies:

| # | Rule | Binds to |
|---|---|---|
| 1 | **by name** | the carry whose name equals the parameter's |
| 2 | **by object field** | the field of an object-typed carry whose name equals the parameter's — `width` binds `spec.width` |
| 3 | **by role** (§7.2) | for a content parameter, the instruction's first non-path-shaped read carry; for a path parameter, a path-shaped read carry |
| 4 | **positionally** | the i-th read carry — **except** that a path-named parameter MUST NOT bind a non-path-shaped carry this way |
| 5 | **by invocation fallback** (§7.3) | for a path parameter only: a filename recovered from the invocation text |
| 6 | **unbound** | a null value |

Rule 4's exception is the whole reason rule 3 exists. Positional binding on a write tool
declared `save(content, path)` reading `[document]` would hand the document to `content`
correctly — but on `save(path, content)` it would hand the document to `path` and leave
`content` null, producing an empty file named after its own contents. Role binding runs
first, and positional binding refuses the specific transposition that causes it.

Operands of an **SU slot** bind differently and more simply: the slot's parameters *are*
the instruction's read carries, in declaration order, capped per §7.6. Knowledge resident
on the instruction does not appear as a parameter; it is folded into the semantic operand
(§5.2). An implementation MAY additionally pass a knowledge item as a typed operand, but
MUST NOT do so *instead* of folding it in.

### 7.2 Role binding — content versus path

A write tool's two parameters usually have the same type and opposite meanings, so position
cannot be trusted to tell them apart. Role binding runs first and separates them by name:

- A parameter whose name is one of the **content names** (`content`, `text`, `data`, `body`,
  `code`, `source`, `markdown`, `html`, `payload`) binds to the instruction's first
  non-path-shaped read carry.
- A parameter whose name is one of the **path names** (`path`, `out`, `dest`, `outfile`,
  `filename`, `file`, `out_path`, `output_path`, `outpath`, `target`, `target_path`,
  `dest_path`) binds to a path-shaped read carry if one exists.

A carry is **path-shaped** when its name is `path` or `filename`, or ends in `_path`,
`_file`, `_filename`, `_dest`, `_out`, or `_target`. The carry `task` is never path-shaped.

This is why a tool declared `save_plan(plan_md, path)` reading only `[plan_md]` binds
correctly: `plan_md` is content, and `path` falls through to the next rule.

### 7.3 The invocation fallback for paths

A path parameter with no carry to bind resolves from the invocation's `task` text:

- for a **write** (an `ACT`, or a `CODE` served by an `ACT·artifact` tool), the filename
  following a save/output/write verb — "save as `out.csv`" — else the first bare filename;
- for a **read** (a `SENSE`), the filename following a read/open/load/parse/from verb —
  "clean `data.csv`" — skipping any filename already claimed by a write.

So for the invocation *"clean data.csv and save as out.csv"*, a reader binds `data.csv` and
a writer binds `out.csv` with no carries declared for either. A producer SHOULD let
invocation-supplied filenames fall to this rule rather than modeling them as carries.

When a write's destination cannot be resolved, the implementation MUST derive a
program-controlled destination inside the run directory (§4.2.2), never an empty path.

### 7.4 The carry-naming rule

**A carry MUST NOT be named with a bare tool-parameter name** — `path`, `content`, `text`,
`data`, `file`, `out`, `dest`. Rule 1 binds by name and outranks everything else, so a carry
literally named `path` hijacks the `path` parameter of *every* tool in the module that has
one. A search directory held in a carry named `path` will silently redirect a later file
write to the search directory: a green compile that writes nowhere.

Qualify every carry name to its role: `search_path`, `input_text`, `csv_row`, `out_file`.
The qualified name still binds correctly by role — `search_path` is path-shaped — without
colliding.

### 7.5 Invocation

A run is invoked with values for the carries declared `role: input`. The carry `task` is
the invocation's subject in natural language. An implementation SHOULD additionally expose
each string-typed input carry as a named invocation parameter, so that a caller already
holding a value can supply it directly instead of round-tripping it through prose; the task
text remains the fallback for the input the entry instruction reads.

An implementation MUST NOT satisfy a human-approval input from the task text. A task phrased
"approve and delete the old files" must not thereby answer the confirmation gate that guards
the deletion.

### 7.6 Slot arity

A backend MUST cap the number of operands bound to one SU slot (Appendix A.2), and MUST use
the same cap in the slot's declaration and at every call site — a slot declared with more
parameters than its call site supplies is a broken program. When an instruction's `reads`
exceed the cap, the excess SHOULD be folded into one composed context operand rather than
dropped, since a dropped read is an operand the slot needed and cannot ask for.

---

## 8. Module format

### 8.1 Encoding

An AIS module is encoded as **AG-IR**: one YAML document, conventionally in a file with the
extension `.agir`.

An implementation MUST accept:

- an optional leading Markdown code fence around the whole document;
- an optional `--- … ---` frontmatter block preceding the body;
- each mapping section (`types`, `tools`, `knowledge`, `walker.carries`, a type's `fields`)
  in any of three spellings, all equivalent:

```yaml
tools: {upcase: {sig: "(s) -> str"}}          # mapping
tools: [{name: upcase, sig: "(s) -> str"}]    # sequence, name inline
tools: [{upcase: {sig: "(s) -> str"}}]        # sequence of single-entry mappings
```

An implementation MAY additionally accept relaxations of strict YAML that authored documents
commonly contain — an unquoted flow mapping such as `{type: list[str], role: input}`, or a
plain scalar containing a colon. Any such relaxation MUST be applied identically by every
component that reads the document: a viewer that parses differently from the backend renders
a program the backend never built, and the disagreement surfaces as a wrong picture rather
than as the drift it is.

Producers SHOULD emit strictly valid YAML: put code in block scalars (`body: |`), and quote
any scalar containing a colon.

### 8.2 Top-level sections

| Section | Presence | Holds |
|---|---|---|
| frontmatter `name` | REQUIRED | the module's identifier |
| frontmatter `description` | REQUIRED | when to invoke it; becomes the registered tool's description |
| `agir_version` | RECOMMENDED | the encoding version (§12) |
| `types` | optional | declared enums and objects (§6.2) |
| `knowledge` | optional | the knowledge plane (§5.2) |
| `tools` | optional | the tool plane (§5.4) |
| `walker.name` | REQUIRED | the program's name in the target |
| `walker.carries` | REQUIRED | the data plane (§5.1) |
| `nodes` | REQUIRED | the instruction list (§3, §4) |
| `edges` | REQUIRED | the control plane (§5.3) |
| `concurrency` | optional | module-level parallelism declaration; `spawn: none` with a stated reason is a conforming value and SHOULD be present when a module declares no `SPAWN` |
| `faithfulness` | optional | the provenance record (§9.5) |
| `standalone`, `shape` | optional | descriptive metadata: self-containment, and a topology label such as `pipeline` or `dispatch-router` |

Sections not listed here MUST be ignored rather than rejected (§3, §12.2).

### 8.3 Program order

The order of `nodes` is significant in exactly one way: **`nodes[0]` is the entry
instruction**. All other ordering is presentational, and control flow is determined solely
by `edges`.

The order of `tools` is significant when several tools serve one instruction (§5.4,
pipeline order). The order of `edges` is significant on a branching instruction: guards are
evaluated in edge order.

Everything else — the order of `carries`, of `knowledge`, of `types` — is presentational.

---

## 9. Static semantics

### 9.1 Validation model — diagnose, do not veto

A validator's job is not to reject a program. It is to produce the most faithful runnable
program it can and to say exactly where it had to compromise. This is a deliberate
inversion of the usual compiler contract, and it follows from what produces AIS programs:
a producer that is itself stochastic will get details wrong, and a pipeline that halts on
the first imperfection converges more slowly than one that repairs, degrades, and reports.

A conforming implementation SHOULD therefore apply, in order:

1. **Mechanical repair** — deterministic fixes re-checked through the compile oracle: mint a
   missing carry, inline a referenced sibling file as knowledge, re-own a hollow DU
   instruction to an SU slot, adopt an agreeing carry type. A repair that fails to compile
   MUST be discarded and the original kept.
2. **Scoped repair** — a bounded model pass over just the failing view.
3. **Faithful degradation** — take the weaker-but-real lowering and record it (§10.3).
4. **Report** — everything unresolved rides a typed findings list, each with a severity and
   the action that would resolve it.

The resulting outcomes:

| Outcome | Meaning |
|---|---|
| `clean` | runnable; nothing found, nothing needed |
| `fixed` | runnable and clean, but only because repairs landed |
| `degraded` | runnable, with residual findings attached |
| `failed` | no runnable program exists — the only true failure |

### 9.2 Well-formedness

A validator MUST report each of the following. These are properties of the program text and
require no lowering. An implementation MAY discharge some of them indirectly — several
surface as compile-oracle failures (X5) rather than as their own diagnostic — but a
diagnostic that names the violated condition is worth more than one that names its
consequence, and implementations SHOULD check them directly.

| # | Requirement |
|---|---|
| W1 | Every instruction has a unique, non-empty `id` |
| W2 | Every instruction's `type` is a defined opcode, spelled exactly |
| W3 | Every instruction's `owner` is `code` or `model`, and is permitted by its opcode |
| W4 | Every `edges` endpoint names an existing instruction |
| W5 | `edges` is non-empty whenever the module has more than one instruction |
| W6 | Exactly one `TERMINAL` exists, and it is reachable from the entry instruction |
| W7 | Every instruction is reachable from the entry instruction |
| W8 | Every name in `reads` resolves to a carry, a knowledge key, or an object field of a read carry |
| W9 | Every name in `writes` is a declared carry |
| W10 | Every carry declares `role: input` or `produced_by`, and every `produced_by` names an existing instruction |
| W11 | Every tool binds to at least one instruction, and every bound instruction id exists |
| W12 | Every knowledge item's `resident_on` names existing instructions and carries content |
| W13 | No carry is named with a bare tool-parameter name (§7.4) |
| W14 | Every declared type is well-formed: an enum has members, an object has fields |

### 9.3 Executability

| # | Requirement |
|---|---|
| X1 | Every DU instruction resolves to executable code — a bound tool with a body, a `command`, a built-in name, a live external tool, or (for `CODE`) an inline body. A DU instruction that resolves to none of these is **hollow**, and hollow is an error |
| X2 | Every `LOOP` declares a verdict carry and a cap (§4.4.2) |
| X3 | Every `SPAWN` declares an isolation mode (§4.4.4) |
| X4 | Every multi-way `ROUTE` declares a total default edge, or else accepts the dead-end fault of §4.4.1 as its behavior when no guard matches |
| X5 | The program lowers to the target and type-checks with zero errors |

X5 is the **compile oracle**, and it is the only condition whose failure makes a validation
`failed`: if the program does not lower, there is no agent to have findings about.

### 9.4 The validation battery

A conforming validator SHOULD implement these checks. The identifiers are stable and appear
in diagnostics; `G2` is unassigned in this version.

| Gate | Question | Severity of a residual finding |
|---|---|---|
| **G1** — standalone | is every tool and knowledge item embodied rather than a pointer? | warn |
| **G3** — artifact boundary | does every mandated output actually get written by an `ACT`? | error |
| **G4** — compile oracle | does the program lower and type-check with zero errors? | **fatal** — the only one |
| **G5** — structural coverage | is each mandatory obligation realized by its own instruction, rather than folded monolithically or missing? | warn |
| **G6** — human-in-the-loop | is every human-feedback `ROUTE` `owner: code` with explicit guards? | error |
| **G7** — environment | do the tools' imports and binaries resolve in the target runtime? | warn (advisory; an implementation MAY offer a strict mode) |
| **G8** — concurrency | is claimed parallelism real, and is declared isolation sufficient? | error for false parallelism; advisory for missed opportunities |
| **G9** — type unification | do carry types match the tools that consume them, and is no model→code carry untyped? | error |

Severity has a precise meaning and implementations MUST preserve it:

- **error** — a runtime crash or a violated mandate riding a green compile. The program
  runs and is wrong.
- **warn** — a faithfulness or quality deficit. The program runs and is weaker than its
  source.
- **fatal** — there is no program.

### 9.5 Provenance and faithfulness

When a program is lifted from a source, each obligation in that source is assigned a stable
rule id, and every instruction, edge, carry, tool, and knowledge item MAY carry a
`traces_to` naming the obligations it realizes. The `faithfulness` section records the audit:
which obligations are realized where, and which deviations were accepted.

A validator performing a faithfulness audit MUST check four things, in this order — the
first is about structure, the rest are about self-containment:

| Check | Question |
|---|---|
| **Structure** | are there instructions with no source obligation (added), obligations with no instruction (dropped), or transitions whose modality differs from the source's deontic force (re-modalized)? |
| **Delete-the-source** | if the source document were deleted, does the program still lower to a working agent? |
| **Bundle depth** | recursing through every sibling resource the source references: is local know-how embodied, is each sub-skill a standalone sub-program, and does live external data stay live? |
| **Carrier completeness** | given only the typed carries — not the raw invocation text — can every required deliverable still be produced? |

The fourth is the least obvious and the most often failed. Tight scoping is where the cost
saving comes from, and the same tightness clips any deliverable that a loose, unstructured
agent would have produced incidentally. The fix is to *widen the typed carrier* — declare
the deliverable list as a typed carry and add an instruction that emits it — never to
loosen the scoping back out.

"World-independent" is not a requirement and often not achievable: a program that must
fetch a live resource is correctly dependent on the world. The distinction is between
*bundle-independent* — all local know-how embodied — and world-independent, and only the
first is required.

---

## 10. Dynamic semantics

### 10.1 Faults

A fault aborts the run and propagates to the caller with a message naming the faulting
instruction. The specified faults:

| Fault | Raised when |
|---|---|
| **route dead-end** | a multi-way `ROUTE` matched no guard and declared no default (§4.4.1) |
| **unresolvable operand** | a required path operand resolved empty and no program-controlled destination could be derived |
| **budget exhausted** | the step budget was consumed before a `TERMINAL` executed (§10.4) |

Everything else is a *result*, not a fault. In particular, the failure of an executed
program — a non-zero exit, a traceback from a generated script — MUST be delivered to the
program as an inspectable value carrying at least an outcome flag, an error string, and any
output, so that a `ROUTE` can branch on it and a `LOOP` can repair from it. A tool failure
that escapes as an exception converts a recoverable state into a dead run.

### 10.2 Error routing

A produced error value MUST be routed. An error sentinel that no edge tests is
indistinguishable from success: the run continues, the deliverable is missing, and the
report says the work is done. Producers MUST place a `ROUTE` on every path that can produce
an error value, including the path out of a verification instruction.

### 10.3 The deviation record

When a backend cannot lower an instruction as written and takes a weaker form — a rung-3
tool, a hollow DU instruction re-owned to a slot, a `LOOP` cap imposed where none was
declared — it MUST record a deviation naming the instruction, the intended lowering, and
the substituted one, and MUST surface it with the program. A backend MUST NOT silently
weaken a program: the entire value of the instruction set rests on the claim that what the
program says is what the run does, and an unrecorded substitution voids it.

### 10.4 Budgets

An implementation SHOULD enforce a step budget over a run, and SHOULD make it inspectable.
On exhaustion it MUST fault (§10.1) rather than report success. Where an instruction
declares its own bound — a `LOOP` cap, a slot's tool-use limit — the instruction's bound
applies first.

### 10.5 Observability

An implementation SHOULD emit, per instruction: the visit, the operand values bound, the
unit that executed it, and the value written. For SU instructions this trace is the only
evidence that a slotted obligation was discharged, which is precisely what "observable but
not guaranteed" (§2.4) means in practice. A trace that omits SU input and output reduces a
slotted realization to a monolithic one from the reader's point of view.

---

## 11. Conformance levels

### 11.1 Program conformance

A **conforming program** satisfies every MUST in §3–§8, all of W1–W14, and all of X1–X5.

A **strictly conforming program** additionally: is encoded as strictly valid YAML; declares
a type for every carry; declares `traces_to` on every instruction; and produces no `error`
finding from the battery in §9.4.

### 11.2 Implementation profiles

| Profile | Opcodes | Required of the implementation |
|---|---|---|
| **AIS-Core** | `GEN-ENUM`, `GEN-FILL`, `GEN-RAW`, `SENSE`, `ACT`, `CODE`, `ROUTE`, `TERMINAL` | the full operand model (§5), the calling convention (§7), the module format (§8), well-formedness and executability (§9.2, §9.3) |
| **AIS-Flow** | Core + `LOOP`, `CALL`, `SPAWN`, `GEN-EDIT` | the above, plus bounded iteration, sub-program expansion, and real concurrency with enforced isolation |
| **AIS-Full** | all | the above, plus the complete validation battery (§9.4), the faithfulness audit (§9.5), and the repair-and-degrade ladder (§9.1) |

An implementation MUST document its profile. An implementation that encounters an opcode
outside its profile MUST report it as unsupported and MUST NOT silently skip the
instruction — skipping is exactly the failure mode the instruction set exists to eliminate.

### 11.3 Producer conformance

A conforming producer MUST emit conforming programs, MUST apply the tightening requirement
(§4.1), MUST obey the embodiment rule (§5.2) and the carry-naming rule (§7.4), and — when
lifting from a source — MUST NOT add, drop, or re-modalize a step relative to that source
(A5).

---

## 12. Versioning and extension

### 12.1 Version identification

A module SHOULD declare `agir_version`. This document specifies `0.1`. A missing version is
interpreted as `0.1`.

### 12.2 Extension rules

- Unknown top-level sections, unknown instruction fields, and unknown tool or carry fields
  MUST be ignored, never rejected.
- An unknown **opcode** MUST NOT be ignored: it is an unsupported instruction and MUST be
  reported (§11.2).
- An unknown `modality`, `surface`, or `isolation` value MUST be reported, and the
  implementation SHOULD fall back to the most conservative interpretation — `mandatory` for
  a modality, `artifact` for a surface, `orchestrator_owned` for an isolation.

New opcodes are added only when a shape cannot be expressed as a composition of existing
ones. The composite patterns — a safe-edit with a code-checked diff, a skeleton-first
build, a grounded verification loop — are *shapes over this alphabet*, and they earn a name
in the guidance documents rather than an opcode here.

### 12.3 Divergence between this document and the reference backend

Where the reference backend implements more than this document specifies, that behavior is
an extension and MUST NOT be relied on by a portable program. Where it implements less, the
gap is a defect in the backend. Where the two conflict on a specified behavior — the
lowering of an opcode, a binding rule, a fault — this document is the authority, and the
divergence is a bug report.

Two provisions are known to be under-enforced by the reference backend at the time of
writing and are flagged here rather than quietly relaxed: `LOOP`'s cap and verdict (X2) are
specified but not statically enforced, and `SPAWN`'s isolation modes (X3) are recorded and
reported but realized only as per-sibling scratch separation, with stronger isolation
deferred to the host runtime.

---

## Appendix A — Reserved names and limits

### A.1 Reserved identifiers

An identifier that collides with a target keyword MUST be sanitized before emission, in
declarations and uses alike. For the reference target the reserved set is:

```
True False None and or not in is if else elif for while def class return
import from as walker node edge obj has can with visit spawn report root
global nonlocal lambda del try except async await yield pass enum sem
here self visitor
```

### A.2 Limits

| Limit | Value in the reference implementation | Requirement |
|---|---|---|
| Operands bound to one SU slot | 12 | a backend MUST apply one value consistently to declarations and call sites (§7.6) |
| Context entries injected into a model-guided `ROUTE` | 6 | implementation-defined |
| Instructions per module | unlimited | — |
| Steps per run | implementation-defined | MUST fault on exhaustion (§10.4) |

### A.3 Guard sentinels

A guard whose text, lowercased and trimmed, is one of the following means *unconditional*
and MUST be treated as a default edge rather than lowered as a condition:

```
""   otherwise   default   else   always   true   _
```

### A.4 Parameter-name vocabularies

**Content names** — `content`, `text`, `data`, `body`, `code`, `source`, `markdown`,
`html`, `payload`.

**Path names** — `path`, `out`, `dest`, `outfile`, `filename`, `file`, `out_path`,
`output_path`, `outpath`, `target`, `target_path`, `dest_path`.

**Path-shaped carry names** — a carry named `path` or `filename`, or one ending in `_path`,
`_file`, `_filename`, `_dest`, `_out`, `_target`. The carry `task` is never path-shaped.

---

## Appendix B — Instruction quick reference

| Mnemonic | Unit | `reads` | `writes` | Required companions | Control out |
|---|---|---|---|---|---|
| `GEN-ENUM` | SU | operands | 1 | an enum in `types`; no `autonomy.tools` | fall through |
| `GEN-FILL` | SU | operands | 1 | an object in `types` | fall through |
| `GEN-EDIT` | SU | the value revised | 1 | — | fall through |
| `GEN-RAW` | SU | operands | 1 | a runner, if it writes a program | fall through |
| `SENSE` | DU/SU | operands | 0–n | a tool (DU) | fall through |
| `ACT` | DU/SU | content, path | 0–n | a tool, or a content carry | fall through |
| `CODE` | DU | operands | 1 | a tool or an inline `body` | fall through |
| `ROUTE` | DU/SU | the discriminator | 0–1 | guarded edges + a default | branch |
| `LOOP` | DU/SU | operands | 1 | a verdict carry, a cap, a back edge | branch |
| `SPAWN` | DU | a list, or `concurrency.spawn` | 1 | `concurrency.isolation` | fan out, join |
| `CALL` | SU | operands | 1 | a runner, if it produces a program | fall through |
| `TERMINAL` | DU | hint | 0 | exactly one per module | halt |

---

## Appendix C — A conforming program

A plan writer: two SU instructions draft, three DU instructions assemble, verify, and save.
Note that `save_plan` reads only `[plan_md]` — its `path` parameter falls to the invocation
fallback of §7.3.

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
    surface: ACT
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
    tool: assemble_plan
    reads: [header_md, tasks_md]
    writes: [plan_md]
  - id: verify
    type: SENSE
    owner: code
    tool: verify_has_tasks
    reads: [plan_md]
    writes: [plan_ok]
  - id: save
    type: ACT
    surface: artifact
    owner: code
    tool: save_plan
    reads: [plan_md]
    writes: [plan_file]
  - id: done
    type: TERMINAL
    owner: code
    reads: [plan_file]

edges:
  - {from: draft_header, to: write_tasks, modality: mandatory}
  - {from: write_tasks,  to: assemble,    modality: mandatory}
  - {from: assemble,     to: verify,      modality: mandatory}
  - {from: verify,       to: save,        modality: mandatory}
  - {from: save,         to: done,        modality: mandatory}
```

---

## Appendix D — The reference lowering

One AIS construct, one target form. A backend making judgment calls during lowering is a
sign the program was underspecified: fix the program, not the generated code.

| AIS construct | Jac / OSP form |
|---|---|
| a module | a `walker` plus a `node` archetype per instruction, and an entry function that builds the graph and spawns the walker |
| `walker.carries` | `walker { has <carry>: <type> = <default>; }` |
| an instruction | `node <Id> {}` plus `can n_<id> with <Id> entry { … }` on the walker |
| `edges` | `++>` connections built at graph-construction time |
| an SU instruction | a module-level `def <slot>(<operands>) -> <type> by llm();` plus a `sem` carrying `doc` and every resident knowledge item |
| `autonomy.tools` | `by llm(tools=[…])` on the slot |
| a DU instruction | a call to the bound tool function with operands threaded by §7 |
| `tools[].body` | a function in the emitted module |
| `tools[].command` | a subprocess invocation with operands threaded in signature order |
| a DU `ROUTE` | `if <guard> { visit [-->][?:Target]; } elif … else { … }` |
| an SU `ROUTE` | `visit [-->] by llm(intent=<doc>, incl_info={<read carries>})` |
| a `mandatory` edge | an unconditional `visit` inside the entry ability — it fires by construction |
| a `forbidden` edge | nothing is emitted; the transition does not exist |
| `SPAWN` | `flow` / `wait` over `root spawn <Sibling>`, one sibling per sub-task, joined into the write carry |
| `types.<Enum>` / `<Obj>` | `enum` / `obj` with a `sem` per member or field, and a default on every field |
| `TERMINAL` | an assignment to `self.report` composed from the produced carries, then `disengage` |

### D.1 Target-specific requirements

These are properties of the reference target, and a backend for it MUST observe them:

- The model is bound as module-level state and rebound by the entry function — never
  threaded through a slot as a parameter, which leaks the model specification into the
  prompt.
- `by llm()` is written with parentheses.
- A slot returning an enum does not also carry a tool list.
- A tool that writes a file creates its parent directory; a bare open inside a tool-use
  loop throws and is retried silently.
- `visit` and `here` appear only inside an entry ability, never in a plain method — the
  latter compiles and fails at run time.
- One repair slot per error class. Widening a repair's semantic operand to a second class
  of error is the tightening requirement (§4.1) violated on the recovery path.

---

## Appendix E — Related documents

| Document | Role |
|---|---|
| [writing-ag-ir.md](writing-ag-ir.md) | the authoring tutorial: how to write a program, with the failure-mode table |
| [../../src/contracts/agir-primitives.md](../../src/contracts/agir-primitives.md) | design rationale: the four views of the graph, the principles behind unit assignment, the composite shapes |
| [../../src/contracts/agir-standard.md](../../src/contracts/agir-standard.md) | the lowering contract in backend terms |
| [agir-cookbook/](agir-cookbook/) | conforming programs, one per archetype |
