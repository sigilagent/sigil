"""autofix — the mechanical fix-forward passes. Pure code, no model."""

import os;
import tempfile;
import yaml;
import from src.compiler.mechanical.compiler { _load_ir }

def _yaml(ir: dict) -> str {
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

test "a hollow code node is re-owned to a model slot; a served one is not" {
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
    assert by_id["n_hollow"]["type"] == "GEN-RAW";
    assert by_id["n_served"]["owner"] == "code";
    assert len([f for f in r["fixes"] if "n_hollow" in str(f) and "re-owned" in str(f)]) == 1;
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
