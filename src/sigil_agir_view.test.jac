# Tests for sigil_agir_view — annex of sigil_agir_view.jac.
# Pure projection: no graph, no model. The cookbook AG-IRs are the fixtures,
# which also makes this a regression test on the shared reader — every one of
# them must stay drawable, and confirm_delete.agir did not parse at all until
# the relaxer moved into sigil_agir_yaml.

import from pathlib { Path }
import from .sigil_runtime { repo_root }

def _cookbook(name: str) -> str {
    return (Path(repo_root()).parent / "docs" / "reference" / "agir-cookbook"
            / (name + ".agir")).read_text();
}

test "parse_agir: a pipeline IR projects to its nodes, edges and dataflow" {
    g = parse_agir(_cookbook("word_frequency"));
    assert g["warning"] == "";
    ids = [str(n["id"]) for n in g["nodes"]];
    assert ids == ["read_input", "compute", "write_output", "done"];
    assert len(g["edges"]) == 3;
    # the spine is directed and every edge names real nodes
    assert str((g["edges"])[0]["src"]) == "read_input";
    assert str((g["edges"])[0]["dst"]) == "compute";
    # dataflow survives the projection — this is what the node tooltip shows
    compute = [n for n in g["nodes"] if str(n["id"]) == "compute"][0];
    assert compute["reads"] == ["input_text"];
    assert compute["writes"] == ["output_text"];
    assert str(compute["tool"]) == "count_top_words";
}

test "parse_agir: node types map to their primitive family" {
    g = parse_agir(_cookbook("word_frequency"));
    by_id: dict = {};
    for n in g["nodes"] { by_id[str(n["id"])] = str(n["group"]); }
    assert by_id["read_input"] == "boundary";      # SENSE
    assert by_id["compute"] == "code";             # CODE
    assert by_id["write_output"] == "boundary";    # ACT
    assert by_id["done"] == "terminal";
    # a model-owned slot is what the canvas draws as a diamond
    g2 = parse_agir(_cookbook("contact_to_csv"));
    gen = [n for n in g2["nodes"] if str(n["type"]).startswith("GEN-")];
    assert gen;
    for n in gen { assert str(n["group"]) == "mind"; }
}

test "parse_agir: a tool's `serves` binds it to the node it runs on" {
    g = parse_agir(_cookbook("word_frequency"));
    read = [n for n in g["nodes"] if str(n["id"]) == "read_input"][0];
    assert str(read["tool"]) == "read_file";
    assert "count_top_words" in g["tools"];
}

test "parse_agir: every cookbook AG-IR stays drawable" {
    # The relaxed reader is why confirm_delete parses: its carries are flow maps
    # (`{ type: list[str], produced_by: … }`) that strict YAML rejects outright.
    for name in ["word_frequency", "contact_to_csv", "confirm_delete",
                 "md_to_text", "doc_tldr", "grep_summary", "bug_report"] {
        g = parse_agir(_cookbook(name));
        assert g["nodes"], name + " produced no nodes";
        assert g["warning"] == "", name + " warned: " + str(g["warning"]);
    }
}

test "parse_agir: an undecodable IR warns instead of raising" {
    assert "no stored AG-IR" in str(parse_agir("")["warning"]);
    assert "no stored AG-IR" in str(parse_agir("   ")["warning"]);
    g = parse_agir("%%% not yaml [");
    assert g["warning"];
    assert g["nodes"] == [];
}

test "parse_agir: an edge naming an unknown node is reported, not dropped silently" {
    ir = "nodes:\n  - id: a\n    type: CODE\nedges:\n  - {from: a, to: ghost, modality: mandatory}\n";
    g = parse_agir(ir);
    assert len(g["nodes"]) == 1;
    assert len(g["edges"]) == 1;          # kept, so the inconsistency is visible
    assert "unknown nodes" in str(g["warning"]);
    assert "a->ghost" in str(g["warning"]);
}

test "parse_agir: an IR with no nodes says so" {
    g = parse_agir("agir_version: 0.1\nshape: pipeline\n");
    assert g["nodes"] == [];
    assert "no nodes" in str(g["warning"]);
}
