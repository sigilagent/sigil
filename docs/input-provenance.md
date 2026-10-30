# Input provenance: making a compiled skill callable

A prose skill is *read* by an agent. A compiled skill is *called* by one. That
difference is the whole of this document.

When an agent reads SKILL.md, the file locations stay in the conversation: the
agent knows the task said `/root/network.json`, and it types that path into
whatever command it runs. When an agent calls a compiled artifact over MCP, the
locations have to cross a typed boundary. Everything the artifact needs from the
outside world must be a **parameter** — named, typed, and described — or the
artifact is left guessing at filenames from the task sentence.

This is the defect class that kept SkillsBench cells at zero while every
individual piece of the compiled program worked. The sections below are the
eight distinct bugs found, in the order they were hit, each with the live
evidence. The last four are not about provenance at all: they are what became
visible once the parameters were right, and each one had been hiding behind the
one before it.

---

## 1. The parameter surface did not exist

**Symptom.** `_EJ_PARAM_KEYS = []` in every artifact. The MCP schema advertised
one property, `task`, so the calling agent could pass only a sentence. The
artifact then mined filenames out of that sentence with a regex.

**Why it happened.** Skill authors write tools that resolve their own paths,
because that is what works when a human runs the script:

```python
def resolve_pdf_path(task: str) -> str:
    m = re.search(r"([\w.-]+\.pdf)", task)
    return m.group(1) if m else "form.pdf"
```

The lift preserved this faithfully. Nothing was wrong with the code; it simply
had no input surface. Whichever path the sentence mentioned first became the one
that was opened — offer-letter-generator opened its own *output* as the
template, and every cell failed while the delivery layer worked perfectly.

**Fix.** Five passes that turn a resolved location into a declared one:

| Pass | Fires when |
| --- | --- |
| `_fix_task_scraped_inputs` | a tool derives a pathish local from its `task` argument |
| `_fix_resolver_inputs` | a whole node exists only to resolve a path out of prose |
| `_fix_derived_outputs` | a tool invents the name of the deliverable it writes |
| `_fix_pathish_params` | a tool signature names a location the walker carries nowhere |
| `gate_input_provenance` (G14-IN) | reports whatever is left, as an error |

Each mints a `role: input`, `type: path` carry, widens the tool's inner `def`,
and injects an override so a caller-supplied value wins. **The original
derivation stays as the fallback**, so an unnamed call behaves exactly as it did
before. The lowering already turns `role: input` carries into `--flags`,
`_EJ_PARAM_KEYS`, and MCP schema properties, so one declaration reaches all
three callers.

The rule now stated in the io_view lift prompt: *every external artifact whose
location the skill does not fix is its own `role=input`, `type=path` carry;
prose-mining may be a fallback inside a tool, never the only way in.*

---

## 2. The destination was bound to the wrong file

Two separate bugs wore the same costume.

**The input template got the output path.** `_bind_args` filled every pathish
parameter from the first matching carry, so a docx tool lowered to
`_fill_template(self.template_file, ..., (self.template_file or _outname(...)))`
— reading and writing the same file. Fixed by threading a `used` list through
the binder and refusing an *input* carry when the parameter is a write target.

**The output path went to an intermediate.** The output lift took the first tool
whose body wrote a file. In the pdf pipeline that is `extract_form_field_info`,
which writes `fields.json` on the way to the real deliverable. The caller's
`sc100-filled.pdf` was handed to a JSON writer. Fixed by ordering candidates
with ACT nodes first and lifting every ACT writer (a ROUTE'd pipeline delivers
from more than one branch), while non-ACT writers stay first-match-only.

---

## 3. The schema named the parameters but never described them

**Symptom.** Bindings that were syntactically perfect and semantically wrong.
energy-ac's agent called the artifact 32 times, every time with:

```
network_path = /root/math-model.md     # the maths write-up
size_path    = /root/report.json       # the file it meant to produce
```

with `network.json` sitting in the same directory the whole time.

**Why it happened.** Every property in the emitted `inputSchema` read:

```json
{"network_path": {"type": "string", "description": "Exact value for input 'network_path'."}}
```

The description says the name back to the caller. With nothing else to go on,
the model matched on the name alone, and two path parameters of the same shape
were *byte-identical* to it.

**Fix.** Describe each input by what it holds, from two facts already in scope
when the carry is minted:

- **the file type**, via `path_ext_hint`. The lift states it twice — in the
  scrape pattern (`\.(json|csv)`) and in the literal fallback
  (`"network.json"`) — and lifting the name to a parameter threw both away.
  When the tool takes `path` as a parameter there is no filename in it at all,
  so the **opener** is read instead: `json.load` says `.json` as plainly as a
  filename would, and likewise `load_workbook`, `Document`, `PdfReader`,
  `pd.read_csv`, `yaml.safe_load`.
- **the consuming tool's own doc**, which the IR already carried and nothing
  used.

The artifact now emits `_EJ_PARAM_DOCS` beside `_EJ_PARAM_KEYS`, and
`_mcp_serve` uses it for the property descriptions:

> **network_path** — Path to the .json file this run READS, the one
> `load_network` opens (load_network: Load network data from JSON with Python's
> json parser in one call. Returns baseMVA, bus, gen, branch…). It must be that
> file itself, not a document that describes or refers to it. Optional
> (caller-supplied); defaults to a filename named in the task.
>
> **size_path** — Path to the file this run READS, the one `check_file_size`
> opens (check_file_size: If needed, check the file size: line count and
> human-readable size). …

**Result.** The agent bound `network_path=/root/network.json` on every call.

The phrase *caller-supplied* is load-bearing in a second way: it marks a lane as
minted rather than authored, which is how an IR is reset to its authored shape
before a re-lower. Keep it, lowercase, in every branch.

---

## 4. An injected override broke the body it was injecting into

**Symptom.** The artifact raised, on every run:

```
SyntaxError: sigil: tool body failed to parse as Python;
the compiler refused to emit a string stub for it
```

**Why it happened.** The injectors matched an assignment with a line regex and
appended the override after that *line*. A statement can span several:

```python
out_img = os.path.join(os.path.dirname(img) or ".",
out_img = output_path or out_img                      # <- injected here
                       "validation_page_%d.png" % page_number)
```

The IR still round-tripped, the module still lowered, and `jac check` still
passed, because the gates read the IR and not the tool bodies. The artifact
raised only when the walker reached that tool — which is every run. The agent
retried twelve times against a perfectly-bound `pdf_file` and `output_path`.

**Fix**, three parts:

- `_stmt_ends` tracks bracket depth (strings and comments stripped first), so an
  override is emitted only once the statement it overrides has closed.
- `_in_loop` refuses to lift a destination assigned inside a `for`/`while`. A
  path re-bound every iteration is not a deliverable path:
  `create_validation_images` writes one image per page, and pointing the
  caller's `output_path` at it would send every page to the same file.
- `_injected_ok` re-parses the rewritten body and discards the injection if a
  body that used to parse no longer does. **A mechanical pass must never leave a
  body that does not parse**, and nothing downstream was checking.

---

## 5. The artifact left the interpreter that held its dependencies

**Symptom.** `No module named 'pypdf'` on all twelve calls, with `pypdf` sitting
in `_ENV_MANIFEST`, installed by the preflight, and importable in the parent.

**Why it happened.** The tool shells out:

```python
proc = subprocess.run([sys.executable, script, pdf_path, fields_file, out_pdf],
                      capture_output=True, text=True)
```

Under jac, `sys.executable` is the **jac binary**, verified directly:

```
sys.executable = /Users/…/.local/bin/jac
```

jac will run a `.py` child, but that child's module path is the runtime closure.
It does not include the artifact-local `.jac/pydeps` the preflight installed
into, and jac does not honour `PYTHONPATH`, so the child cannot be fixed from
outside either. The artifact bound its environment correctly and then handed the
work to a process that could not see it.

**Fix.** `_sigil_run_py`, emitted into any artifact that needs it, runs the
script in **this** interpreter via `runpy`, capturing stdout and stderr and
mapping `SystemExit` to a return code. A mechanical rewrite points the call at
it, changing only the callee:

```python
proc = _sigil_run_py([sys.executable, script, pdf_path, fields_file, out_pdf],
                     capture_output=True, text=True)
```

Every argument, keyword, and the `.returncode` / `.stdout` / `.stderr` surface
are untouched, so the body around it is unchanged. A call to a real binary
(`subprocess.run(["pdftotext", …])`) is not rewritten.

Two traps worth recording. The helper is pasted into a `.jac` module, so it must
be fenced as a `::py::` block — emitted bare, `class _SigilProc:` is parsed as
Jac and the whole module fails with `Expected '-->', got 'NAME'`. And the box
served a **stale `.jac` cache**: the rewrite was in the source and absent from
the output until the cache was cleared.

## 6. A fence was only stripped off one kind of slot

`_strip_fences` was applied to GEN-RAW string slots only. xlsx's `fix_errors` is
a **GEN-EDIT** returning the corrected build script, and its ```` ```python ````
line survived, was written to `_sigil_build_model_fixed.py` and executed:
16 of 18 calls returned `REBUILD FAILED: invalid syntax (<unknown>, line 1)`.
Reproduced byte-for-byte by running a fenced `.py` under jac. Every model slot
that produces text is now unfenced; the helper only fires when the whole output
is one fenced block, so a document containing fenced examples is untouched.

## 7. An omitted optional input reached an unguarded open

Minting an input makes it optional, and an omitted optional path arrives as `""`.
`load_network` opened it: `FileNotFoundError: ''`, ten times in one cell. The
detector for this shape already existed (`_unguarded_read_tools`, feeding G7) and
nothing acted on it. `_fix_unguarded_reads` now injects a not-found route
returning the declared return type's empty value, so absence is a branch rather
than an exception. It fires only on a bare pathish parameter opened directly, and
never on a tool that already routes.

## 8. A deliverable path names a format

The output-name fallback reads the filename out of the task, so a skill that
produces a Markdown report wrote it to the `report.json` the task asked for. All
24 checks died on `JSONDecodeError` at char 0, and the agent — which had the
analysis and could have written real JSON — found the file already there.
`write_file` now refuses a `.json` path whose content is not JSON, preserves the
content beside it as `.md`, and says so in its return. An absent deliverable is
recoverable; a corrupt one is not.

## What this did and did not fix

The parameter surface is now correct and demonstrably used. Across the two cells
that were diagnosed end to end:

- **court-form-filling / pdf** — binds `pdf_file=/root/sc100-blank.pdf` and
  `output_path=/root/sc100-filled.pdf`, correctly, on every call.
- **energy-ac / power-flow-data** — binds `network_path=/root/network.json` on
  every call, and writes `report.json` at that name.
- **offer-letter-generator / docx** — 3/4, ahead of the prose arm's 2/4.

Both cells still fail their verifiers, for causes that are *not* about
provenance and are recorded here so they are not rediscovered:

1. **Sidecar-script dependencies are not in the manifest.** `pdf` ships
   `scripts/fill_pdf_form_with_annotations.py`, which imports `pypdf`. The
   manifest is extracted from *tool bodies*, so a module imported only by a
   shipped script never reaches it and the preflight never installs it. The
   artifact fails with `No module named 'pypdf'` while the agent's own
   `pip install pypdf` lands in an interpreter the rt-closure never sees. This
   is the G7-ENV class, one level of indirection out.
2. **An empty path default reaches an unguarded `open`.** `size_path` defaults
   to `""`, and `check_file_size` opens it: `FileNotFoundError: ''`. An optional
   input needs a not-found route, which is the `_unguarded_read_tools` class.
3. **Format, not plumbing.** power-flow-data writes Markdown into `report.json`.
   The deliverable lands at the right path with the right name and the wrong
   content — a generation problem in the compiled agent, downstream of
   everything above.
4. **Authored inputs carry no doc.** `docx` declares `template_file` and
   `data_file` in the IR itself, so no pass mints them and they keep the generic
   description. The io_view prompt should require a doc on every declared input,
   the way the minting passes now produce one.

---

## Tests

| File | Covers |
| --- | --- |
| `envbind.test.jac` | `path_ext_hint` from literals, from alternations, from openers; a generic file probe claims no type; a literal beats an opener |
| `autofix.test.jac` | minted inputs documented by content; two same-shaped inputs get distinguishable text; an override never lands inside a multi-line statement; a loop-bound destination is not lifted; an unparseable injection is refused |
| `compiler.test.jac` | a destination is never bound to an input carry; the spawn fallback for a single pathish input |
| `gates.test.jac` | G14-IN reports a tool that mines its own paths |
