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

test "runtime INFO chatter is muted unless SIGIL_VERBOSE asks for it" {
    import os;
    import logging;
    # sigil_core's import-time entry gates the jac runtime loggers: unless this
    # run opted into SIGIL_VERBOSE, serializer/memory INFO narration is filtered.
    if not (os.getenv("SIGIL_VERBOSE") or "").strip() {
        assert logging.getLogger("jaclang.runtimelib").getEffectiveLevel() >= int(logging.WARNING);
    }
}

test "verbose: off by default, togglable, and SIGIL_VERBOSE wins for one run" {
    import os;
    os.environ.pop("SIGIL_VERBOSE", None);
    assert not describe_soul()["verbose"], "verbose must default OFF (raw token stream is a debugging view)";
    assert not verbose_mode();
    assert "on" in configure("verbose", "on");
    assert describe_soul()["verbose"];
    assert verbose_mode();
    # the env var overrides the graph, for one run
    os.environ["SIGIL_VERBOSE"] = "0";
    assert not verbose_mode();
    os.environ["SIGIL_VERBOSE"] = "1";
    assert verbose_mode();
    os.environ.pop("SIGIL_VERBOSE", None);
    assert "off" in configure("verbose", "off");
    assert not verbose_mode();
}

test "clean_verdict strips model decoration so a HIT stays a HIT" {
    known = ["hackernews_relevant_posts", "clean_csv"];
    # the live failure: sonnet wrapped the signature in backticks and the
    # exact-matcher read a perfect HIT as a MISS
    assert clean_verdict("`hackernews_relevant_posts`", known) == "hackernews_relevant_posts";
    assert clean_verdict("  NONE \n", known) == "NONE";
    assert clean_verdict("'clean_csv'.", known) == "clean_csv";
    assert clean_verdict("MUTATE:`clean_csv`", known) == "MUTATE:clean_csv";
    # prose naming exactly one known signature resolves to that signature
    assert clean_verdict("The right skill is hackernews_relevant_posts.", known) == "hackernews_relevant_posts";
    assert clean_verdict("This needs a MUTATE of clean_csv to fit.", known) == "MUTATE:clean_csv";
    # ambiguous or unknown replies pass through untouched (select_target
    # already treats them as a MISS)
    assert clean_verdict("gibberish", known) == "gibberish";
    assert clean_verdict("clean_csv or hackernews_relevant_posts", known) == "clean_csv or hackernews_relevant_posts";
}

test "tier accessors track awaken()'s rebind" {
    # `import from` copies a glob's binding at import time: a module that
    # imported `router` directly kept the env-default Model (ollama qwen)
    # forever, and awaken()'s rebind never reached it — cron fires called
    # ollama on a machine whose every configured tier was claude-cc. The
    # accessors execute in sigil_core, so a config change followed by
    # awaken() must be visible through them. (Behavioral on purpose: the
    # import-copy identity itself differs across jac releases.)
    keep_claude = claude_mode();
    use_claude_code(False);   # the claude-mode override would rewrite our test names
    soul = awaken();
    keep_r = soul.router_model;
    keep_f = soul.frontier_model;
    soul.router_model = "test-provider/rebound-router";
    soul.frontier_model = "test-provider/rebound-frontier";
    awaken();
    assert getattr(cur_router(), "model_name", "") == "test-provider/rebound-router";
    assert getattr(cur_frontier(), "model_name", "") == "test-provider/rebound-frontier";
    # restore so later tests in this process see the original config
    soul.router_model = keep_r;
    soul.frontier_model = keep_f;
    use_claude_code(keep_claude);
    awaken();
}

test "next_version lands a re-registration ABOVE the existing lineage" {
    reg = Registry();
    assert next_version(reg, "csv-clean") == 1;
    reg +>:Crystallized:+> TaskGraph(signature="csv-clean", intent="", agir="", module="", version=1);
    reg +>:Crystallized:+> TaskGraph(signature="csv-clean", intent="", agir="", module="", version=13);
    reg +>:Crystallized:+> TaskGraph(signature="other-skill", intent="", agir="", module="", version=99);
    # a fresh compile of an existing signature must be routable: above v13,
    # not a shadowed duplicate v1 that latest_by_sig can never pick
    assert next_version(reg, "csv-clean") == 14;
    assert next_version(reg, "brand-new") == 1;
}

test "lineage_src recovers the original skill document across versions" {
    reg = Registry();
    assert lineage_src(reg, "hn-watch") == "";
    reg +>:Crystallized:+> TaskGraph(signature="hn-watch", intent="", agir="", module="", version=1, skill_src="# the original SKILL.md");
    reg +>:Crystallized:+> TaskGraph(signature="hn-watch", intent="", agir="", module="", version=2, skill_src="");
    reg +>:Crystallized:+> TaskGraph(signature="hn-watch", intent="", agir="", module="", version=3, skill_src="");
    # v2/v3 (mutation-era) lost the source; the lineage still knows it
    assert lineage_src(reg, "hn-watch") == "# the original SKILL.md";
    # a newer version WITH a source wins over the older one
    reg +>:Crystallized:+> TaskGraph(signature="hn-watch", intent="", agir="", module="", version=4, skill_src="# amended SKILL.md");
    assert lineage_src(reg, "hn-watch") == "# amended SKILL.md";
    # other signatures never bleed in
    reg +>:Crystallized:+> TaskGraph(signature="other", intent="", agir="", module="", version=9, skill_src="# other doc");
    assert lineage_src(reg, "hn-watch") == "# amended SKILL.md";
}
