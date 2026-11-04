# Tests for sigil_channel_compile — annex of sigil_channel_compile.jac.
# Slash commands, drafts and the finish message. No model, no compile, no network.

import tempfile;

test "slash commands are recognised, everything else goes to the model" {
    assert channel_command("/build") == {"cmd": "build", "arg": ""};
    assert channel_command("  /compile ~/skills/hn/SKILL.md ") == {"cmd": "compile", "arg": "~/skills/hn/SKILL.md"};
    assert channel_command("/Reset")["cmd"] == "new", "/reset is /new";
    assert channel_command("/build@my_sigil_bot")["cmd"] == "build", "Telegram group form";
    assert channel_command("/weather in Colombo")["cmd"] == "", "unknown commands reach the model";
    assert channel_command("build it please")["cmd"] == "";
    assert channel_command("/")["cmd"] == "";
}

test "a drafted SKILL.md is unwrapped, named and slugged" {
    md = "```markdown\n---\nname: HN Comments\ndescription: x\n---\n# Steps\n```";
    clean = strip_fences(md);
    assert clean.startswith("---\nname: HN Comments"), clean;
    assert "```" not in clean;
    assert frontmatter_name(clean, "fallback") == "HN Comments";
    assert frontmatter_name("no frontmatter", "fallback") == "fallback";
    assert slug("HN Comments!") == "hn_comments";
    assert slug("") == "agent";
}

test "a draft is this chat's, and a revision replaces it" {
    base = tempfile.mkdtemp();
    was = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = os.path.join(base, "home");
    try {
        assert pending_draft("whatsapp", "user:1") == {}, "no draft yet";
        p1 = save_draft("whatsapp", "user:1", "hn comments", "---\nname: hn\n---\nv1", base);
        p2 = save_draft("whatsapp", "user:1", "hn comments", "---\nname: hn\n---\nv2", base);
        assert p1 == p2, "same name, same file";
        with open(p2) as f { assert "v2" in f.read(); }
        assert pending_draft("whatsapp", "user:1")["path"] == p2;
        assert pending_draft("whatsapp", "user:2") == {}, "another person's chat has no draft";
        assert pending_draft("telegram", "user:1") == {}, "nor does another channel";
        # learn_skill never overwrites: it writes beside an existing folder
        p3 = write_skill_draft(base, "hn comments", "x", True);
        assert p3 != p2 and p3.endswith(os.path.join("hn_comments_2", "SKILL.md")), p3;
    } finally {
        if was is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = was; }
    }
}

test "/build with no draft, and /compile of a missing file, explain instead of starting" {
    base = tempfile.mkdtemp();
    was = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = os.path.join(base, "home");
    try {
        assert "/compile <path>" in handle_command("whatsapp", "user:9", "build", "", base);
        assert "Send /compile" in handle_command("whatsapp", "user:9", "compile", "", base);
        miss = handle_command("whatsapp", "user:9", "compile", "nope/SKILL.md", base);
        assert miss.startswith("Couldn't start the compile: no such file"), miss;
        assert "/status" in handle_command("whatsapp", "user:9", "help", "", base);
    } finally {
        if was is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = was; }
    }
}

test "the finish message says what happened" {
    ok = compile_notice({"name": "hn_comments"}, {"ok": True, "signature": "hn_comments", "version": 2});
    assert ok.startswith("✓ Compiled hn_comments (v2)"), ok;
    warn = compile_notice({"name": "a"}, {"ok": True, "signature": "a", "version": 1, "save_warning": "lost a race"});
    assert "could not be saved" in warn, warn;
    bad = compile_notice({"name": "a"}, {"ok": False, "status": "failed", "issues": ["G2: no output", "G5: empty"]});
    assert bad.startswith("✗ The compile of a failed: G2: no output; G5: empty"), bad;
    err = compile_notice({"name": "a"}, {"ok": False, "status": "failed", "error": "chatgpt: out of credits"});
    assert "out of credits" in err;
}
