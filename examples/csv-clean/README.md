# csv-clean — a SKILL.md compiled by the compiler, running on a local model

This bundle takes a plain-markdown skill, runs it through **`sigil compile`**, and
executes the result on a **fully-local model** (`gemma4:e4b` via Ollama — no API
key, nothing in the cloud).

Unlike [`writing-plans`](../writing-plans), whose AG-IR is hand-authored, everything
here is **produced by the compiler**. The `.agir` and the `.jac` in this directory
are compiler output, not hand-tuned artifacts.

## Run it

```bash
ollama pull gemma4:e4b

cd examples/csv-clean
SIGIL_MODEL=ollama_chat/gemma4:e4b ./csv-clean.jac messy.csv
```

The cleaned file lands next to you as `cleaned.csv`. Run from *this* directory —
the skill writes `cleaned.csv` into the working directory.

To rebuild the artifacts from the skill (needs a frontier key for the compile):

```bash
sigil compile examples/csv-clean/SKILL.md -e examples/csv-clean/csv-clean.jac
```

## The input

`messy.csv` is a realistic export: five columns whose headers carry units,
punctuation and parenthetical qualifiers, plus three fully-empty rows.

```
First  Name,Last-Name,Cust. E-mail (primary),Signup Date (UTC),Total Spend ($)
```

The headers are chosen so a *literal* character substitution mangles them —
`cust__e_mail__primary_`, `total_spend____`. Getting them right takes judgment,
which is the one thing in this skill the model is asked to do:

```
first_name,last_name,customer_email,signup_date,total_spend
```

## The three files, and the pipeline they trace

| file | what it is |
|---|---|
| [`SKILL.md`](SKILL.md) | the source skill — plain-markdown instructions |
| [`csv-clean.agir`](csv-clean.agir) | the **AG-IR**: the skill as a typed graph, emitted by the compiler |
| [`csv-clean.jac`](csv-clean.jac) | the ejected runnable — the mechanical lowering of the AG-IR |

The compiler turned the skill into **16 nodes**, of which exactly **two** call a
model:

```
read_input_csv ─▶ decide_column_meanings ─▶ apply_header_rename ─▶ drop_empty_rows
   (SENSE)            (GEN-FILL, model)          (CODE)                (CODE)
                                                                         │
                                    ┌────────────────────────────────────┘
                                    ▼
                          write_cleaned_csv ─▶ re_read_output_csv ─▶ spawn_verifications
                               (ACT)                (SENSE)               (SPAWN)
                                                                             │
        ┌────────────────────────────────────────────────────────────────────┤
        ▼           ▼             ▼              ▼               ▼            ▼
   parses_ok   header_regex   uniqueness   column_count    row_count     header_order
    (CODE)        (CODE)         (CODE)        (CODE)          (CODE)          (CODE)
        └───────────┴─────────────┴──────────────┴───────────────┴────────────┘
                                    ▼
                            verification_gate ──▶ done
                                (ROUTE)      └──▶ fix_output ──▶ (back to rename)
                                                  (GEN-EDIT, model)
```

- **`decide_column_meanings`** is the judgment slot, and it is typed:
  `(input_headers: list[str]) -> list[str] by llm`. The model is handed the actual
  headers and must return names — it is not free-styling a CSV.
- **Everything mechanical stayed mechanical.** Renaming, dropping empty rows and
  writing the file are `CODE`/`ACT` nodes. The model never touches the data rows.
- **Six independent verifications** fan out from a `SPAWN` and converge on a
  `ROUTE` gate: does it parse, is every header snake_case, are they unique, does
  the column count match, does the row count equal input-minus-empty, and did the
  written header match what was proposed.
- **`fix_output`** is the repair path the gate takes when a check fails.

That is the point of compiling a skill: on a small model a prompt's rules are
optional, but a node the walker must visit is not — and a gate it must satisfy
cannot be talked around.

## Honest notes

**This demo is not yet reliable.** On `gemma4:e4b` it converges when the naming
slot returns clean output on the first pass, and can spin when it does not. The
cause is in the graph, not the model:

`fix_output` is wired as
`(proposed_headers, check_parse_ok, check_regex_ok, check_unique_ok, check_colcount_ok, check_rowcount_ok) -> list[str]`.
It receives **booleans and its own previous guess** — never `input_headers` or the
target column count. So when told "the column count is wrong" it cannot know the
answer is five, and a small model fills the gap by inventing a column
(`extra_column`, `placeholder_column`). The gate correctly rejects that, and the
loop repeats until `AGIR_STEP_BUDGET` (default 256) trips.

The gate is doing its job — it never let bad output through. What is missing is a
repair node that can see what it is repairing. That is the closed-loop
compile → run → repair gap tracked in
[issue #83](https://github.com/sigilagent/sigil/issues/83).

Worth stating plainly: the model is not the weak link here. Called in isolation
with the same prompt, `gemma4:e4b` returns the ideal answer in ~7s:

```
['first_name', 'last_name', 'customer_email', 'signup_date', 'total_spend']
```

**Two lowering bugs had to be fixed before this ran at all**, both found by
building this demo and both model-independent:

- a `SPAWN`'s fan-out only visited its *first* child, so five of the six
  verifications never executed;
- a code-owned `ROUTE` never called the tool that computes its own guard, so
  `all_checks_passed` stayed `False` forever.

Before those fixes, every model — qwen2.5:1.5b, gemma3n:e4b, gemma4:e4b — failed
identically at `verification_gate`, which is what pointed at the compiler rather
than the models.

## Inspecting a run

Every node entry is traceable:

```bash
AGIR_PROGRESS=/tmp/agir.jsonl SIGIL_MODEL=ollama_chat/gemma4:e4b ./csv-clean.jac messy.csv
python3 -c "import json;[print(json.loads(l)['node']) for l in open('/tmp/agir.jsonl')]"
```

Cap a run that is not converging with `AGIR_STEP_BUDGET=60`.
