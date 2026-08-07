# Tests for sigil_runtime — annex of sigil_runtime.jac (`jac test sigil_runtime.jac`).
# Pure path/slug/name helpers; no subprocess, no model.

test "module_name slugs the signature and appends the version" {
    assert module_name("PDF Extract!", 2) == "pdf_extract_v2";
    assert module_name("a b/c", 1) == "a_b_c_v1";
    assert module_name("email-extract", 1) == "email_extract_v1";
}

test "agir_name reads the frontmatter name, else slugs the head" {
    assert agir_name("name: Email-Extractor\nshape: gen") == "email_extractor";
    assert agir_name("name: \"CSV To Chart\"\n") == "csv_to_chart";
    assert agir_name("Just a plain description with no name field") == "just_a_plain_description_with_no_name_field"[:48];
}

test "repo_root points at the agent package dir and the contract loads" {
    # repo_root() is the dir that owns sigil_runtime.jac — the `src/` agent package,
    # where contracts/ and crystallized/ live as siblings. That default_contract()
    # loads is the real invariant (contracts/ resolves relative to repo_root()).
    assert repo_root().endswith("src");
    assert len(default_contract()) > 100;
}

test "skill_description reads the SKILL.md frontmatter trigger line" {
    md = "---\nname: clean-csv\ndescription: Use when a messy CSV needs clean headers.\n---\n\n# Clean a CSV\n";
    assert skill_description(md) == "Use when a messy CSV needs clean headers.";
    # quoted, and with a colon in the value (split on the FIRST colon only)
    assert skill_description("---\ndescription: \"Use when: a thing\"\n---\n") == "Use when: a thing";
}

test "skill_description folds a YAML block/folded scalar, not the >- marker" {
    # `description: >-` puts the value on the following indented lines. The old
    # parser returned the literal ">-" marker, which became the skill's intent
    # and poisoned eval_skill's default probe (a real run judged against an
    # empty task -> false-negative 15/100 -> needless relearn).
    folded = "---\nname: hn\ndescription: >-\n  Scan the latest popular Hacker News\n  stories relevant to agentic AI.\ntags: [x]\n---\n";
    assert skill_description(folded) == "Scan the latest popular Hacker News stories relevant to agentic AI.";
    # literal block scalar `|` and a chomp indicator `|-`
    literal = "---\ndescription: |-\n  First line.\n  Second line.\n---\n";
    assert skill_description(literal) == "First line. Second line.";
    # a bare `>` with no chomp char still folds
    assert "one two" == skill_description("---\ndescription: >\n  one\n  two\n---\n");
    # inline value on the key line is unchanged (regression guard)
    assert skill_description("---\ndescription: Plain inline value.\n---\n") == "Plain inline value.";
}

test "skill_description returns empty when there is nothing to read" {
    assert skill_description("# Just a heading\n\nno frontmatter here") == "";
    assert skill_description("---\nname: x\n---\n") == "";
    assert skill_description("") == "";
    # a `description:` AFTER the frontmatter block is body text, not the trigger
    assert skill_description("---\nname: x\n---\ndescription: not this one\n") == "";
}

test "the compiled-module driver installs the claude-cc provider when needed" {
    # The module runs in a SUBPROCESS, so an in-process provider registration does
    # not reach it: the driver has to install it itself or claude mode silently
    # covers the compiler and not execution.
    drv = _DRIVER.format(mod="x_v1", marker="M");
    assert "import sigil_claude_cc;" in drv;
    assert "sigil_claude_cc.is_claude_cc(model_name)" in drv;
    assert "config=cfg" in drv;
}
