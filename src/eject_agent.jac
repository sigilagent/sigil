"""Eject a compiled skill as a whole agent, not a one-shot program.

`compile -e agent.jac` emits a program: it runs one task and exits. Useful, and
the README's headline promise, but it has no soul, no memory, no schedule and no
way to be reached — none of the runtime travels with it.

This ejects the runtime too. The result is a small self-contained project with
its own graph, its own daemon, and the skills it shipped with:

    myagent/
      jac.toml          its own project, its own store
      myagent           launcher — pins cwd, passes SIGIL_PWD
      main.jac          solve | cron | channel | daemon | chat | soul | tasks
      agent/            the bundled runtime capability modules
      agent/crystallized/   the compiled skill module(s)
      agent/skills.json     what to install on the graph at first run

What does NOT travel is the compiler. An ejected agent runs the skills it has and
cannot author new ones — smaller, no compile-time model dependency, and a
tighter surface for something you deploy. That is only possible because the
runtime was split out of the hub into `sigil_core`; `RUNTIME_MODULES` below is
the closure of that split, and `carries_compiler()` is the test that it stayed
honest.
"""

import os;
import json;
import shutil;
import from pathlib { Path }
import from .sigil_core { awaken, Registry, TaskGraph, latest_by_sig, describe_soul }
import from .sigil_runtime { repo_root }

# The runtime closure: every module an ejected agent needs, and nothing that
# reaches the compiler. Adding a module here that imports `.sigil` or
# `.compiler.*` will fail the no-compiler test rather than silently bloat the
# artifact.
glob RUNTIME_MODULES: list[str] = [
    "sigil_core", "sigil_runtime", "sigil_cron", "sigil_api", "views",
    "agent", "cron", "channels", "hooks", "approvals", "sigil_sessions",
    "sigil_secrets", "sigil_transports", "sigil_bridge", "sigil_daemon",
    "sigil_tasks", "sigil_workspace", "sigil_subagents", "sigil_mcp",
    "sigil_claude_cc", "sigil_observe", "sigil_docs", "sigil_channels_setup",
    "chat_agent", "sigil_chat", "sigil_logo"
];

# Modules that stay behind: they reach the compiler, or they only make sense in
# the full Sigil.
glob HOST_ONLY: list[str] = ["sigil", "sigil_plugins", "sigil_migrate", "sigil_mcp_serve", "eject_agent"];

def _src_dir() -> Path {
    return Path(repo_root());
}

def _templates() -> Path {
    return _src_dir() / "templates";
}

def _one_line(text: str) -> str {
    # An intent is prose the compiler wrote, and it can carry newlines and
    # quotes. Both are fatal inside a TOML basic string, and the failure shows up
    # as a parse error on first run that names nothing.
    flat = " ".join(str(text or "").split());
    return flat.replace(chr(92), "").replace('"', "'")[:200];
}

def _render(tmpl: str, subs: dict) -> str {
    out = tmpl;
    for (k, v) in dict(subs).items() {
        out = out.replace(str(k), str(v));
    }
    return out;
}

def carries_compiler(agent_root: str) -> list[str] {
    # Every ejected file that reaches the compiler. Empty is the contract; the
    # test asserts it, so a future import cannot quietly drag the front-end back
    # into something meant to be deployed.
    bad: list[str] = [];
    base = Path(agent_root);
    if not base.exists() { return bad; }
    for p in sorted(base.rglob("*.jac")) {
        try { text = p.read_text(errors="replace"); }
        except Exception as e { continue; }
        for line in text.split(chr(10)) {
            s = line.strip();
            if not s.startswith("import") { continue; }
            if ("compiler.mechanical" in s) or ("compiler.ai" in s) {
                bad.append(str(p.relative_to(base)) + ": " + s[:80]);
            }
            # `.sigil` (the hub) is the compiler's own module; `.sigil_core` and
            # `.sigil_*` are the runtime and are fine.
            if ("from .sigil {" in s) or ("from agent.sigil {" in s) {
                bad.append(str(p.relative_to(base)) + ": " + s[:80]);
            }
        }
    }
    return bad;
}

def _copy_runtime(dest: Path) -> int {
    pkg = dest / "agent";
    pkg.mkdir(parents=True, exist_ok=True);
    (pkg / "__init__.jac").write_text("");
    n = 0;
    for mod in RUNTIME_MODULES {
        for suffix in [".jac", ".impl.jac"] {
            src = _src_dir() / (mod + suffix);
            if src.exists() {
                shutil.copyfile(str(src), str(pkg / (mod + suffix)));
                n += 1;
            }
        }
    }
    return n;
}

def _copy_docs(dest: Path) -> int {
    # `read_docs` is a real tool on the tool-belt; without these it answers
    # nothing. The daemon / cron / channels pages describe exactly what an
    # ejected agent can do.
    src = _src_dir().parent / "docs" / "reference";
    if not src.exists() { return 0; }
    out = dest / "docs" / "reference";
    out.mkdir(parents=True, exist_ok=True);
    n = 0;
    for p in sorted(src.glob("*.md")) {
        shutil.copyfile(str(p), str(out / p.name));
        n += 1;
    }
    return n;
}

def _skill_rows(signatures: list[str]) -> list[dict] {
    # Resolve requested signatures (or all of them) to their latest versions.
    regs = [root -->[?:Registry]];
    if not regs { return []; }
    rows: list[dict] = [];
    for tg in latest_by_sig([regs[0] -->[?:TaskGraph]]) {
        if signatures and (str(tg.signature) not in signatures) { continue; }
        rows.append({"signature": str(tg.signature), "intent": str(tg.intent),
                     "module": str(tg.module), "version": int(tg.version)});
    }
    return rows;
}

def eject_agent(name: str, out_dir: str, signatures: list[str] = [],
                model: str = "") -> dict {
    # Build the project. Returns {ok, path, skills, modules, error}.
    rows = _skill_rows(signatures);
    if not rows {
        wanted = ", ".join(signatures) if signatures else "(any)";
        return {"ok": False, "path": "", "skills": [], "modules": 0,
                "error": "no compiled skill to eject for " + wanted
                         + " — `sigil library` lists what exists"};
    }
    agent_name = str(name or str(rows[0]["signature"]));
    dest = Path(os.path.abspath(os.path.expanduser(out_dir)));
    dest.mkdir(parents=True, exist_ok=True);

    modules = _copy_runtime(dest);
    _copy_docs(dest);

    # the compiled modules themselves, where execute_module will look for them
    crystal = dest / "agent" / "crystallized";
    crystal.mkdir(parents=True, exist_ok=True);
    (crystal / "__init__.jac").write_text("");
    shipped: list[dict] = [];
    for row in rows {
        mod_path = Path(str(row["module"]));
        if not mod_path.exists() {
            # the library remembers a module that is no longer on disk
            continue;
        }
        dst = crystal / mod_path.name;
        shutil.copyfile(str(mod_path), str(dst));
        shipped.append({"signature": row["signature"], "intent": row["intent"],
                        "module": str(dst), "version": row["version"]});
    }
    if not shipped {
        return {"ok": False, "path": str(dest), "skills": [], "modules": modules,
                "error": "the skill's compiled module is missing from disk — recompile it first"};
    }
    (dest / "agent" / "skills.json").write_text(json.dumps({"skills": shipped}, indent=2));

    soul = describe_soul();
    subs = {
        "__NAME__": agent_name,
        "__DESC__": _one_line(str(shipped[0]["intent"] or ("the " + agent_name + " agent"))),
        "__MODEL__": str(model or soul["small_model"] or "gpt-4o-mini")
    };
    for (tmpl, target, executable) in [
        ("agent_main.jac.tmpl", "main.jac", False),
        ("agent_jac_toml.tmpl", "jac.toml", False),
        ("agent_launcher.tmpl", agent_name, True)
    ] {
        body = _render((_templates() / tmpl).read_text(), subs);
        path = dest / target;
        path.write_text(body);
        if executable { os.chmod(str(path), 0o755); }
    }

    leaks = carries_compiler(str(dest));
    return {"ok": True, "path": str(dest), "skills": [s["signature"] for s in shipped],
            "modules": modules, "name": agent_name, "compiler_leaks": leaks, "error": ""};
}
