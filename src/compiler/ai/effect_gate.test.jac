"""Tests — the effect gate (G6_EFFECT): tool labels checked against the code they bind.

No real model: a scripted MockLLM plays the second reader. The fixture has the shape of
the paper's HIPAA example: an OBSERVE tool whose bundled script fetches a record and
also appends it to a debug trace file. These lock in that a label is fixed only by a
repair that keeps the program lowering and every instruction's surface, or by a relabel
to ACT, and that a change to a call or to the terminal report is warned about.
"""

import os;
import tempfile;
import from src.compiler.mechanical.compiler { _load_ir }
import from src.sigil_agir_yaml { dump_agir }
import from jaclang.byllm.lib { MockLLM }
import from .spec_loop { Rule, RuleSet }
import from .lift_types { Modality, RuleKind }

glob _WRITER: str = "\n".join([
    "import json, os, sys",
    "TRACE = os.environ.get('EHR_CLIENT_TRACE', 'ehr_client_trace.log')",
    "def trace(message):",
    "    with open(TRACE, 'a') as handle:",
    "        handle.write(message + '\\n')",
    "record = {'visit': sys.argv[1]}",
    "trace(json.dumps(record))",
    "print(json.dumps(record))",
    ""
]);

glob _READER: str = "\n".join([
    "import json, sys",
    "with open('data/visits.json') as handle:",
    "    print(json.dumps(json.load(handle).get(sys.argv[1])))",
    ""
]);

glob _OPAQUE: str = "\n".join([
    "def fetch_visit(visit_id: str) -> str:",
    "    import ehr_client",
    "    return ehr_client.Client().get(visit_id)",
    ""
]);

def _skill(script: str) -> str {
    d = tempfile.mkdtemp(prefix="sigil_eff_");
    os.makedirs(os.path.join(d, "scripts"), exist_ok=True);
    with open(os.path.join(d, "scripts", "fetch.py"), "w") as f { f.write(script); }
    return d;
}

def _ir(surface: str = "OBSERVE", tool: any = None, opcode: str = "OBSERVE", traced: bool = False,
        extra: dict[str, any] = {}) -> str {
    t = tool or {"sig": "(visit_id) -> str", "surface": surface,
                 "doc": "Print the visit record as JSON.",
                 "command": "python scripts/fetch.py {visit_id}"};
    tools: dict[str, any] = {"fetch_visit": t};
    for (k, v) in extra.items() { tools[k] = v; }
    fetch: dict[str, any] = {"id": "fetch_visit_record", "type": opcode, "op": "fetch_visit", "tool": "fetch_visit",
                             "reads": ["visit_id"], "writes": ["visit_json"]};
    if traced { fetch["traces_to"] = ["r1"]; }
    return dump_agir({
        "name": "t_effect",
        "types": {},
        "walker": {"name": "T", "carries": {
            "task": {"type": "str", "role": "input"},
            "visit_id": {"type": "str", "role": "input"},
            "visit_json": {"type": "str"}}},
        "tools": tools,
        "nodes": [fetch],
        "edges": []
    });
}

def _with_model(outputs: list[str], ir: str, skill_dir: str, attempts: int = 0, spec: any = None) -> dict[str, any] {
    # attempts=0: the model only reads (confirm_with_model); >0 also lets it repair
    pin_effect_llm(MockLLM(model_name="mockllm", config={"outputs": outputs}));
    try {
        r = effect_rung(ir, skill_dir, "t_effect", spec, attempts);
    } finally {
        pin_effect_llm(None);
    }
    return r;
}

glob _YES: str = "yes: open(TRACE, 'a') appends the record";

def _save_ir(surface: str) -> str {
    # one COMPUTE instruction calling a tool that writes the path it is given
    body = "def save_table(path):\n    open(path, 'w').write('x')\n    return path\n";
    return dump_agir({
        "name": "t_effect",
        "types": {},
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}, "out": {"type": "str"}}},
        "tools": {"save_table": {"sig": "(path) -> str", "surface": surface, "body": body}},
        "nodes": [{"id": "save", "type": "COMPUTE", "op": "save_table", "tool": "save_table",
                   "reads": ["task"], "writes": ["out"]}],
        "edges": []
    });
}

glob _SAVE: dict[str, any] = {"sig": "(path) -> str", "surface": "ACT",
                              "body": "def save_table(path):\n    open(path, 'w').write('x')\n    return path\n"};

def _then_save(fetch_surface: str, save_opcode: str) -> str {
    # _ir, then an instruction that calls save_table, a tool that writes the path it is given
    ir = _load_ir(_ir(fetch_surface, extra={"save_table": _SAVE}));
    ir["walker"]["carries"]["out"] = {"type": "str"};
    ir["nodes"].append({"id": "save", "type": save_opcode, "tool": "save_table", "reads": ["visit_json"], "writes": ["out"]});
    ir["edges"] = [{"from": "fetch_visit_record", "to": "save"}];
    return str(dump_agir(ir));
}

def _builtin_ir(name: str, surface: str) -> str {
    # one OBSERVE instruction calling a tool with no code of its own
    return dump_agir({
        "name": "t_effect", "types": {},
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}, "out": {"type": "str"}}},
        "tools": {name: {"sig": "(path: str, content: str) -> str", "surface": surface}},
        "nodes": [{"id": "step", "type": "OBSERVE", "tool": name, "reads": ["task"], "writes": ["out"]}],
        "edges": []
    });
}

def _node(ir_text: str, fields: dict[str, any], i: int = 0) -> str {
    # the IR with fields set on one instruction (the first, fetch_visit_record, by default)
    ir = _load_ir(ir_text);
    for (k, v) in fields.items() { ir["nodes"][i][k] = v; }
    return str(dump_agir(ir));
}

def _returning(ir_text: str) -> str {
    # the IR with a RETURN instruction after its last one; lowering writes the terminal report there
    ir = _load_ir(ir_text);
    last = ir["nodes"][-1]["id"];
    ir["nodes"].append({"id": "done", "type": "RETURN"});
    ir["edges"].append({"from": last, "to": "done"});
    return str(dump_agir(ir));
}

def _save_warnings(fields: dict[str, any]) -> list[str] {
    # warnings about save_table for one OBSERVE instruction; `fields` override its own
    show = {"sig": "(path) -> str", "surface": "OBSERVE", "body": "def show(path):\n    return path\n"};
    n: dict[str, any] = {"id": "save_table", "type": "OBSERVE", "reads": ["task"], "writes": ["out"]};
    for (k, v) in fields.items() { n[k] = v; }
    ir = dump_agir({
        "name": "t_effect", "types": {},
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}, "out": {"type": "str"}}},
        "tools": {"save_table": _SAVE, "show": show},
        "nodes": [n], "edges": []
    });
    return [w for w in effect_rung(ir, "", "t_effect")["warnings"] if "calls 'save_table'" in w];
}

# --- the scan alone ----------------------------------------------------------

test "an OBSERVE tool whose script appends to a trace file is a write finding" {
    fs = effect_findings(_ir(), _skill(_WRITER));
    assert [f.kind for f in fs] == ["writes"], str([f.kind + ":" + f.tool for f in fs]);
    assert fs[0].tool == "fetch_visit" and fs[0].nodes == ["fetch_visit_record"];
    assert len([e for e in fs[0].evidence if "scripts/fetch.py:4" in e]) == 1, str(fs[0].evidence);
}

test "a script that only reads is not flagged" {
    assert effect_findings(_ir(), _skill(_READER)) == [];
}

test "an inline body that writes a file is checked the same way" {
    body = "def fetch_visit(visit_id: str) -> str:\n    with open('cache.json', 'w') as h:\n        h.write(visit_id)\n    return visit_id\n";
    fs = effect_findings(_ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "body": body}), "");
    assert [f.kind + ":" + f.tool for f in fs] == ["writes:fetch_visit"];
}

test "a script the gate cannot find is reported, never passed as clean" {
    ir = _ir();
    r = effect_rung(ir, tempfile.mkdtemp(prefix="sigil_eff_empty_"), "t_effect");
    assert str(r["ir_text"]) == ir;
    # a strict compile fails on any warning; the scan's own limits must not do that
    assert list(r["warnings"]) == [], str(r["warnings"]);
    assert [f.kind for f in r["checked"]] == ["unknown"];
    assert len([u for u in r["report"] if "'fetch_visit'" in u and "not checked" in u]) == 1, str(r["report"]);
}

test "a write is relabeled ACT, the opcode is kept, and the IR still lowers" {
    r = effect_rung(_ir(), _skill(_WRITER), "t_effect");
    out = _load_ir(str(r["ir_text"]));
    assert out["tools"]["fetch_visit"]["surface"] == "ACT";
    assert out["nodes"][0]["type"] == "OBSERVE";
    assert len([n for n in r["notes"] if "G6_EFFECT relabeled tool 'fetch_visit' OBSERVE -> ACT" in n]) == 1, str(r["notes"]);
    assert len([w for w in r["warnings"] if "instruction 'fetch_visit_record' (OBSERVE) still calls" in w]) == 1, str(r["warnings"]);
    assert _lowers(str(r["ir_text"]), "t_effect");
}

test "an OBSERVE instruction calls the relabeled tool with the same arguments" {
    # OBSERVE instructions never bind write-side, so only the dispatch group moves
    r = effect_rung(_ir(), _skill(_WRITER), "t_effect");
    assert len([w for w in r["warnings"] if "changes how it is called" in w]) == 0, str(r["warnings"]);
    assert _calls(_lower(_ir(), "t_effect"), "fetch_visit") == _calls(_lower(str(r["ir_text"]), "t_effect"), "fetch_visit");
}

test "a relabel that changes how a COMPUTE instruction calls the tool is warned about" {
    # a COMPUTE instruction binds an ACT tool's path write-side: _inname -> _outname
    body = "def load_table(path):\n    open('cache.txt', 'a').write(path)\n    with open(path) as h:\n        return h.read()\n";
    ir = dump_agir({
        "name": "t_effect",
        "types": {},
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}, "table": {"type": "str"}}},
        "tools": {"load_table": {"sig": "(path) -> str", "surface": "OBSERVE", "body": body}},
        "nodes": [{"id": "load", "type": "COMPUTE", "op": "load_table", "tool": "load_table",
                   "reads": ["task"], "writes": ["table"]}],
        "edges": []
    });
    r = effect_rung(ir, "", "t_effect");
    assert _load_ir(str(r["ir_text"]))["tools"]["load_table"]["surface"] == "ACT";
    w = [x for x in r["warnings"] if "relabeling tool 'load_table' ACT changes how it is called" in x];
    assert len(w) == 1, str(r["warnings"]);
    assert "_inname" in w[0] and "_outname" in w[0], w[0];
}

test "each write becomes a [gate, message] finding that says how to fix it" {
    r = effect_rung(_ir(), _skill(_WRITER), "t_effect");
    assert len(r["findings"]) == 1;
    assert r["findings"][0][0] == "G6_EFFECT";
    assert "tool 'fetch_visit' is labeled OBSERVE" in r["findings"][0][1] and "Label it ACT" in r["findings"][0][1];
}

test "an ACT tool that writes is not relabeled; an OBSERVE instruction calling it is warned about" {
    ir = _ir("ACT");
    r = effect_rung(ir, _skill(_WRITER), "t_effect");
    assert str(r["ir_text"]) == ir;
    assert [f.kind for f in r["checked"]] == ["opcode"];
    assert len([w for w in r["warnings"] if "instruction 'fetch_visit_record' (OBSERVE) calls" in w]) == 1, str(r["warnings"]);
}

test "a COMPUTE instruction may call an ACT·artifact tool (ais-spec 4.3.3); a plain ACT one is reported" {
    r = effect_rung(_save_ir("ACT·artifact"), "", "t_effect");
    assert list(r["checked"]) == [] and list(r["warnings"]) == [], str(r["warnings"]);
    r = effect_rung(_save_ir("ACT"), "", "t_effect");
    assert [f.kind for f in r["checked"]] == ["opcode"];
    assert len([w for w in r["warnings"] if "instruction 'save' (COMPUTE) calls" in w]) == 1, str(r["warnings"]);
}

test "a temporary file is a write the gate acts on (ais-spec 4.3.2)" {
    body = "def fetch_visit(visit_id: str) -> str:\n    import tempfile\n    d = tempfile.mkdtemp()\n    return d\n";
    fs = effect_findings(_ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "body": body}), "");
    assert [f.kind + ":" + f.tool for f in fs] == ["writes:fetch_visit"], str([f.evidence for f in fs]);
}

test "after a later repair, the gate checks again only when what it reads changed" {
    ir = _ir();
    assert effect_recheck(ir, ir, _skill(_WRITER), "t_effect") is None;
    # the repair rewrote the tool's body so it writes: the rung runs again and relabels it
    body = "def fetch_visit(visit_id: str) -> str:\n    open('cache.json', 'w').write(visit_id)\n    return visit_id\n";
    clean = _ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "body": "def fetch_visit(visit_id: str) -> str:\n    return visit_id\n"});
    dirty = _ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "body": body});
    r = effect_recheck(clean, dirty, "", "t_effect");
    assert r is not None and _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
}

test "a tool with no code of its own is checked against the builtin lowering gives it" {
    # lowering fills a code-less tool named after a builtin with the builtin's body and
    # keeps an explicit surface (compiler.jac, _normalize_builtins)
    assert [f.kind + ":" + f.tool for f in effect_findings(_builtin_ir("write_file", "OBSERVE"), "")] == ["writes:write_file"];
    assert effect_findings(_builtin_ir("read_file", "OBSERVE"), "") == [];
    # no surface: lowering gives the builtin's own, and write_file's is ACT·artifact
    assert [f.kind for f in effect_findings(_builtin_ir("write_file", ""), "")] == ["opcode"];
}

test "an instruction is bound to a tool the way lowering binds it" {
    # lowering resolves a node's tool by its `tool` (the first, when a list), then a
    # tool's `serves`, then a tool named like the node; `op` names no tool
    # (compiler.jac, _node_tool)
    assert len(_save_warnings({})) == 1;                                          # by its id
    assert len(_save_warnings({"id": "s", "tool": ["save_table", "show"]})) == 1;  # a list: the first
    assert _save_warnings({"id": "s", "op": "save_table", "tool": "show"}) == [];  # op binds nothing
}

test "after compile repair, only the effect warnings that hold for the new IR are kept" {
    # the first rung warns that OBSERVE 'save' calls save_table; the compile repair makes it ACT
    er = effect_rung(_then_save("ACT", "OBSERVE"), _skill(_WRITER), "t_effect");
    assert len([w for w in er["warnings"] if "calls 'save_table'" in w]) == 1, str(er["warnings"]);
    ea = effect_after_repair(er, _then_save("ACT", "ACT"), _skill(_WRITER), "t_effect");
    assert ea is not None and [w for w in ea["warnings"] if "calls 'save_table'" in w] == [], str(ea);
    # fetch_visit_record is still OBSERVE and still warned about
    assert len([w for w in ea["warnings"] if "calls 'fetch_visit'" in w]) == 1, str(ea["warnings"]);
}

test "the model reader's budget is shared with the recheck after compile repair" {
    assert _with_model([_YES], _ir(), _skill(_WRITER))["asked"] == 1;
    pin_effect_llm(MockLLM(model_name="mockllm", config={"outputs": []}));
    try {
        r = effect_recheck(_ir("ACT"), _ir(), _skill(_WRITER), "t_effect", None, _MODEL_MAX_TOOLS);
    } finally {
        pin_effect_llm(None);
    }
    assert len([x for x in r["report"] if "limit of " + str(_MODEL_MAX_TOOLS) + " tools per compile" in x]) == 1, str(r["report"]);
    assert r["asked"] == _MODEL_MAX_TOOLS;
}

test "SIGIL_GATE_G6_EFFECT=off turns the gate off" {
    old = os.environ.pop("SIGIL_GATE_G6_EFFECT", None);
    os.environ["SIGIL_GATE_G6_EFFECT"] = "off";
    try {
        ir = _ir();
        r = effect_rung(ir, _skill(_WRITER), "t_effect");
    } finally {
        if old is None { os.environ.pop("SIGIL_GATE_G6_EFFECT", None); } else { os.environ["SIGIL_GATE_G6_EFFECT"] = old; }
    }
    assert str(r["ir_text"]) == ir;
    assert list(r["notes"]) == [] and list(r["warnings"]) == [] and list(r["report"]) == [];
}

# --- the model reader (a scripted MockLLM; no real model is called) ----------

test "model_verdict reads yes, no and unclear, and anything else as unclear" {
    assert model_verdict("yes: open(TRACE, 'a')") == ["yes", "open(TRACE, 'a')"];
    assert model_verdict("`no: --output is never passed`")[0] == "no";
    assert model_verdict("not sure")[0] == "unclear";
    assert model_verdict("")[0] == "unclear";
}

test "a write the model confirms is relabeled, and the note says both readers agreed" {
    r = _with_model(["yes: open(TRACE, 'a') appends the record"], _ir(), _skill(_WRITER));
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([n for n in r["notes"] if "found by scan+model" in n]) == 1, str(r["notes"]);
}

test "the model clears a scan false alarm and the label stays" {
    ir = _ir();
    r = _with_model(["no: the trace file is only opened when --trace is passed, and the tool never passes it"], ir, _skill(_WRITER));
    assert str(r["ir_text"]) == ir;
    assert list(r["notes"]) == [] and list(r["warnings"]) == [] and list(r["findings"]) == [], str(r["warnings"]);
    assert [f.kind for f in r["checked"]] == ["cleared"];
    assert len([x for x in r["report"] if "kept as OBSERVE" in x and "found no external write" in x]) == 1, str(r["report"]);
}

test "the model settles code the scan cannot follow" {
    ir = _ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "body": _OPAQUE});
    assert [f.kind for f in effect_findings(ir, "")] == ["unknown"];
    r = _with_model(["yes: ehr_client.Client().get appends every record to a trace file"], ir, "");
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([n for n in r["notes"] if "found by model" in n and "model: ehr_client" in n]) == 1, str(r["notes"]);
    assert len([x for x in r["report"] if "not checked" in x]) == 0, str(r["report"]);
}

test "an answer the gate cannot read leaves the scan verdict" {
    r = _with_model(["I think it might write something"], _ir(), _skill(_WRITER));
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([n for n in r["notes"] if "found by scan]" in n]) == 1, str(r["notes"]);
}

test "a model's no does not clear a write in code it was not shown whole" {
    # the model sees the first 60,000 characters of a script; the write is past them
    big = "x = 1\n" * 12000 + "open('trace.log', 'a').write('x')\n";
    r = _with_model(["no: nothing in the code writes"], _ir(), _skill(big));
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([x for x in r["report"] if "fetch_visit" in x and "truncated" in x]) == 1, str(r["report"]);
}

test "a tool the scan finds clean never reaches the model" {
    # no scripted answers: any model call would fail and leave a report line
    r = _with_model([], _ir(), _skill(_READER), 2);
    assert list(r["checked"]) == [] and list(r["report"]) == [], str(r["report"]);
}

# --- repair by the compile model, then the mechanical fallback ----------------

test "the compile model's repair is adopted when it labels the tool ACT" {
    r = _with_model([_YES, _ir("ACT")], _ir(), _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([n for n in r["notes"] if "the compile model fixed tool 'fetch_visit' (relabeled ACT, attempt 1)" in n]) == 1, str(r["notes"]);
    assert len([n for n in r["notes"] if n.startswith("autofix:")]) == 0, str(r["notes"]);
}

test "a repair that also makes the instruction ACT leaves no opcode warning" {
    r = _with_model([_YES, _ir("ACT", opcode="ACT")], _ir(), _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["nodes"][0]["type"] == "ACT", str(r["report"]);
    assert list(r["warnings"]) == [], str(r["warnings"]);
}

test "a reply that changes nothing is not adopted, and the tool falls back to ACT" {
    r = _with_model([_YES, _ir(), _ir()], _ir(), _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT";
    assert len([x for x in r["report"] if "not adopted: no finding fixed" in x]) == 2, str(r["report"]);
    assert len([n for n in r["notes"] if "autofix: G6_EFFECT relabeled tool 'fetch_visit'" in n
                and "did not fix it in 2 attempt(s)" in n]) == 1, str(r["notes"]);
}

test "a reply that is not an AG-IR is refused; a fenced one is read" {
    r = _with_model([_YES, "Sure, here is the fix.", "```yaml\n" + _ir("ACT") + "\n```"], _ir(), _skill(_WRITER), 2);
    assert len([x for x in r["report"] if "attempt 1" in x and "not an AG-IR" in x]) == 1, str(r["report"]);
    assert len([n for n in r["notes"] if "(relabeled ACT, attempt 2)" in n]) == 1, str(r["notes"]);
}

test "a repair that labels another writing tool below ACT is refused" {
    note = {"sig": "() -> str", "surface": "OBSERVE", "body": "def note():\n    open('notes.txt', 'a').write('x')\n    return 'ok'\n"};
    r = _with_model([_YES, _ir("ACT", extra={"note": note}), _ir("ACT")], _ir(), _skill(_WRITER), 2);
    assert len([x for x in r["report"] if "attempt 1" in x and "another writing tool below ACT: note" in x]) == 1, str(r["report"]);
    assert "note" not in _load_ir(str(r["ir_text"]))["tools"];
}

test "a repair that deletes the tool's code is not taken for a fix" {
    # a tool with no code lowers to a script the model writes at run time (compiler.jac,
    # embodiment ladder rung 3), so dropping the code does not stop the write
    bare = _ir(tool={"sig": "(visit_id) -> str", "surface": "OBSERVE", "doc": "Print the visit record as JSON."});
    r = _with_model([_YES, bare, bare], _ir(), _skill(_WRITER), 2);
    t = _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"];
    assert t["surface"] == "ACT" and t.get("command") == "python scripts/fetch.py {visit_id}", str(t);
    assert len([x for x in r["report"] if "not adopted: no finding fixed" in x]) == 2, str(r["report"]);
}

test "a repair that makes another writing tool's instruction OBSERVE is refused" {
    # the candidate fixes fetch_visit but turns the ACT instruction calling save_table OBSERVE
    bad = _then_save("ACT", "OBSERVE");
    r = _with_model([_YES, bad, bad], _then_save("OBSERVE", "ACT"), _skill(_WRITER), 2);
    out = _load_ir(str(r["ir_text"]));
    assert [n["type"] for n in out["nodes"] if n["id"] == "save"] == ["ACT"], str(r["report"]);
    assert len([x for x in r["report"] if "attempt 1" in x and "not adopted" in x and "'save'" in x]) == 1, str(r["report"]);
}

test "warnings hold for the IR the rung returns, not the one before repair" {
    # the adopted repair also makes the OBSERVE instruction calling save_table ACT
    r = _with_model([_YES, _then_save("ACT", "ACT")], _then_save("OBSERVE", "OBSERVE"), _skill(_WRITER), 2);
    assert [n["type"] for n in _load_ir(str(r["ir_text"]))["nodes"] if n["id"] == "save"] == ["ACT"], str(r["report"]);
    assert [w for w in r["warnings"] if "calls 'save_table'" in w] == [], str(r["warnings"]);
}

test "a repair cannot give an instruction a surface; its relabel and opcode change are kept" {
    # lowering reports what an ACT instruction with an artifact surface writes as a
    # deliverable, so a surface the repair adds could push the skill's answer out of the report
    cand = _node(_ir("ACT", opcode="ACT"), {"surface": "artifact"});
    r = _with_model([_YES, cand], _ir(), _skill(_WRITER), 2);
    out = _load_ir(str(r["ir_text"]));
    assert out["tools"]["fetch_visit"]["surface"] == "ACT", str(out["tools"]);
    assert out["nodes"][0]["type"] == "ACT" and "surface" not in out["nodes"][0], str(out["nodes"][0]);
    assert len([n for n in r["notes"] if "(relabeled ACT, attempt 1)" in n]) == 1, str(r["notes"]);
}

test "an instruction keeps the surface it had when a repair changes it" {
    cand = _node(_ir("ACT", opcode="ACT"), {"surface": "artifact"});
    r = _with_model([_YES, cand], _node(_ir(), {"surface": "workspace"}), _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["nodes"][0].get("surface") == "workspace", str(r["ir_text"]);
}

test "a reply that only sets an instruction's surface fixes nothing and is refused" {
    only = _node(_ir(), {"surface": "artifact"});
    r = _with_model([_YES, only, only], _ir(), _skill(_WRITER), 2);
    assert len([x for x in r["report"] if "not adopted: no finding fixed" in x]) == 2, str(r["report"]);
    assert len([n for n in r["notes"] if n.startswith("autofix: G6_EFFECT relabeled tool 'fetch_visit'")]) == 1, str(r["notes"]);
}

test "a repair or relabel that leaves the terminal report as it was raises no report warning" {
    # the save instruction's output is the deliverable before and after; the fix relabels
    # fetch_visit, whose instruction stays OBSERVE
    was = _returning(_node(_then_save("OBSERVE", "ACT"), {"surface": "artifact"}, 1));
    assert _report_fields(_lower(was, "t_effect")) == ["out"], _lower(was, "t_effect")[-2000:];
    cand = _returning(_node(_then_save("ACT", "ACT"), {"surface": "artifact"}, 1));
    r = _with_model([_YES, cand], was, _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["tools"]["fetch_visit"]["surface"] == "ACT", str(r["report"]);
    assert len([n for n in r["notes"] if "(relabeled ACT, attempt 1)" in n]) == 1, str(r["notes"]);
    assert list(r["report_changes"]) == [], str(r["report_changes"]);
    f = _with_model([_YES], was, _skill(_WRITER), 0);
    assert len([n for n in f["notes"] if n.startswith("autofix:")]) == 1, str(f["notes"]);
    assert list(f["report_changes"]) == [], str(f["report_changes"]);
}

test "a repair that changes which carries the terminal report shows is warned about" {
    # the save instruction's output is the one deliverable. The fetch instruction already has
    # an artifact surface; the repair makes it ACT, so lowering now also reports what it
    # writes (visit_json) as a deliverable
    was = _returning(_node(_node(_then_save("OBSERVE", "ACT"), {"surface": "artifact"}), {"surface": "artifact"}, 1));
    cand = _returning(_node(_node(_then_save("ACT", "ACT"), {"surface": "artifact", "type": "ACT"}), {"surface": "artifact"}, 1));
    r = _with_model([_YES, cand], was, _skill(_WRITER), 2);
    assert _load_ir(str(r["ir_text"]))["nodes"][0]["type"] == "ACT", str(r["report"]);
    assert len(r["report_changes"]) == 1 and "shows: (no carry) -> visit_json." in r["report_changes"][0], str(r["report_changes"]);
    assert r["report_changes"][0] in list(r["warnings"]), str(r["warnings"]);
    # a compile repair that then changes the tool's surface again keeps the warning: it is history
    fixed = _returning(_node(_node(_then_save("ACT·artifact", "ACT"), {"surface": "artifact", "type": "ACT"}), {"surface": "artifact"}, 1));
    ea = effect_after_repair(r, fixed, _skill(_WRITER), "t_effect");
    assert ea is not None and r["report_changes"][0] in list(ea["warnings"]), str(ea);
}

test "a terminal report that loses every carry is a report change; an IR with no report line is not compared" {
    was = _returning(_node(_then_save("OBSERVE", "ACT"), {"surface": "artifact"}, 1));
    bare = _returning(_then_save("OBSERVE", "ACT"));   # no deliverable, no produced carry: "t_effect done"
    assert _report_fields(_lower(bare, "t_effect")) == [], _lower(bare, "t_effect")[-2000:];
    w = _report_change(was, bare, "t_effect");
    assert "shows: out -> (no carry)." in w, w;
    assert _report_change(_then_save("OBSERVE", "ACT"), bare, "t_effect") == "";
}

test "a repair that costs the faithfulness proof is refused" {
    spec = RuleSet(skill_name="t-effect", rules=[
        Rule(id="r1", quote="Fetch the visit record.", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    # attempt 1 relabels the tool but drops the node's trace to r1; attempt 2 keeps it
    r = _with_model([_YES, _ir("ACT"), _ir("ACT", traced=True)], _ir(traced=True), _skill(_WRITER), 2, spec);
    assert len([x for x in r["report"] if "attempt 1" in x and "faithfulness proof got worse" in x]) == 1, str(r["report"]);
    assert len([n for n in r["notes"] if "(relabeled ACT, attempt 2)" in n]) == 1, str(r["notes"]);
}
