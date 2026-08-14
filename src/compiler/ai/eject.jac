"""AI compiler — eject: package a compiled OSP module as ONE runnable program.

The mechanical half already injects the full runtime helper library verbatim
into every generated module, so the module is self-contained — ejecting is
appending a CLI entry shim (argv -> task, model from env, print the report)
plus a `jac run` shebang, and marking the file executable:

    sigil compile SKILL.md -e agent.jac
    ./agent.jac "extract the tables from report.pdf"     # SIGIL_MODEL=... to pick the model

The AG-IR stays on the graph (TaskGraph.agir) — compile-time provenance never
rides the runnable (and never enters a prompt).
"""

import os;

glob _MCP_SERVE_SRC: str = 'def _mcp_description(name):\n    # serve the SKILL.md imperative description (the trigger surface that\n    # drives selection) instead of a bland generic line\n    import os, re\n    desc = ""\n    try:\n        sk = os.path.join(os.path.dirname(os.path.abspath(__file__)), "SKILL.md")\n        fm = open(sk, encoding="utf-8", errors="replace").read().split("---")\n        if len(fm) > 2:\n            m = re.search(r"description:\\s*\\"?(.*?)\\"?\\s*$", fm[1], re.M | re.S)\n            if m:\n                desc = " ".join(m.group(1).split())[:800]\n    except Exception:\n        pass\n    return ((desc + " ") if desc else "") + ("This tool EXECUTES the whole procedure itself (compiled program, built-in checks) — "\n        "ALWAYS call it instead of writing the logic manually; hand-rolled versions fail verification. "\n        "After it returns, VERIFY the produced files against the task requirements before finishing.")\n\ndef _mcp_serve(run_fn, model_cls, keys, name, model_name):\n    # HANDTUNE mcp-1: the artifact hosts itself as an MCP stdio server.\n    # `tools/call` invokes run() IN-PROCESS (jac runtime + model warm across\n    # calls); the artifact\'s own prints are rerouted to stderr so stdout\n    # stays a clean JSON-RPC channel.\n    import sys, json as _j, os as _os\n    real_out = sys.stdout\n    tool = {\n        "name": name,\n        "description": _mcp_description(name),\n        "inputSchema": {\n            "type": "object",\n            "properties": dict(\n                [("task", {"type": "string", "description": "One sentence: the concrete goal."})] +\n                [(k, {"type": "string", "description": "Exact value for input \'" + k + "\'."}) for k in keys]\n            ),\n            "required": ["task"],\n            "additionalProperties": False,\n        },\n    }\n    for line in sys.stdin:\n        line = line.strip()\n        if not line:\n            continue\n        try:\n            req = _j.loads(line)\n        except Exception:\n            continue\n        rid = req.get("id")\n        m = req.get("method", "")\n        if m == "initialize":\n            res = {"protocolVersion": req.get("params", {}).get("protocolVersion", "2024-11-05"),\n                   "capabilities": {"tools": {}},\n                   "serverInfo": {"name": "sigil-" + name, "version": "1.0"}}\n        elif m == "tools/list":\n            res = {"tools": [tool]}\n        elif m == "tools/call":\n            args = (req.get("params", {}) or {}).get("arguments", {}) or {}\n            task = str(args.get("task", "")) or ("apply the " + name + " skill")\n            params = {k: str(v) for k, v in args.items() if k != "task" and str(v).strip()}\n            before = set(_os.listdir("."))\n            sys.stdout = sys.stderr\n            try:\n                rep = str(run_fn(task, model_cls(model_name=model_name), "", params))\n                err = False\n            except Exception as e:\n                rep = f"{type(e).__name__}: {e}"\n                err = True\n            finally:\n                sys.stdout = real_out\n            new = sorted(set(_os.listdir(".")) - before)\n            txt = rep + (("\\nnew files: " + ", ".join(new)) if new else "")\n            res = {"content": [{"type": "text", "text": txt[:8000]}], "isError": err}\n        elif rid is None:\n            continue\n        else:\n            res = {}\n        if rid is not None:\n            real_out.write(_j.dumps({"jsonrpc": "2.0", "id": rid, "result": res}) + "\\n")\n            real_out.flush()';


def eject_program(module_src: str, name: str) -> str {
    # `#` opens a comment in jac, so the shebang line is legal source; `env -S`
    # splits the argument so `./prog.jac task` execs `jac run ./prog.jac task`.
    header = (
        "#!/usr/bin/env -S jac run\n"
        + "# " + name + " — standalone agent ejected by the sigil AI compiler.\n"
        + "# Usage: ./" + name + ".jac \"<task>\"   (or: jac run " + name + ".jac -- \"<task>\")\n"
        + "# Model: $SIGIL_MODEL, else $SIGIL_SMALL, else gpt-4o-mini.\n\n"
    );
    shim = (
        "\n\nwith entry:__main__ {\n"
        + "    import sys;\n"
        + "    import os;\n"
        + "    # accept both `./prog.jac task...` and `jac run prog.jac -- task...`\n"
        + "    _ej_raw = sys.argv;\n"
        + "    _ej_args = _ej_raw[_ej_raw.index(\"--\") + 1:] if \"--\" in _ej_raw else _ej_raw[1:];\n"
        + "    # direct args (#argparse): `--<input>=<value>` binds that walker input\n"
        + "    # verbatim, bypassing task-string grounding; other words join the task.\n"
        + "    _ej_params: dict = {};\n"
        + "    _ej_words: list = [];\n"
        + "    for _ej_a in _ej_args {\n"
        + "        _ej_s = str(_ej_a);\n"
        + "        if _ej_s.startswith(\"--\") and (\"=\" in _ej_s) {\n"
        + "            _ej_kv = _ej_s[2:].split(\"=\", 1);\n"
        + "            _ej_params[str(_ej_kv[0]).replace(\"-\", \"_\")] = str(_ej_kv[1]);\n"
        + "        } elif not _ej_s.startswith(\"-\") { _ej_words.append(_ej_s); }\n"
        + "    }\n"
        + "    _ej_task = str(\" \".join(_ej_words));\n"
        + "    _ej_keys: list = [];\n"
        + "    try { _ej_keys = list(_EJ_PARAM_KEYS); } except Exception { _ej_keys = []; }\n"
        + "    if \"--mcp\" in [str(a) for a in _ej_raw] {\n"
        + "        # MCP serve mode: the artifact hosts itself as a tool server\n"
        + "        _ej_name = os.environ.get(\"SIGIL_MODEL\", os.environ.get(\"SIGIL_SMALL\", \"gpt-4o-mini\"));\n"
        + "        _mcp_serve(run, Model, _ej_keys, \"" + name + "\", _ej_name);\n"
        + "    } elif (not _ej_task) and _ej_params {\n"
        + "        # flags-only call: params are enough - never block on the ask prompt\n"
        + "        _ej_task = \"apply this skill with the provided arguments\";\n"
        + "    }\n"
        + "    if (not _ej_task) and _tui_on() {\n"
        + "        # a terminal with no task: the artifact ASKS — it is a TUI app\n"
        + "        print(\"\");\n"
        + "        _ej_task = str(input(\"  " + name + " \u203a \"));\n"
        + "    }\n"
        + "    if not _ej_task {\n"
        + "        print(\"usage: " + name + ".jac [--<input>=<value> ...] \\\"<task>\\\"\");\n"
        + "        if _ej_keys { print(\"  direct inputs: \" + \", \".join([(\"--\" + str(k) + \"=<value>\") for k in _ej_keys])); }\n"
        + "    } else {\n"
        + "        _ej_name = os.environ.get(\"SIGIL_MODEL\", os.environ.get(\"SIGIL_SMALL\", \"gpt-4o-mini\"));\n"
        + "        _tui_banner(\"" + name + "\", _ej_task);\n"
        + "        if _ej_params { print(\"  bound args: \" + \", \".join([(str(k) + \"=\" + str(v)) for (k, v) in _ej_params.items()])); }\n"
        + "        _ej_before = set(os.listdir(\".\"));\n"
        + "        _ej_rep = run(_ej_task, Model(model_name=_ej_name), \"\", params=_ej_params);\n"
        + "        _ej_after = set(os.listdir(\".\"));\n"
        + "        _ej_diff = _ej_after - _ej_before;   # jac: no binary ops inside a comprehension iterable\n"
        + "        _ej_new = sorted([str(f) for f in _ej_diff if (str(f)[:1] != \".\") and (str(f)[:1] != \"_\") and (str(f) != \"op.py\")]);\n"
        + "        if _tui_on() { _tui_finish(_ej_rep, _ej_new); }\n"
        + "        else { print(_ej_rep); }\n"
        + "    }\n"
        + "}\n"
    );
    serve = "\n\n::py::\n" + _MCP_SERVE_SRC + "\n::py::\n";
    return header + module_src.rstrip() + serve + shim;
}

def write_program(text: str, path: str) -> str {
    d = os.path.dirname(path);
    if d { os.makedirs(d, exist_ok=True); }
    with open(path, "w") as f { f.write(text); }
    os.chmod(path, 0o755);
    return path;
}
