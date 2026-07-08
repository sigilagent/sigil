# Tests for sigil — annex of sigil.jac (`jac test sigil.jac`).
# Pure graph-algebra helpers (no model calls). Construct TaskGraph nodes in a list
# and assert version-collapsing; nothing is hung off root, so no persistence gotcha.

test "latest_by_sig keeps only the highest version per signature" {
    a1 = TaskGraph(signature="x", intent="", agir="", module="", version=1);
    a2 = TaskGraph(signature="x", intent="", agir="", module="", version=3);
    b1 = TaskGraph(signature="y", intent="", agir="", module="", version=2);
    out = latest_by_sig([a1, a2, b1]);
    assert len(out) == 2;
    sigs = sorted([t.signature for t in out]);
    assert sigs == ["x", "y"];
    keptx = [t for t in out if t.signature == "x"][0];
    assert keptx.version == 3;
}

test "memory_context renders bullet facts, empty for none" {
    assert memory_context([]) == "";
    m = Memory(content="user likes CSV");
    ctx = memory_context([m]);
    assert "user likes CSV" in ctx;
}
