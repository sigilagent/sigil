# Tests for sigil_docs — annex (`jac test src/sigil_docs.jac`).
# Loads the real docs/reference markdown; no model, no network.

test "list_docs enumerates the reference topics" {
    out = list_docs();
    for slug in ["configuration", "workspace-and-sandbox", "models", "channels"] {
        assert slug in out, slug + " missing from list_docs";
    }
}

test "doc_topics returns slug/title/summary entries" {
    ts = doc_topics();
    assert len(ts) >= 6, str(len(ts));
    got = [str(t["slug"]) for t in ts];
    assert "overview" in got, str(got);
    for t in ts { assert str(t["title"]), "empty title for " + str(t["slug"]); }
}

test "read_doc: exact slug" {
    body = read_doc("models");
    assert "# Models" in body, body[:80];
    assert "frontier" in body and "small" in body, body[:200];
}

test "read_doc: fuzzy match (substring + word overlap)" {
    assert "# Workspace and sandbox" in read_doc("sandbox");
    assert "# Configuration" in read_doc("config");
    assert "# Models" in read_doc("what models can i use");
}

test "read_doc: unknown topic lists what's available" {
    out = read_doc("totally-made-up");
    assert "No reference topic matches" in out, out;
    assert "configuration" in out, out;
}
