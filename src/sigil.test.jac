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

test "describe_soul reports the EFFECTIVE tiers the chat banner shows" {
    # The banner reads chat_model to tell you who you are talking to. Reporting
    # the graph value there meant `sigil --claude chat` announced "gpt-4o-mini"
    # while every word came from Claude.
    use_claude_code(False);
    plain = describe_soul();
    use_claude_code(True);
    claude = describe_soul();
    use_claude_code(False);

    assert str(claude["chat_model"]).startswith("claude-cc/");
    assert str(claude["frontier_model"]).startswith("claude-cc/");
    assert str(claude["small_model"]).startswith("claude-cc/");
    assert str(claude["router_model"]).startswith("claude-cc/");
    # and the override is claude-mode only — it must not rewrite the graph
    assert not str(plain["chat_model"]).startswith("claude-cc/");
    assert describe_soul()["chat_model"] == plain["chat_model"];
}

test "verbose: on by default, togglable, and SIGIL_VERBOSE wins for one run" {
    import os;
    os.environ.pop("SIGIL_VERBOSE", None);
    assert describe_soul()["verbose"], "verbose must default ON";
    assert verbose_mode();
    assert "off" in configure("verbose", "off");
    assert not describe_soul()["verbose"];
    assert not verbose_mode();
    # the env var overrides the graph, for one run
    os.environ["SIGIL_VERBOSE"] = "1";
    assert verbose_mode();
    os.environ["SIGIL_VERBOSE"] = "0";
    assert not verbose_mode();
    os.environ.pop("SIGIL_VERBOSE", None);
    assert "on" in configure("verbose", "on");
    assert verbose_mode();
}
