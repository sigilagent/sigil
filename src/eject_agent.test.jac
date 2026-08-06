# Tests for eject_agent — annex of eject_agent.jac.
#
# The load-bearing property is a negative one: an ejected agent must not carry
# the compiler. That is checked against the SOURCE modules rather than against a
# finished ejection, so it holds without needing a compiled skill on the graph —
# and so the failure names the import that broke it, at the moment someone adds
# it, rather than months later inside somebody's deployment.

import os;
import from pathlib { Path }

def _src(mod: str) -> str {
    p = Path(repo_root()) / (mod + ".jac");
    return p.read_text(errors="replace") if p.exists() else "";
}

test "every runtime module exists" {
    missing: list[str] = [];
    for mod in RUNTIME_MODULES {
        if not (Path(repo_root()) / (mod + ".jac")).exists() { missing.append(mod); }
    }
    assert missing == [], f"RUNTIME_MODULES names modules that do not exist: {missing}";
}

test "no runtime module reaches the compiler" {
    # The whole reason the hub was split. A single `import from .sigil` or
    # `.compiler.*` in this closure puts the AI front-end back into an artifact
    # meant to be deployed.
    leaks: list[str] = [];
    for mod in RUNTIME_MODULES {
        for line in _src(mod).split(chr(10)) {
            s = line.strip();
            if not s.startswith("import") { continue; }
            if ("compiler.mechanical" in s) or ("compiler.ai" in s) {
                leaks.append(mod + ": " + s[:70]);
            }
            if "from .sigil {" in s { leaks.append(mod + ": " + s[:70]); }
        }
    }
    assert leaks == [], f"these would drag the compiler into an ejected agent: {leaks}";
}

test "the hub and the compiler-bound modules stay behind" {
    for mod in HOST_ONLY {
        assert mod not in RUNTIME_MODULES, f"{mod} must not travel with an ejected agent";
    }
    assert "sigil" in HOST_ONLY, "sigil.jac IS the compiler half";
    assert "sigil_core" in RUNTIME_MODULES, "the runtime core is the point of the split";
}

test "sigil_core itself is compiler-free" {
    # Code, not prose: the module's docstring explains the split and names the
    # compiler, which is exactly right and must not fail this test.
    body = _src("sigil_core");
    assert body, "sigil_core.jac must exist";
    code: list[str] = [];
    for line in body.split(chr(10)) {
        s = line.strip();
        if s.startswith("#") { continue; }
        code.append(s);
    }
    joined = chr(10).join(code);
    assert "import from .compiler" not in joined;
    assert "transpile_ir(" not in joined, "sigil_core must not call the lowerer";
    assert "builtin_catalogue(" not in joined;
}

test "the moved archetypes keep their old names as aliases" {
    # Without these, every existing graph quarantines its Soul and its whole
    # skill library on the next run and comes back empty. This is not a
    # nice-to-have; it is the difference between a refactor and data loss.
    body = _src("sigil_core");
    for name in ["Soul", "Registry", "TaskGraph", "Memory", "Attempt", "McpServer",
                 "Embodies", "Anchored", "Crystallized", "Remembers", "Owns", "Ran"] {
        assert ('@archetype_alias("src.sigil.' + name + '")') in body,
               f"{name} moved modules with no alias — existing graphs would lose it";
    }
}

test "the templates are present and parameterised" {
    tdir = Path(repo_root()) / "templates";
    for f in ["agent_main.jac.tmpl", "agent_jac_toml.tmpl", "agent_launcher.tmpl"] {
        p = tdir / f;
        assert p.exists(), f"missing template {f}";
        assert "__NAME__" in p.read_text(), f"{f} does not take the agent's name";
    }
    assert "__MODEL__" in (tdir / "agent_jac_toml.tmpl").read_text();
}

test "the ejected CLI refuses to compile, in words" {
    body = (Path(repo_root()) / "templates" / "agent_main.jac.tmpl").read_text();
    assert 'cmd == "compile"' in body, "an ejected agent must answer `compile`, not 404 on it";
    assert "without the compiler" in body;
    # and it must route through the no-compile solver
    assert "run_task" in body;
}

test "an intent becomes a legal TOML value" {
    # The compiler writes prose intents, with newlines and quotes in them. Either
    # one ends up as a parse error on the ejected agent's very first run.
    assert chr(10) not in _one_line("two" + chr(10) + "lines");
    assert _one_line("two" + chr(10) + "lines") == "two lines";
    assert '"' not in _one_line('he said "hi" loudly');
    assert _one_line("   padded   out   ") == "padded out";
    assert len(_one_line("x" * 500)) <= 200;
    assert _one_line("") == "";
}

test "carries_compiler reports nothing for a directory that is not there" {
    assert carries_compiler("/nonexistent/path/for/a/test") == [];
}
