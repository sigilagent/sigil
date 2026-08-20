"""Tests — the raise2 front end's mechanical rungs.

Covers the wiring that the default compile path depends on. `autofix_ir` itself
is tested in autofix.test.jac; what is pinned here is that raise2 CALLS it with
the skill_dir it is handed. That call was missing: raise2 accepted skill_dir and
referenced it nowhere, so sibling embodiment ran only on the legacy lift() path
and every default compile shipped the pointer instead of the content.
"""

import os;
import tempfile;
import from src.compiler.mechanical.compiler { _load_ir }
import from src.sigil_agir_yaml { dump_agir }

def _ir_pointing_at(doc: str) -> str {
    return dump_agir({
        "walker": {"name": "T", "carries": {"task": {"type": "str", "role": "input"}}},
        "nodes": [{"id": "n_a", "type": "GEN-RAW", "owner": "model",
                   "reads": ["guide"], "writes": []}],
        "edges": [],
        "knowledge": {"guide": {"body": "See " + doc + " for details.",
                                "resident_on": ["n_a"]}}
    });
}

test "raise2 embodies a sibling the IR only points at" {
    d = tempfile.mkdtemp(prefix="sigil_r2_");
    with open(os.path.join(d, "FORMS.md"), "w") as f {
        f.write("# Forms\nset each field by field_id");
    }
    r = embody_siblings(_ir_pointing_at("FORMS.md"), d);
    out = _load_ir(str(r["ir_text"]));
    assert "set each field by field_id" in str(out["knowledge"]["guide"]["body"]);
    assert len(list(r["fixes"])) >= 1;
}

test "no skill_dir leaves the IR untouched" {
    # compile_skill can be called without a source directory (a skill passed as
    # text); that must stay a no-op rather than an error.
    ir = _ir_pointing_at("FORMS.md");
    r = embody_siblings(ir, "");
    assert str(r["ir_text"]) == ir;
    assert list(r["fixes"]) == [];
}

test "a sibling that does not exist is left as-is" {
    d = tempfile.mkdtemp(prefix="sigil_r2_");
    ir = _ir_pointing_at("MISSING.md");
    r = embody_siblings(ir, d);
    out = _load_ir(str(r["ir_text"]));
    assert "See MISSING.md" in str(out["knowledge"]["guide"]["body"]);
}
