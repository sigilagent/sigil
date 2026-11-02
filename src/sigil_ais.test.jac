"""Tests — the AIS vocabulary and the canonicalization every reader applies.

The contract is the paper's: the opcode decides the unit. A legacy document is
read, not rejected, and comes out as the composition it always meant; a
canonical document comes out unchanged.
"""

def _node(ir: dict[str, any], nid: str) -> dict[str, any] {
    for n in ir["nodes"] {
        if str(n.get("id")) == nid { return n; }
    }
    return {};
}

def _legacy() -> dict[str, any] {
    return {
        "types": {"Mode": {"kind": "enum", "members": ["fast", "slow"]}},
        "tools": {"rd": {"sig": "(path) -> str", "surface": "SENSE", "serves": ["read"]}},
        "walker": {"name": "W", "carries": {
            "task": {"type": "str", "role": "input"},
            "text": {"type": "str", "produced_by": "read"},
            "plan": {"type": "str", "produced_by": "decide"},
            "rev": {"type": "str", "produced_by": "refine"}
        }},
        "knowledge": {"hints": {"resident_on": ["recital"], "template": "be careful"}},
        "nodes": [
            {"id": "read", "type": "SENSE", "owner": "code", "reads": ["task"], "writes": ["text"]},
            {"id": "recital", "type": "SENSE", "owner": "model", "doc": "remember"},
            {"id": "decide", "type": "ROUTE", "owner": "model", "reads": ["text"], "writes": ["plan"], "doc": "pick"},
            {"id": "author", "type": "GEN-RAW", "owner": "model", "reads": ["plan"], "writes": ["rev"],
             "autonomy": {"tools": ["rd"]}},
            {"id": "alt", "type": "GEN-ENUM", "owner": "model", "reads": ["plan"], "writes": ["rev"]},
            {"id": "refine", "type": "LOOP", "owner": "model", "reads": ["rev"], "writes": ["rev"]},
            {"id": "sub", "type": "CALL", "owner": "model", "reads": ["task"], "writes": ["rev"]},
            {"id": "done", "type": "TERMINAL", "owner": "code"}
        ],
        "edges": [
            {"from": "read", "to": "recital"}, {"from": "recital", "to": "decide"},
            {"from": "decide", "to": "author"}, {"from": "decide", "to": "alt"},
            {"from": "author", "to": "done"}, {"from": "alt", "to": "refine"},
            {"from": "refine", "to": "refine", "guard": "rev == bad"}, {"from": "refine", "to": "sub"},
            {"from": "sub", "to": "done"}
        ]
    };
}

test "legacy mnemonics read as the paper's opcodes" {
    assert canonical_opcode("GEN-ENUM") == "SELECT";
    assert canonical_opcode("gen_fill") == "EXTRACT";
    assert canonical_opcode("GEN-EDIT") == "MUTATE";
    assert canonical_opcode("GEN-RAW") == "GENERATE";
    assert canonical_opcode("SENSE") == "OBSERVE";
    assert canonical_opcode("CODE") == "COMPUTE";
    assert canonical_opcode("ROUTE") == "BRANCH";
    assert canonical_opcode("SPAWN") == "PARALLEL";
    assert canonical_opcode("TERMINAL") == "RETURN";
    for op in AIS_OPCODES { assert canonical_opcode(op) == op; }
    assert canonical_surface("SENSE") == "OBSERVE";
    assert canonical_surface("ACT·artifact") == "ACT·artifact";
}

test "the opcode decides the unit" {
    for op in ["SELECT", "EXTRACT", "MUTATE", "GENERATE", "DELEGATE"] { assert unit_of(op) == "model"; }
    for op in ["COMPUTE", "OBSERVE", "ACT", "BRANCH", "LOOP", "PARALLEL", "CALL", "RETURN"] { assert unit_of(op) == "code"; }
    assert opcode_class("DELEGATE") == "delegated";
    assert opcode_class("ROUTE") == "control";
}

test "a model-chosen ROUTE becomes a SELECT over its successors feeding a BRANCH" {
    ir = _legacy();
    canonicalize_ais(ir);
    assert _node(ir, "decide")["type"] == "GENERATE";        # it also wrote `plan`
    sel = _node(ir, "decide_choose");
    br = _node(ir, "decide_branch");
    assert sel["type"] == "SELECT" and sel["owner"] == "model";
    assert br["type"] == "BRANCH" and br["owner"] == "code";
    assert ir["types"]["DecideRoute"]["members"] == ["to_author", "to_alt"];
    guards = [str(e.get("guard")) for e in ir["edges"] if str(e.get("from")) == "decide_branch"];
    assert guards == ["decide_route == to_author", "decide_route == to_alt"];
    assert ir["walker"]["carries"]["decide_route"]["produced_by"] == "decide_choose";
}

test "semantic steps with tools and legacy CALLs become DELEGATE; LOOP work splits from control" {
    ir = _legacy();
    canonicalize_ais(ir);
    assert _node(ir, "author")["type"] == "DELEGATE";
    assert _node(ir, "alt")["type"] == "SELECT";
    assert _node(ir, "sub")["type"] == "DELEGATE";
    assert _node(ir, "sub")["from_legacy"] == "CALL";
    assert _node(ir, "refine")["type"] == "GENERATE";
    assert _node(ir, "refine_loop")["type"] == "LOOP";
    back = [e for e in ir["edges"] if (str(e.get("from")) == "refine_loop") and (str(e.get("to")) == "refine")];
    assert back and (str(back[0].get("guard")) == "rev == bad");
    assert ir["tools"]["rd"]["surface"] == "OBSERVE";
    assert _node(ir, "read")["owner"] == "code";
}

test "a no-op model OBSERVE is spliced out and its knowledge moves on" {
    ir = _legacy();
    canonicalize_ais(ir);
    assert _node(ir, "recital") == {};
    assert [e for e in ir["edges"] if (str(e.get("from")) == "read") and (str(e.get("to")) == "decide")];
    assert ir["knowledge"]["hints"]["resident_on"] == ["decide"];
}

test "canonicalization is idempotent and leaves a paper-form document alone" {
    ir = _legacy();
    canonicalize_ais(ir);
    snap = str(ir);
    assert canonicalize_ais(ir) == [];
    assert str(ir) == snap;
}

test "the paper's CALL keeps its procedure and runs as code" {
    ir = {"nodes": [{"id": "c", "type": "CALL", "procedure": "count_words", "owner": "model"}]};
    canonicalize_ais(ir);
    assert ir["nodes"][0]["type"] == "CALL";
    assert ir["nodes"][0]["owner"] == "code";
}
