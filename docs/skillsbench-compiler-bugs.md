# Compiler bugs found by running compiled artifacts on SkillsBench

> **Names.** This log was written before Sigil adopted the SIGIL paper's
> vocabulary. Opcodes and gate ids here are the old ones: GEN-RAW/GEN-EDIT/GEN-FILL/
> GEN-ENUM are now GENERATE/MUTATE/EXTRACT/SELECT, SENSE is OBSERVE, ROUTE is BRANCH,
> and G7/G10/G11/G14 are G6_ENV/G1_TRACE/G2_EMBODY/G4_INPUT. See
> [ais-spec.md Appendix F](reference/ais-spec.md#appendix-f--the-version-01-encoding).


A running log of the **compiler** defects behind each observed artifact failure.
The point of the list is that none of these were visible in the IR, in
`jac check`, or in any gate: every one of them only appears when the artifact is
executed against a real task, and each was hiding behind the one above it.

Method that made them findable: a direct-run harness that executes ONE artifact
against its task fixture inside the task's own image and then runs the task's
real verifier. About a minute per iteration instead of a full agent bench cell,
with `AGIR_PROGRESS` on so the node trace is visible.

---

## B1 — A two-way branch lowered as one linear chain

**Layer:** lift (graph shape)
**Seen in:** `pdf` / court-form-filling, every cell 0/5

SKILL.md branches on a check: a PDF **with** AcroForm fields is filled by
`scripts/fill_fillable_fields.py` and that is the deliverable; a PDF **without**
them goes through a bounding-box + annotation pipeline instead. The lift emitted
both paths as one chain:

```
… → route_fillable → extract_field_info → … → fill_fields
      → locate_label_in_box_entries → … → annotate_pdf → done
```

`route_fillable` had exactly one outgoing edge, so every run did both: it filled
the real form fields correctly, then ran the annotation pipeline over the same
document, and `annotate_pdf` **overwrote the 294KB filled form with a 3.8KB
annotation-built file with no text layer**. The verifier's report — "Failed to
extract text from PDF" — described the second write, not the first.

The tell was in the artifact's own output: `is_fillable=True` *and* a
bounding-box gate verdict in the same report. Two mutually exclusive branches
both reporting is the signature.

**Fix (IR):** make the ROUTE a real two-way split, move the two shared
preparation steps above it, and end the fillable branch at its own deliverable:

```
detect_fillable → extract_field_info → render_pages → route_fillable
  route_fillable --[is_fillable == true]--→ analyze_fillable_fields → … → fill_fields → done
  route_fillable --[is_fillable == false]-→ locate_label_in_box_entries → … → annotate_pdf → done
```

**Compiler lesson:** a ROUTE node with one out-edge is a lift failure, not a
degenerate branch. Worth a gate: `ROUTE` with `< 2` guarded successors, or with
successors that reconverge into another branch's exclusive chain.

---

## B2 — The deliverable path was bound to an intermediate writer

**Layer:** autofix `_fix_derived_outputs`
**Seen in:** `pdf`, deliverable was 2216 bytes of JSON

The output lift binds a caller-supplied `output_path` onto ACT tools that write a
file. It bound it to **every** ACT writer, so two tools received the same path:

```python
self.values_file = _write_field_values(self.field_values_json, (self.output_path or …))
self.filled_pdf  = _fill_fillable_fields(self.pdf_path, self.values_file, (self.output_path or …))
```

`write_field_values` wrote `field_values.json` **to `/root/sc100-filled.pdf`**,
and `fill_fillable_fields` then read that file back as its values file and wrote
its output over the same path. The deliverable was a copy of the tool's own JSON.
`field_values.json` never existed on disk, which is what gave it away.

**Fix:** an ACT writer whose written carry is **read by another node** is an
intermediate and keeps its derived filename. Only a writer whose output nothing
consumes is a deliverable. Implemented as `_consumed_downstream(ir, tool)`.

**Compiler lesson:** "writes a file" is not "produces the deliverable". The
dataflow already says which is which; the pass just was not asking.

---

## B3 — `runpy` does not work under the jac runtime

**Layer:** emitted runtime helper (`envbind.runpy_src`)
**Seen in:** `pdf`, `ModuleNotFoundError: No module named 'extract_form_field_info'`

The in-process runner (B4's fix) executed sidecar scripts with
`runpy.run_path(script, run_name="__main__")`. Under the jac runtime that goes
through jac's import machinery and fails with a module-not-found error **naming
the script file**, while the identical call under system python runs it fine —
verified side by side in the same container.

**Fix:** read, `compile()`, and `exec()` the file with an explicit
`__name__ == "__main__"` globals dict, and put the script's own directory on
`sys.path` (these scripts import their siblings, e.g.
`from extract_form_field_info import get_field_info`).

---

## B4 — A spawned interpreter cannot see the artifact's own dependencies

**Layer:** tool lowering
**Seen in:** `pdf`, 12/12 calls `No module named 'pypdf'`

Tools shell out with `subprocess.run([sys.executable, script, …])`. Under jac,
`sys.executable` is **the jac binary**, and the child's module path is the
runtime closure — which does not include the artifact-local `.jac/pydeps` the
preflight installed into. jac also ignores `PYTHONPATH`, so the child could not
be fixed from outside either. The manifest was correct and the install succeeded;
the work was simply handed to a process that could not see it.

**Fix:** rewrite the callee only (`_sigil_run_py`), preserving every argument,
keyword, and the `.returncode` / `.stdout` / `.stderr` surface. Calls to real
binaries (`subprocess.run(["pdftotext", …])`) are left alone.

Two traps this exposed: the helper is pasted into a `.jac` module and must be
fenced as `::py::` (bare, `class _SigilProc:` parses as Jac and the module dies
with `Expected '-->', got 'NAME'`), and a **stale `.jac` cache** served the old
lowering long after the source changed.

---

## B5 — Only one kind of model slot was unfenced

**Layer:** slot lowering
**Seen in:** `xlsx` / exceltable, 16 of 18 calls `REBUILD FAILED: invalid syntax (<unknown>, line 1)`

`_strip_fences` was applied to GEN-RAW string slots only. `fix_errors` is a
**GEN-EDIT** slot returning a corrected build script; its ` ```python ` line
survived, was written to `_sigil_build_model_fixed.py`, and executed. Reproduced
byte-for-byte by running a fenced `.py` under jac.

**Fix:** unfence every model slot that writes a `str` carry. The helper only
fires when the whole output is one fenced block, so a document containing fenced
examples is untouched.

---

## B6 — A destination parameter was skipped when the node read a source

**Layer:** autofix `_fix_pathish_params`
**Seen in:** `docx` / offer-letter, 0/4 on the run where the deliverable vanished

The pass short-circuited on any node that already read a pathish carry, on the
theory that the binder's role rung was served. `fill_template(template_file,
fill_data, path)` reads `template_file`, so `path` — the **destination** — never
got a lane. The deliverable went to `_outname(task)`, and on a task whose
sentence named no file that is the literal fallback `out_file.out`.

**Fix:** the short-circuit applies to source parameters only. A write target is
never served by the source the node reads.

---

## B7 — An existence check silenced a correctable error

**Layer:** autofix `_fix_unguarded_reads` (my own regression, caught and fixed)
**Seen in:** `docx`, 3/4 → 0/4

An omitted optional input arrives as `""` and was reaching an unguarded `open()`
(`FileNotFoundError: ''`, ten times in one energy-ac cell). The first guard
returned the declared type's empty value when the path was empty **or did not
exist**. The first time the agent passed a *relative* path, that turned a loud,
self-correcting failure into a silent no-op that produced no document at all.

**Fix:** guard the **omitted** case only. A non-empty path that does not resolve
is a caller error, and raising is what lets the caller correct it.

**Lesson:** "route on absent instead of raising" is right only when the graph
actually routes and the input is genuinely optional. Otherwise it converts a
recoverable error into a silent zero.

---

## B8 — An injected override landed inside a multi-line statement

**Layer:** autofix body injectors
**Seen in:** `pdf`, artifact raised `SyntaxError` on every run

The injectors matched an assignment by line regex and appended the override after
that *line*. A statement can span several:

```python
out_img = os.path.join(os.path.dirname(img) or ".",
out_img = output_path or out_img                      # ← injected here
                       "validation_page_%d.png" % page_number)
```

The IR round-tripped, the module lowered, and `jac check` passed, because the
gates read the IR and not the tool bodies.

**Fix:** `_stmt_ends` (bracket depth, strings stripped) defers the override to
the end of the statement; `_in_loop` refuses to lift a destination assigned
inside a loop; `_injected_ok` re-parses and discards any injection that breaks a
body that used to parse.

---

## B9 — A deliverable path names a format

**Layer:** `write_file` builtin
**Seen in:** `power-flow-data` / energy-ac, all 24 checks `JSONDecodeError` at char 0

The output-name fallback reads the filename out of the task, so a skill that
produces a Markdown report wrote it to the `report.json` the task asked for. The
agent, which had the analysis and could have written real JSON, found the file
already there.

**Fix:** refuse a `.json` path whose content is not JSON, preserve the content
beside it as `.md`, and say so in the return. An absent deliverable is
recoverable; a corrupt one is not.

---

## B10 — Fan-in re-runs the whole downstream chain

**Layer:** lift / traversal
**Seen in:** `pdf` node trace

`detect_fillable` has three mandatory in-edges (`plan_streaming`, `resolve_pdf`,
`extract_structured_tables`). The trace shows the walker entering it once per
incoming path and re-running everything below it:

```
detect_fillable ×3   extract_field_info ×3   render_pages ×3   route_fillable ×3
analyze_fillable_fields ×2   author_field_values ×2   save_field_values ×2
```

Every repeat is a duplicated model call and a duplicated file write. It did not
change the outcome here because the writes are idempotent, but it is real cost
and a real nondeterminism risk wherever they are not.

**Not yet fixed.** A node should run once per traversal regardless of how many
mandatory edges converge on it.

---

## B11 — A conditional deleted the content it was asked to keep

**Layer:** lift (tool logic)
**Seen in:** `docx` / offer-letter, the one failing group at 3/4 — now **4/4**

The template marks a block `{{IF_RELOCATION}}…{{END_IF_RELOCATION}}` and the task
says keep it when **RELOCATION_PACKAGE** is Yes. The lifted tool did:

```python
keep = bool(data.get(key))          # key == "RELOCATION"
```

Two bugs in one line:

1. **Name.** The marker names the *condition*; the data names the *field*.
   `"RELOCATION"` is not a key, so `.get` returned `None` and the block was
   deleted — markers **and** content. The document read "Relocation Assistance:"
   followed by nothing.
2. **Truthiness.** Even with the right key, `bool("No")` is `True`, so a "No"
   would have kept a block that must be dropped. The values are Yes/No strings,
   not booleans.

**Fix:** resolve the marker against the data's own field names (exact, then
prefix, then ignoring underscores), read Yes/No/true/false/0/1 as words, and —
when no governing field exists at all — **keep** the content. Deleting document
content on a missing key is unrecoverable; keeping it is not.

**Compiler lesson:** the destructive default is the wrong default. Anywhere a
lowered tool decides whether to remove task content, absence of evidence must
not mean remove.

---

## What each fix was worth

Measured on the same five cells, gpt-4o, compiled arm:

| Cell | Before | After | Prose |
| --- | --- | --- | --- |
| offer-letter / docx | 3/4 | **4/4** | 2/4 |
| court-form / pdf | 0/5 | **2/5** | 2/5 |
| energy-ac / power-flow | 0/24 | 0–12/24, unstable | 0/24 |
| exceltable / xlsx | 0/8 | 0–7/8, unstable | 0/8 |
| pddl-airport | 1/2 | 1/2 | 1/2 |

Two cautions on that table. The bench collapses many parametrized checks into a
few named groups and a group passes only if every case in it passes, so pdf's
"2/5" is **27 of 35 individual checks**. And energy-ac and exceltable swing
between runs because the *agent*, not the artifact, is doing the work in those
two — verified by counting tool calls: in one exceltable run the compiled tool
was called 60 times and succeeded zero times while the cell scored 7/8.

Only docx, pdf and pddl are artifact-driven. In the docx cell the agent calls the
compiled tool three times, binds the destination, and finishes — no terminal, no
file editing.

## Still open, and not compiler bugs

- **pdf**, 27/35 raw checks passing. The remaining 8 are the model filling
  court-only fields the task said to leave empty. Model behaviour, not plumbing.
- **exceltable is a scope mismatch.** The task is a pptx job with an embedded
  worksheet; the compiled skill under test is the xlsx financial-model builder,
  whose pipeline is "build a model from assumptions", not "patch one cell in an
  embedded workbook". That is why its tool fails every call. The cell does not
  measure the compiled artifact.
- **energy-ac** writes at the right path with the right input; the skill produces
  a Markdown report where the task wants JSON. Scope mismatch, and prose ties at
  0/24.
- **pddl** writes `; FAILURE: no plan exists`. Both arms tie at 1/2.
- **Authored inputs carry no doc,** so `docx`'s `template_file` and `data_file`
  keep the generic MCP description. Only minted carries get a real one.
- **`osp_runtime.py.txt` still contains a `subprocess.run([sys.executable, …])`**
  in its script-repair loop — the same B4 defect, in the shared runtime asset.
  None of these five skills reach it.
