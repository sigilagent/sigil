---
name: writing-agir
description: Use when authoring an AG-IR — the typed intermediate representation Sigil lowers into a runnable agent — from a SKILL.md and its frozen rule set, verifying each draft with the compile oracle until every gate passes.
---

# Writing an AG-IR

You are the front-end of a compiler. Your input is a **SKILL.md** written for a
human, plus a **frozen rule set** already extracted from it. Your output is one
file, `agent.ir`: a YAML AG-IR that Sigil lowers mechanically into a runnable
object-spatial program.

The point of the AG-IR is that it removes the model's discretion. In a prompt-based
harness a skill is advice the model may follow. Here every mandatory step becomes a
node the run **must visit**, every prohibition becomes a constraint on a node, and
every verification becomes a gate with a typed verdict. Your job is to build that
structure faithfully — not to improve the skill, and not to summarize it.

## The three things that get checked

Your draft is not accepted because it looks right. It is accepted because it clears
three gates, and each one maps to a rule you must follow while drafting.

**G4 — it must compile.** `sigil gate agent.ir <name>` lowers your IR and
type-checks the result. Run it after every edit. It exits nonzero while the IR is
broken and prints the exact diagnostic.

**G1 — every tool and knowledge item must be embodied.** A tool with no `body:` and
no `command:` is a prose-pointer, and it is rejected. Knowledge must carry its
content **verbatim**, never "see the section above" or "follow the format in
FORMS.md". The test: if `SKILL.md` were deleted, would the IR still lower to a
working agent? If the answer depends on prose that only lives in the skill, embody
that prose in the IR.

**G5 — every mandatory rule must be realized by a node.** Each rule in the frozen
set has an id (`r1`, `r2`, …). Each node carries `traces_to: [r3, r7]` naming the
rules it realizes. A mandatory STEP or IO rule with no node tracing to it is a
structural gap and fails. Worse than missing is *monolithic*: several rules folded
into one model slot, so nothing guarantees each was done. Give a rule its own node
when it is its own obligation.

Prefer `owner: code` where the rule is mechanical — a code node is **guaranteed by
construction**. A model slot is only *observable*. Reserve model slots for genuine
judgment.

## Prohibitions are not steps

A rule the skill states as a prohibition ("never modify the input", "always
lowercase before counting") is not a step to add — it is a property the run must
have. Realize it, in this order of preference:

1. **In code.** "Always lowercase before counting" belongs inside the counting
   tool's body, where it cannot be skipped. This is the strongest form.
2. **By construction.** "Never modify the input" is satisfied by a read-only
   read; say so in the node's `doc` so the choice is legible.
3. **In the node's `doc`.** For a prohibition binding a model slot, put it in the
   `doc` of every model node it constrains — the compiler folds `doc` into the
   slot's sem, which is where a prohibition binds at run time.

Trace the rule from whichever node realizes it. A prohibition that appears
nowhere in the IR has been dropped, even if the IR compiles.

## Procedure

1. **Read `SKILL.md` and `rules.md` in full.** `rules.md` is the frozen rule set,
   already grounded — each rule quotes the skill verbatim. It is the anchor: your
   IR is audited against it, not against your reading of the prose.

2. **Read `agir-template.md`.** It is the compiler-exact shape, with a complete
   working example. Deviating from its keys makes the IR fail to lower.
   `agir-primitives.md` and `agir-standard.md` are the full reference when the
   template does not cover a case.

3. **Draft the carries.** The typed values that flow through the run: the input,
   each intermediate, the final artifact. Every carry that is not `role: input`
   names the node that `produced_by` it.

4. **Draft the nodes**, one per obligation, in the skill's order. Set `owner: code`
   for anything deterministic and `owner: model` only for judgment. Give every node
   `traces_to` naming the rules it realizes. Steps the skill states as mandatory
   must be on the mandatory path — never behind an optional edge.

5. **Embody the tools.** Any `owner: code` node needs a tool with a real `body: |`
   (Python) or an exact `command:`. Copy code snippets from the skill **verbatim** —
   the agent must run the skill's prescribed code, not a paraphrase of it.

6. **Wire the edges.** Required. Without them the walker stops after the first node.
   Entry node first, exactly one `TERMINAL` last.

7. **Verify.** Run the oracle:

       sigil gate agent.ir <name>

   Read the diagnostic, fix exactly what it names, run it again. Repeat until it
   prints `gate: ok`.

8. **Re-check faithfulness before you stop.** Walk `rules.md` top to bottom and
   confirm each mandatory rule appears in some node's `traces_to`. A compiling IR
   that dropped a rule is a worse outcome than one that failed to compile.

## Rules

- **Never invent an obligation.** If it is not in the skill, it does not belong in
  the IR. The rule set is the contract.
- **Never re-modalize.** A "when uncertain, ask" is conditional; compiling it as an
  unconditional step is a faithfulness violation. So is turning a SHOULD into a MUST.
- **Never summarize embodied content.** Verbatim or not at all.
- **Output valid YAML.** Put code in `body: |` block scalars. Never emit a raw
  `::py::` block, and never leave an unescaped `:` in an unquoted value.
- **Bind registered MCP tools by their exact name** as SENSE/ACT nodes — do not
  re-script a tool that already exists.
- **Edit `agent.ir` only.** Do not create other files.

## When you are done

`sigil gate agent.ir <name>` prints `gate: ok`, and every mandatory rule in
`rules.md` is traced by a node. Then stop and reply with the single word `DONE`.
