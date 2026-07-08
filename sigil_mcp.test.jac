# Tests for sigil_mcp — annex of sigil_mcp.jac (`jac test sigil_mcp.jac`).
# The non-raising sentinels: no servers / disabled servers must degrade honestly.

test "digest of no/disabled servers is empty" {
    assert digest([]) == "";
    assert digest([{"name": "gh", "enabled": False}]) == "";
}

test "tools_for no/disabled servers yields no tools" {
    assert tools_for([]) == [];
    assert tools_for([{"name": "gh", "enabled": False}]) == [];
}

test "dispatch with no registered servers returns None (caller falls back)" {
    assert dispatch("anything", []) is None;
}
