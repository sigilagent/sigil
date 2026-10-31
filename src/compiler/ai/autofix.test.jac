"""autofix — the mechanical fix-forward passes. Pure code, no model."""

import os;
import tempfile;
import yaml;
import from src.compiler.mechanical.compiler { _load_ir }

def _yaml(ir: dict[str, any]) -> str {
    return str(yaml.safe_dump(ir, sort_keys=False));
}

test "a node read naming a skill-dir file is inlined as knowledge" {
    d = tempfile.mkdtemp(prefix="sigil_afx_");
    os.makedirs(os.path.join(d, "templates"), exist_ok=True);
    with open(os.path.join(d, "templates", "viewer.html"), "w") as f {
        f.write("<html>the viewer scaffold</html>");
    }
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [{"id": "n_read", "type": "SENSE", "owner": "model",
                   "reads": ["templates/viewer.html"], "writes": []}],
        "edges": []
    });
    r = autofix_ir(ir, d);
    assert len([f for f in r["fixes"] if "templates/viewer.html" in str(f) and "inlined" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    kn = out["knowledge"]["templates/viewer.html"];
    assert "viewer scaffold" in str(kn["body"]);
    assert "n_read" in list(kn["resident_on"]);
}

test "an unresolvable read is minted as an input carry, an undeclared write as a lane" {
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [{"id": "n_a", "type": "GEN-FILL", "owner": "model",
                   "reads": ["user_request"], "writes": ["summary"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    out = _load_ir(str(r["ir_text"]));
    carries = out["walker"]["carries"];
    assert carries["user_request"]["role"] == "input";
    assert carries["summary"]["produced_by"] == "n_a";
    assert len(list(r["fixes"])) == 2;
}

test "a pointer knowledge body is embodied from the skill dir" {
    d = tempfile.mkdtemp(prefix="sigil_afx_");
    with open(os.path.join(d, "FORMS.md"), "w") as f {
        f.write("# Forms\nthe real reference content");
    }
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [{"id": "n_a", "type": "GEN-RAW", "owner": "model", "reads": ["forms_ref"], "writes": []}],
        "edges": [],
        "knowledge": {"forms_ref": {"body": "See FORMS.md for details.", "resident_on": ["n_a"]}}
    });
    r = autofix_ir(ir, d);
    assert len([f for f in r["fixes"] if "FORMS.md" in str(f) and "embodied" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    assert "real reference content" in str(out["knowledge"]["forms_ref"]["body"]);
}

test "a pointer with no resolvable file is left alone" {
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [{"id": "n_a", "type": "GEN-RAW", "owner": "model", "reads": ["forms_ref"], "writes": []}],
        "edges": [],
        "knowledge": {"forms_ref": {"body": "See NOWHERE.md for details.", "resident_on": ["n_a"]}}
    });
    r = autofix_ir(ir, tempfile.mkdtemp(prefix="sigil_afx_"));
    assert r["fixes"] == [];
    assert str(r["ir_text"]) == ir;
}

test "an escape path never resolves" {
    d = tempfile.mkdtemp(prefix="sigil_afx_");
    assert _skill_file(d, "../etc/passwd") == "";
    assert _skill_file(d, "/etc/passwd") == "";
}

test "a hollow COMPUTE is made a GENERATE; a served one is not" {
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [
            {"id": "n_hollow", "type": "CODE", "owner": "code", "reads": ["task"], "writes": []},
            {"id": "n_served", "type": "CODE", "owner": "code", "reads": ["task"], "writes": []}
        ],
        "edges": [],
        "tools": {"checker": {"body": "return 1", "serves": ["n_served"]}}
    });
    r = autofix_ir(ir, "");
    out = _load_ir(str(r["ir_text"]));
    by_id = {str(n["id"]): n for n in out["nodes"]};
    assert by_id["n_hollow"]["owner"] == "model";
    assert by_id["n_hollow"]["type"] == "GENERATE";
    assert by_id["n_served"]["owner"] == "code";
    assert by_id["n_served"]["type"] == "COMPUTE";
    assert len([f for f in r["fixes"] if "n_hollow" in str(f) and "made a GENERATE" in str(f)]) == 1;
}

test "a clean IR passes through byte-identical" {
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "out": {"type": "str", "produced_by": "n_a"}}},
        "nodes": [{"id": "n_a", "type": "GEN-RAW", "owner": "model", "reads": ["task"], "writes": ["out"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert r["fixes"] == [];
    assert str(r["ir_text"]) == ir;
}


# ---------------------------------------------------------------------------
# canonicalize — authored TEXT that is not strict YAML
# ---------------------------------------------------------------------------

# The real defect: a column-aligned carry whose key ran long enough to swallow
# the space after its colon. Seen in a shipped `pdf` IR.
glob MALFORMED_MAP_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:       { type: str, role: input }
    drafted_note:{ type: str, produced_by: draft }
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [drafted_note]
    doc: "Write the note the task asks for."
    traces_to: [r1]
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

# The other shape, from a fresh compile of skillsbench constraint-parser: a typed
# carry inside a flow map, where `[` opens a sequence YAML never sees closed.
glob MALFORMED_SEQ_IR: str = """---
name: constraint-parser
description: Extract scheduling constraints.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: ConstraintAgent
  carries:
    task:        { type: str,       role: input }
    constraints: { type: list[str], produced_by: extract }
nodes:
  - id: extract
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [constraints]
    doc: "Extract the constraints."
    traces_to: [r1]
  - id: done
    type: TERMINAL
edges:
  - {from: extract, to: done, modality: mandatory}
""";

glob CLEAN_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:
      type: str
      role: input
    drafted_note:
      type: str
      produced_by: draft
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [drafted_note]
    doc: "Write the note the task asks for."
    traces_to: [r1]
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

test "an IR that is already strict YAML is left alone" {
    assert strict_parses(CLEAN_IR);
    assert canonicalize_ir(CLEAN_IR, "canon_clean") == "";
}

test "the column-aligned flow map is not strict YAML, and canonicalizes" {
    assert not strict_parses(MALFORMED_MAP_IR);
    out = canonicalize_ir(MALFORMED_MAP_IR, "canon_map");
    assert out;
    assert strict_parses(out);
}

test "the unclosed-sequence shape canonicalizes too" {
    assert not strict_parses(MALFORMED_SEQ_IR);
    out = canonicalize_ir(MALFORMED_SEQ_IR, "canon_seq");
    assert out;
    assert strict_parses(out);
}

test "canonicalizing preserves the carry the malformed line encoded" {
    out = canonicalize_ir(MALFORMED_MAP_IR, "canon_carry");
    c: dict[str, any] = _load_ir(out).get("walker").get("carries");
    assert "drafted_note" in c;
    assert c["drafted_note"]["produced_by"] == "draft";
}

test "canonicalizing changes the IR's form and NOT what it lowers to" {
    # The rung refuses unless this holds — the relaxer already understood the
    # text, so re-emitting it canonically may not move a line of generated Jac.
    for src in [MALFORMED_MAP_IR, MALFORMED_SEQ_IR] {
        out = canonicalize_ir(src, "canon_id");
        assert out;
        assert str(transpile_ir(src, "canon_id")) == str(transpile_ir(out, "canon_id"));
    }
}

test "a document the relaxer cannot rescue is left alone" {
    broken = "---\nname: x\n---\nnodes: [\n  - id: a\n";
    assert canonicalize_ir(broken, "canon_broken") == "";
}

test "an IR with no nodes is not canonicalized" {
    assert canonicalize_ir("---\nname: x\n---\nshape: pipeline\n", "canon_empty") == "";
}

test "paths mined from the task prose are lifted to role:input carries" {
    # live fault (offer-letter-generator): the artifact had NO parameter surface —
    # `_EJ_PARAM_KEYS = []` — because the SENSE tool recovered its template, data
    # and output paths by regex over the task sentence. The caller could not name
    # a file, so the agent's phrasing decided which one was opened, and a sentence
    # that named only the OUTPUT made the artifact open its output as its template.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "template_spec": {"type": "dict", "produced_by": "load_inputs"}}},
        "tools": {"load_template_data": {
            "sig": "(task) -> dict",
            "surface": "SENSE",
            "body": ("def load_template_data(task: str) -> dict:\n"
                     "    import re, os, json\n"
                     "    text = task or \"\"\n"
                     "    docxs = re.findall(r'[^\\s]+\\.docx\\b', text)\n"
                     "    jsons = re.findall(r'[^\\s]+\\.json\\b', text)\n"
                     "    template_path = docxs[0] if docxs else \"template.docx\"\n"
                     "    data_path = jsons[0] if jsons else \"data.json\"\n"
                     "    return {\"template_path\": template_path, \"data_path\": data_path}\n")}},
        "nodes": [{"id": "load_inputs", "type": "SENSE", "owner": "code",
                   "tool": "load_template_data", "reads": ["task"], "writes": ["template_spec"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "task prose" in str(f) and "template_path" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    car = out["walker"]["carries"];
    # the caller can now NAME the files: role:input carries become --flags,
    # MCP schema properties and _EJ_PARAM_KEYS entries in the lowering
    for n in ["template_path", "data_path"] {
        assert car[n]["role"] == "input";
        # `path`, not `str`: a str input the entry node reads inherits the whole
        # task sentence as its default, which is the prose-grounding being replaced
        assert car[n]["type"] == "path";
        assert n in list(out["nodes"][0]["reads"]);
    }
    t = out["tools"]["load_template_data"];
    assert "template_path" in str(t["sig"]) and "data_path" in str(t["sig"]);
    # …and the scrape survives as the fallback, so an unnamed call is unchanged
    assert "_sigil_in_template_path = template_path" in str(t["body"]);
    assert "template_path = _sigil_in_template_path or template_path" in str(t["body"]);
    assert "docxs[0] if docxs" in str(t["body"]);
}

test "a path the walker already carries is left alone" {
    # negative control: the lift mints nothing when the lane already exists —
    # whether it is a declared input or produced upstream.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "template_path": {"type": "path", "role": "input"}}},
        "tools": {"resolve": {
            "sig": "(task, template_path) -> dict",
            "body": ("def resolve(task: str, template_path: str = \"\") -> dict:\n"
                     "    import re\n"
                     "    hits = re.findall(r'[^\\s]+\\.docx\\b', task or \"\")\n"
                     "    template_path = template_path or (hits[0] if hits else \"t.docx\")\n"
                     "    return {\"template_path\": template_path}\n")}},
        "nodes": [{"id": "n", "type": "SENSE", "owner": "code", "tool": "resolve",
                   "reads": ["task", "template_path"], "writes": []}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "task prose" in str(f)]) == 0;
}

test "a tool that names a location the walker carries nowhere gets an input carry" {
    # the second half of the input surface (power-flow-data): the tool signature
    # already says `load_network(path)`, but no carry fed it, so the lowering bound
    # the filename mined from the task sentence and the caller could not name the
    # file. The lift declares the location; the prose extraction stays the fallback.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "network": {"type": "dict", "produced_by": "load"}}},
        "tools": {"load_network": {"sig": "(path) -> dict", "surface": "SENSE",
                                   "serves": ["load"],
                                   "body": "def load_network(path: str) -> dict:\n    import json\n    return json.load(open(path))\n"}},
        "nodes": [{"id": "load", "type": "SENSE", "owner": "code", "tool": "load_network",
                   "reads": ["task"], "writes": ["network"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    # NAMED for what it holds: the node produces `network`, so the flag is
    # `--network_path`, not a generic `--input_path`. A model handed `input_path`
    # guessed math-model.md over network.json 32 times (energy-ac, 0/24).
    assert len([f for f in r["fixes"] if "carried nowhere" in str(f) and "network_path" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    assert out["walker"]["carries"]["network_path"]["role"] == "input";
    assert out["walker"]["carries"]["network_path"]["type"] == "path";
    assert "network_path" in list(out["nodes"][0]["reads"]);
}

test "a write tool's destination is declared as output_path, not mined from prose" {
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "report_md": {"type": "str", "produced_by": "assemble"}}},
        "tools": {"write_file": {"sig": "(path, content) -> str", "surface": "ACT·artifact",
                                 "serves": ["write_report"],
                                 "body": "def write_file(path: str, content: str) -> str:\n    open(path, 'w').write(content)\n    return path\n"}},
        "nodes": [{"id": "write_report", "type": "ACT", "owner": "code", "tool": "write_file",
                   "reads": ["report_md"], "writes": ["report_file"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    out = _load_ir(str(r["ir_text"]));
    assert out["walker"]["carries"]["output_path"]["role"] == "input";
    assert "output_path" in list(out["nodes"][0]["reads"]);
}

test "a tool already fed by a pathish carry is left alone" {
    # negative control: the binder's role rung already has a lane to bind, so
    # nothing is minted and the existing dataflow is untouched.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "deck_path": {"type": "path", "produced_by": "resolve"}}},
        "tools": {"inspect": {"sig": "(path) -> str", "surface": "SENSE", "serves": ["look"],
                              "body": "def inspect(path: str) -> str:\n    return path\n"}},
        "nodes": [{"id": "look", "type": "SENSE", "owner": "code", "tool": "inspect",
                   "reads": ["deck_path"], "writes": []}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "carried nowhere" in str(f)]) == 0;
}

test "a resolver that mines a location out of the task gains a caller override" {
    # the third shape (pdf, 11 tasks): `resolve_pdf_path(task) -> str` returns the
    # first .pdf the prose names, and the literal "input.pdf" when it names none.
    # The location is an input; the caller must be able to give it.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "pdf_path": {"type": "str", "produced_by": "resolve_pdf"}}},
        "tools": {"resolve_pdf_path": {
            "sig": "(task) -> str", "surface": "SENSE",
            "body": ("def resolve_pdf_path(task: str) -> str:\n"
                     "    import re\n"
                     "    m = re.search(r'([^\\s]+\\.pdf)\\b', task or \"\")\n"
                     "    return m.group(1) if m else \"input.pdf\"\n")}},
        "nodes": [{"id": "resolve_pdf", "type": "CODE", "owner": "code",
                   "tool": "resolve_pdf_path", "reads": ["task"], "writes": ["pdf_path"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "resolves 'pdf_path'" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    # the produced carry is already `pdf_path`, so the caller's flag is `pdf_file`
    assert out["walker"]["carries"]["pdf_file"]["role"] == "input";
    assert "pdf_file" in list(out["nodes"][0]["reads"]);
    b = str(out["tools"]["resolve_pdf_path"]["body"]);
    assert "if pdf_file: return pdf_file" in b;       # caller wins
    assert "input.pdf" in b;                          # the search survives untouched
}

test "a resolver that reads more than the task is left alone" {
    # negative control: the guard is narrow on purpose — a node that consumes real
    # dataflow is not a prose resolver, and rewriting it would change its meaning.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "cfg": {"type": "dict", "produced_by": "load_cfg"},
                                            "pdf_path": {"type": "str", "produced_by": "pick"}}},
        "tools": {"pick_path": {"sig": "(task, cfg) -> str", "surface": "SENSE",
                                "body": "def pick_path(task: str, cfg: dict) -> str:\n    return cfg.get('p', '')\n"}},
        "nodes": [{"id": "pick", "type": "CODE", "owner": "code", "tool": "pick_path",
                   "reads": ["task", "cfg"], "writes": ["pdf_path"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "resolves" in str(f)]) == 0;
}

test "a derived deliverable path becomes a caller-nameable output" {
    # live fault (pdf / court-form-filling, 0/5): the artifact named its own
    # deliverable — `out_pdf = splitext(pdf_path)[0] + "_filled.pdf"` — so the
    # caller asked for /root/sc100-filled.pdf, the file landed at
    # /root/sc100-blank_filled.pdf, and the verifier found nothing while the tool
    # reported success. A destination is an input.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "pdf_path": {"type": "path", "role": "input"},
                                            "filled_pdf": {"type": "str", "produced_by": "fill"}}},
        "tools": {"fill_fillable_fields": {
            "sig": "(pdf_path, values_file) -> str", "surface": "ACT",
            "body": ("def fill_fillable_fields(pdf_path: str, values_file: str) -> str:\n"
                     "    import os, subprocess, sys\n"
                     "    out_pdf = os.path.splitext(pdf_path)[0] + \"_filled.pdf\"\n"
                     "    subprocess.run([sys.executable, \"s.py\", pdf_path, values_file, out_pdf])\n"
                     "    return out_pdf\n")}},
        "nodes": [{"id": "fill", "type": "ACT", "owner": "code", "tool": "fill_fillable_fields",
                   "reads": ["pdf_path", "values_file"], "writes": ["filled_pdf"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "derived its deliverable" in str(f)]) == 1;
    out = _load_ir(str(r["ir_text"]));
    assert out["walker"]["carries"]["output_path"]["role"] == "input";
    assert "output_path" in list(out["nodes"][0]["reads"]);
    b = str(out["tools"]["fill_fillable_fields"]["body"]);
    assert "out_pdf = output_path or out_pdf" in b;   # caller wins
    assert "_filled.pdf" in b;                        # the derivation survives
}

test "a tool that already takes its destination is left alone" {
    # negative control: `path` is already a parameter, so there is nothing to lift
    # and no second destination should appear.
    ir = _yaml({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"},
                                            "doc_md": {"type": "str", "produced_by": "draft"}}},
        "tools": {"write_out": {"sig": "(path, content) -> str", "surface": "ACT",
                                "body": "def write_out(path: str, content: str) -> str:\n    open(path, 'w').write(content)\n    return path\n"}},
        "nodes": [{"id": "save", "type": "ACT", "owner": "code", "tool": "write_out",
                   "reads": ["doc_md"], "writes": ["out_file"]}],
        "edges": []
    });
    r = autofix_ir(ir, "");
    assert len([f for f in r["fixes"] if "derived its deliverable" in str(f)]) == 0;
}

test "minted inputs are documented by CONTENT, not by provenance" {
    # These docs are lowered to _EJ_PARAM_DOCS and become the MCP inputSchema
    # property descriptions — the only thing a calling agent reads before it
    # binds a value. Every property used to read "Exact value for input 'x'",
    # so the agent matched on the parameter NAME alone.
    ir = {"nodes": [{"id": "load", "type": "SENSE", "reads": ["task"],
                     "writes": ["network"], "tool": "read_network"}],
          "walker": {"carries": {"task": {"type": "str"}}},
          "types": {},
          "tools": {"read_network": {"sig": "(task) -> dict",
              "doc": "Read the network topology and bus/branch tables.",
              "body": "import re, json\ndef read_network(task):\n"
                      + "    m = re.search(r'([\\w.-]+\\.json)', task)\n"
                      + "    network_path = m.group(1) if m else \"network.json\"\n"
                      + "    return json.load(open(network_path))"}}};
    fixes = _fix_task_scraped_inputs(ir);
    assert fixes, "the mined path was not lifted to an input at all";
    doc = str(ir["walker"]["carries"]["network_path"]["doc"]);
    assert ".json" in doc, "the doc does not say which file type to hand over: " + doc;
    assert "read_network" in doc, "the doc does not name the consumer: " + doc;
    assert "Read the network topology" in doc, "the tool's own doc was dropped: " + doc;
    assert "not a document that describes" in doc, doc;
    # the provenance marker survives: it is how a minted lane is told from an
    # authored one when an IR is reset to its authored shape for a re-lower
    assert "caller-supplied" in doc, doc;
}

test "two same-shaped inputs get DISTINGUISHABLE descriptions" {
    # power-flow-data advertised `network_path` and `size_path` with byte-identical
    # text ("Exact value for input 'x'"), so nothing in the schema said which file
    # to hand to which: the agent gave the solver the maths write-up and the size
    # probe the output path, 32 calls, 0/24.
    ir = {"nodes": [
              {"id": "file_size", "type": "SENSE", "reads": ["task"], "writes": ["size"],
               "tool": "check_file_size"},
              {"id": "load", "type": "SENSE", "reads": ["task"], "writes": ["network"],
               "tool": "load_network"}],
          "walker": {"carries": {"task": {"type": "str"}, "size": {"type": "str"},
                                 "network": {"type": "dict"}}},
          "types": {},
          "tools": {
              "check_file_size": {"sig": "(path) -> str",
                  "doc": "If needed, check the file size: line count and human-readable size.",
                  "body": "def check_file_size(path: str) -> str:\n    import os\n"
                          + "    return str(os.path.getsize(path))"},
              "load_network": {"sig": "(path) -> dict",
                  "doc": "Load network data from JSON in one call. Returns baseMVA, bus, gen, branch.",
                  "body": "def load_network(path: str) -> dict:\n    import json\n"
                          + "    with open(path) as f:\n        return json.load(f)"}}};
    _fix_pathish_params(ir);
    carries = ir["walker"]["carries"];
    mint = [str(k) for k in carries.keys() if "caller-supplied" in str((carries[k] or {}).get("doc", ""))];
    assert len(mint) == 2, "expected one input per unlaned location, got: " + str(mint);
    docs = [str(carries[k]["doc"]) for k in mint];
    assert docs[0] != docs[1], "the two inputs are still indistinguishable:\n  " + docs[0];
    joined = "\n".join(docs);
    assert ".json file" in joined, "the JSON reader's type was never recovered:\n" + joined;
    assert "Load network data from JSON" in joined, joined;
    assert "check the file size" in joined, joined;
}

test "an override never lands inside a multi-line statement" {
    # The lift matched the assignment LINE and appended the override right after
    # it, so a call spanning two lines took the override into its argument list.
    # `jac check` still passed and the module still lowered; the artifact raised
    # SyntaxError only when the walker reached that tool — every run (caught
    # live: pdf's create_validation_images, 0/5, the agent retrying 12 times
    # against a perfectly-bound pdf_file and output_path).
    body = "def make_img(img: str) -> str:\n"
           + "    import os\n"
           + "    out_img = os.path.join(os.path.dirname(img) or \".\",\n"
           + "                           \"page_%d.png\" % 1)\n"
           + "    return out_img";
    got = _lift_output_body(body, "out_img", "output_path");
    assert got, "the multi-line assignment was not lifted at all";
    import ast;
    ast.parse(got);      # the whole point: it must still be Python
    lines = got.split("\n");
    # the override sits AFTER the closing paren, not between the two halves
    close = [i for i in range(len(lines)) if "page_%d.png" in lines[i]][0];
    over = [i for i in range(len(lines)) if "output_path or out_img" in lines[i]][0];
    assert over > close, "override landed inside the call:\n" + got;
}

test "a destination bound inside a loop is not a deliverable path" {
    # create_validation_images writes ONE image per page. Binding the caller's
    # output_path there would send every page to the same file, and it is not
    # the deliverable in any case.
    body = "def make_all(imgs: str) -> str:\n"
           + "    import os\n"
           + "    made = []\n"
           + "    for i, img in enumerate(imgs.split(\"\\n\")):\n"
           + "        out_img = os.path.join(\".\", \"page.png\")\n"
           + "        made.append(out_img)\n"
           + "    return \"\\n\".join(made)";
    assert _lift_output_body(body, "out_img", "output_path") == "",
        "a per-iteration write was treated as the deliverable";

    # the same assignment at function level IS liftable
    flat = "def make_one(img: str) -> str:\n"
           + "    import os\n"
           + "    out_img = os.path.join(\".\", \"page.png\")\n"
           + "    return out_img";
    assert _lift_output_body(flat, "out_img", "output_path");
}

test "an injection that would not parse is refused outright" {
    # The gates read the IR, not the tool bodies, so a pass that breaks a body
    # ships silently. Every injector re-parses its own output.
    ok = "def f(p: str) -> str:\n    q = p\n    return q";
    assert _injected_ok(ok, "def f(p: str) -> str:\n    q = p\n    q = x or q\n    return q");
    assert _injected_ok(ok, "def f(p: str) -> str:\n    q = (p,\n    q = x or q\n    )") == "";
    # a body that ALREADY did not parse is not this pass's fault to police
    assert _injected_ok("def f(:\n  bad", "still bad (") == "still bad (";
}

test "an omitted optional input routes instead of raising" {
    # check_file_size exists to probe a file "if needed". With the input omitted
    # it received "" and opened it: FileNotFoundError: '' ten times in one cell.
    # A detector for this shape already existed; nothing acted on it.
    ir = {"nodes": [{"id": "probe", "type": "SENSE", "reads": ["size_path"],
                     "writes": ["size"], "tool": "check_file_size"}],
          "walker": {"carries": {"task": {"type": "str"},
                                 "size_path": {"type": "path", "role": "input"},
                                 "size": {"type": "str", "produced_by": "probe"}}},
          "types": {},
          "tools": {"check_file_size": {"sig": "(size_path) -> str",
              "body": "def check_file_size(size_path: str) -> str:\n"
                      + "    lines = 0\n"
                      + "    with open(size_path, \"rb\") as f:\n"
                      + "        for _ in f:\n            lines += 1\n"
                      + "    return str(lines)"}}};
    fixes = _fix_unguarded_reads(ir);
    assert fixes, "the unguarded read was not guarded";
    got = str(ir["tools"]["check_file_size"]["body"]);
    assert "if not size_path:" in got, got;
    assert "return \"\"" in got, "the neutral value must match the declared return type: " + got;
    import ast;
    ast.parse(got);
    # the guard precedes the read
    assert got.index("if not size_path") < got.index("open("), got;
    # …and it guards ONLY the omitted case: a path that is present but wrong must
    # still raise, or the caller never learns it passed the wrong path
    assert "exists" not in got, "an existence check silences a correctable error: " + got;

    # a tool that already routes is left alone
    safe = {"tools": {"ok": {"sig": "(p) -> str",
        "body": "def ok(p: str) -> str:\n    import os\n    if not os.path.exists(p):\n        return ''\n    return open(p).read()"}},
        "nodes": [], "walker": {"carries": {}}, "types": {}};
    assert _fix_unguarded_reads(safe) == [];
}

test "a destination parameter is lifted even when the node reads a source" {
    # fill_template(template_file, fill_data, path): `template_file` is a pathish
    # READ carry, which used to mark the whole node served and leave `path` with
    # no lane. The deliverable then went wherever _outname guessed, and the
    # caller had no way to name it.
    ir = {"nodes": [{"id": "fill", "type": "ACT", "reads": ["template_file", "fill_data"],
                     "writes": ["out_file"], "tool": "fill_template"}],
          "walker": {"carries": {"task": {"type": "str"},
                                 "template_file": {"type": "path", "role": "input"},
                                 "fill_data": {"type": "dict"},
                                 "out_file": {"type": "str", "produced_by": "fill"}}},
          "types": {},
          "tools": {"fill_template": {"sig": "(template_file, fill_data, path) -> str",
              "doc": "Fill the template and save the document.",
              "body": "def fill_template(template_file: str, fill_data: dict, path: str) -> str:\n"
                      + "    from docx import Document\n    doc = Document(template_file)\n"
                      + "    doc.save(path)\n    return path"}}};
    fixes = _fix_pathish_params(ir);
    assert fixes, "the destination was not lifted";
    carries = ir["walker"]["carries"];
    assert "output_path" in carries, "no destination lane was minted: " + str(list(carries));
    assert "output_path" in [str(r) for r in ir["nodes"][0]["reads"]];
    doc = str(carries["output_path"]["doc"]);
    assert "WRITE" in doc, doc;

    # the SOURCE side keeps its short-circuit: a node that already reads a
    # pathish carry does not mint a second input for its read parameter
    ir2 = {"nodes": [{"id": "scan", "type": "SENSE", "reads": ["template_file"],
                      "writes": ["keys"], "tool": "scan_placeholders"}],
           "walker": {"carries": {"template_file": {"type": "path", "role": "input"},
                                  "keys": {"type": "list", "produced_by": "scan"}}},
           "types": {},
           "tools": {"scan_placeholders": {"sig": "(path) -> list",
               "body": "def scan_placeholders(path: str) -> list:\n    return []"}}};
    _fix_pathish_params(ir2);
    minted = [k for k in ir2["walker"]["carries"].keys() if str(k) not in ["template_file", "keys"]];
    assert minted == [], "a served read parameter minted a duplicate input: " + str(minted);
}

test "an intermediate writer never takes the caller's deliverable path" {
    # save_field_values writes field_values.json, which fill_fields then READS.
    # Binding output_path to both made the artifact write the JSON to
    # sc100-filled.pdf and hand that file to the fill script as its values file:
    # the deliverable was a 2KB copy of the tool's own JSON.
    ir = {"nodes": [
              {"id": "save_vals", "type": "ACT", "reads": ["vals_json"],
               "writes": ["values_file"], "tool": "write_field_values"},
              {"id": "fill", "type": "ACT", "reads": ["pdf_path", "values_file"],
               "writes": ["filled_pdf"], "tool": "fill_fillable_fields"}],
          "walker": {"carries": {"task": {"type": "str"},
                                 "vals_json": {"type": "str"},
                                 "pdf_path": {"type": "path"},
                                 "values_file": {"type": "str", "produced_by": "save_vals"},
                                 "filled_pdf": {"type": "str", "produced_by": "fill"}}},
          "types": {},
          "tools": {
              "write_field_values": {"sig": "(vals_json) -> str",
                  "body": "def write_field_values(vals_json: str) -> str:\n"
                          + "    out = \"field_values.json\"\n"
                          + "    open(out, \"w\").write(vals_json)\n    return out"},
              "fill_fillable_fields": {"sig": "(pdf_path, values_file) -> str",
                  "body": "def fill_fillable_fields(pdf_path: str, values_file: str) -> str:\n"
                          + "    import os\n"
                          + "    out_pdf = os.path.splitext(pdf_path)[0] + \"_filled.pdf\"\n"
                          + "    open(out_pdf, \"w\").write(values_file)\n    return out_pdf"}}};
    assert _consumed_downstream(ir, "write_field_values"), "the intermediate was not recognised";
    assert not _consumed_downstream(ir, "fill_fillable_fields"), "the deliverable writer was misread";

    _fix_derived_outputs(ir);
    # exactly ONE tool gains the destination, and it is the deliverable writer
    _dsig = str(ir["tools"]["fill_fillable_fields"]["sig"]);
    _isig = str(ir["tools"]["write_field_values"]["sig"]);
    assert "output_path" in _dsig, _dsig;
    assert "output_path" not in _isig, "the intermediate took the caller's path: " + _isig;
}
