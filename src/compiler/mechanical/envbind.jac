"""Environment binding (SkillRT AOT Pass 2, mechanized).

SkillRT's finding (arXiv 2604.03088 §Pass-2): skills depend on packages and
commands not guaranteed to exist at runtime; a missing dependency costs a
frontier model +56-69% tokens diagnosing the mismatch and drops weak models to
33-67% success. Their fix — extract a dependency manifest at compile time,
probe presence at install time, bind before the skill runs — is fully
mechanical, so it lands in the MECHANICAL half.

Our own caught-live bugs are exactly this class (pipeline B.9): the
slack-gif-creator `core/` module that was never shipped (ModuleNotFoundError
took the walker down AFTER tokens were spent — the OSP zero was a crash, not a
capability gap), the `sys.executable`-is-the-jac-binary trap, the
canvas-design relative bundle path. Every one was found at RUN time by a
debugging session; all were knowable at COMPILE time from the tool bodies.

Three exports:
  extract_manifest(ir)  -> {"py": {mod: {"pip": name, "tools": [...]}},
                            "bin": {cmd: [tools]}}
  probe_manifest(m)     -> {"missing_py": [[mod, pip, tools]],
                            "missing_bin": [[cmd, tools]]}   (probes THIS runtime)
  preflight_src(m)      -> the `_ENV_MANIFEST` + `_env_preflight()` python
                           source injected into every lowered module ("" when
                           the manifest is empty)

The compile-time probe feeds gate G7 (ai/gates.jac); the emitted preflight
re-probes at `run()` entry on the EXECUTION host — SkillRT's install-time /
run-time split. Imports resolve in the hermetic rt-closure interpreter, so a
missing module cannot be fixed from OUTSIDE the artifact (#149: the agent's
`pip install` lands in an interpreter the closure never sees; under `jac run`
`sys.executable` is the jac binary, and `jac -m pip` IS the closure's pip).
The preflight therefore remediates by default: it installs missing modules
into the artifact-local `.jac/pydeps` beside the module via the closure's own
pip and rejoins that dir to sys.path on every run — the artifact owns its
runtime environment, mutating only its own directory, never the host.
SIGIL_ENV_AUTOBIND=0 opts out. Whatever still cannot bind fails LOUD (stderr
+ AGIR_PROGRESS, naming the probed interpreter and a copy-pasteable install
command) and never raises.
"""

import sys;
import json;
import shutil;
import textwrap;

# import name -> pip distribution, where they differ (SkillRT's "system-aware
# probing" table, seeded with the imports the skill corpus actually uses)
glob PIP_MAP: dict = {
    "fitz": "pymupdf", "PIL": "pillow", "docx": "python-docx",
    "pptx": "python-pptx", "cv2": "opencv-python", "yaml": "pyyaml",
    "bs4": "beautifulsoup4", "sklearn": "scikit-learn",
    "Crypto": "pycryptodome", "dateutil": "python-dateutil",
    "dotenv": "python-dotenv", "PyPDF2": "pypdf2", "pdf2image": "pdf2image",
    "markdown_it": "markdown-it-py", "jwt": "pyjwt", "magic": "python-magic",
    "gifski": "gifski", "moviepy": "moviepy", "imageio_ffmpeg": "imageio-ffmpeg"
};

# modules the generated module's own runtime always provides — never manifest
glob _PROVIDED: list = ["byllm", "jaclang", "mtllm", "jac"];

# shell tokens that are flow/coreutils noise, not bindable dependencies
glob _SHELL_NOISE: list = [
    "cd", "ls", "cat", "echo", "mkdir", "cp", "mv", "rm", "tar", "touch",
    "test", "true", "false", "set", "export", "source", "if", "then", "else",
    "elif", "fi", "for", "while", "do", "done", "case", "esac", "exit",
    "return", "shift", "read", "wait", "trap", "printf", "pwd", "chmod",
    "chown", "sleep", "head", "tail", "grep", "sed", "awk", "cut", "sort",
    "uniq", "wc", "tee", "xargs", "find", "which", "env", "sh", "bash", "zsh",
    "kill", "nohup", "ln", "date", "basename", "dirname",
    # JS/CSS/HTML tokens that surface when a shell-ish body embeds web content
    # (a first token like `const` is never a PATH binary anyone would bind)
    "const", "let", "var", "function", "export", "import", "module",
    "require", "body", "html", "div", "span", "class", "await", "async",
    # python keywords/idioms: a python body that fails ast.parse (stray indent,
    # partial def) gets shell-classified, and its keywords must not surface as
    # "binaries" (caught live: canvas-design flagged 'def'/'from'/'with')
    "def", "return", "from", "with", "except", "try", "raise", "pass",
    "elif", "lambda", "yield", "global", "nonlocal", "del", "assert",
    "print", "in", "is", "not", "and", "or", "None", "True", "False"
];

def _dct(v: any) -> dict {
    return v if isinstance(v, dict) else {};
}

def _stdlib_names() -> any {
    # sys.stdlib_module_names is py3.10+; the jac runtime is well past that.
    return sys.stdlib_module_names;
}

def _top_module(name: any) -> str {
    return str(name).split(".")[0];
}

def _body_imports(body: str) -> list {
    # AST over the verbatim tool body. Bodies arrive as bare statements (often
    # with a top-level `return`) or as a complete def — parse the wrapped form
    # first (accepts both), fall back to a plain parse.
    import ast;
    src = textwrap.dedent(str(body));
    tree: any = None;
    try { tree = ast.parse("def _f():\n" + textwrap.indent(src, "    ")); }
    except Exception {
        try { tree = ast.parse(src); }
        except Exception { return []; }
    }
    mods: list = [];
    for nd in ast.walk(tree) {
        if isinstance(nd, ast.Import) {
            for al in nd.names { mods.append(_top_module(al.name)); }
        } elif isinstance(nd, ast.ImportFrom) {
            # a relative import can never resolve inside a lowered module —
            # surface its target name so the gate names the missing ship
            if nd.module { mods.append(_top_module(nd.module)); }
        }
    }
    out: list = [];
    for m in mods {
        if m and (m not in out) { out.append(m); }
    }
    return out;
}

def _command_bins(text: str) -> list {
    # First token of each command line; skip comments, env-assignments,
    # heredoc bodies, continuation/flag lines and shell noise. Deliberately
    # conservative — a probe list full of coreutils (or of heredoc CONTENT
    # mistaken for commands) is worse than none (SkillRT: presence checks
    # must stay lightweight).
    import re;
    out: list = [];
    heredoc = "";
    for ln in str(text).splitlines() {
        s = ln.strip();
        if heredoc {
            # inside a `<<EOF` block: content, not commands
            if s == heredoc { heredoc = ""; }
            continue;
        }
        if (not s) or s.startswith("#") { continue; }
        tok = s.split(" ")[0].strip();
        if ("=" in tok) or (not tok) { continue; }
        if tok.startswith("./") or tok.startswith("$") or tok.startswith("-") { continue; }
        base = tok.split("/")[-1];
        # a PATH binary is lowercase alnum with dashes/underscores/plus and an
        # optional trailing version digit; dots / uppercase / punctuation mean
        # we drifted into file names, JS/CSS content, or prose. Single letters
        # are loop variables, never binaries.
        if not re.fullmatch(r"[a-z][a-z0-9_+-]*[0-9]?", base) { continue; }
        if (len(base) < 2) or (base in _SHELL_NOISE) { continue; }
        hd = re.search(r"<<-?\s*['\"]?(\w+)", s);
        if hd { heredoc = str(hd.group(1)); }
        if base not in out { out.append(base); }
    }
    return out;
}

def _looks_shell_body(body: str) -> bool {
    # a body that does not parse as python but has command-looking lines
    import ast;
    try {
        ast.parse("def _f():\n" + textwrap.indent(textwrap.dedent(str(body)), "    "));
        return False;
    } except Exception { return True; }
}

def pip_name(mod: str) -> str {
    return str(PIP_MAP.get(mod, mod));
}

def extract_manifest(ir: any) -> dict {
    # The dependency manifest of a loaded AG-IR: every non-stdlib python
    # import in a tool body, every non-noise binary in a tool command,
    # each mapped to the tools that need it.
    py: dict = {};
    bins: dict = {};
    stdlib = _stdlib_names();
    tools = ir.get("tools") if isinstance(ir, dict) else None;
    if not isinstance(tools, dict) { return {"py": {}, "bin": {}}; }
    for kv in tools.items() {
        tname = str(kv[0]);
        t = kv[1];
        if not isinstance(t, dict) { continue; }
        body = str(t.get("body") or "");
        cmd = str(t.get("command") or "");
        if body.strip() and (not _looks_shell_body(body)) {
            for m in _body_imports(body) {
                if (m in stdlib) or (m in _PROVIDED) { continue; }
                ent: dict = py.get(m, {"pip": pip_name(m), "tools": []});
                if tname not in ent["tools"] { ent["tools"].append(tname); }
                py[m] = ent;
            }
        } elif body.strip() {
            for b in _command_bins(body) {
                cur: list = list(bins.get(b, []));
                if tname not in cur { cur.append(tname); }
                bins[b] = cur;
            }
        }
        if cmd.strip() {
            for b2 in _command_bins(cmd) {
                cur2: list = list(bins.get(b2, []));
                if tname not in cur2 { cur2.append(tname); }
                bins[b2] = cur2;
            }
        }
    }
    return {"py": py, "bin": bins, "proc_io": _proc_io_tools(tools)};
}

# Tool bodies that read PROCESS-level IO instead of their params. A skill's
# hook script lifted verbatim keeps its `json.load(sys.stdin)` / `sys.argv`
# input plumbing — under any harness that owns argv/stdin the tool opens the
# harness's flags as files or hangs on EOF (caught live: using-superpowers
# crashed all cells with FileNotFoundError('--arm'); xlsx died at node 1 on
# json.load of an EOF stdin). A compiled tool receives inputs via params only.
def _proc_io_tools(tools: dict) -> dict {
    import re;
    hits: dict = {};
    for kv in tools.items() {
        t = kv[1];
        if not isinstance(t, dict) { continue; }
        body = str(t.get("body") or "");
        if not body.strip() { continue; }
        m = re.search(r"sys\.argv|sys\.stdin|(?<![\w.])input\(\)", body);
        if m { hits[str(kv[0])] = str(m.group(0)); }
    }
    return hits;
}

def probe_manifest(manifest: dict) -> dict {
    # Install-time presence check, in THIS runtime — the same embedded python
    # that will execute the lowered tool bodies, so find_spec is ground truth
    # (probing a separate interpreter would be exactly the sys.executable trap).
    import importlib.util;
    missing_py: list = [];
    missing_bin: list = [];
    for kv in _dct(manifest.get("py")).items() {
        mod = str(kv[0]);
        ent = _dct(kv[1]);
        found = False;
        try { found = importlib.util.find_spec(mod) is not None; }
        except Exception { found = False; }
        if not found {
            missing_py.append([mod, str(ent.get("pip", mod)), list(ent.get("tools", []))]);
        }
    }
    for kv2 in manifest.get("bin", {}).items() {
        b = str(kv2[0]);
        if shutil.which(b) is None {
            missing_bin.append([b, list(kv2[1])]);
        }
    }
    return {"missing_py": missing_py, "missing_bin": missing_bin};
}

def manifest_empty(manifest: dict) -> bool {
    return (not manifest.get("py")) and (not manifest.get("bin"));
}

def preflight_src(manifest: dict) -> str {
    # The runtime half: `_ENV_MANIFEST` + `_env_preflight()` as a ::py:: block
    # for the lowered module. Re-probes on the EXECUTION host at run() entry
    # and BINDS what is missing into the artifact-local `.jac/pydeps` via the
    # closure's own pip (default on; SIGIL_ENV_AUTOBIND=0 opts out) — the
    # closure interpreter is the only one these imports resolve in, and pydeps
    # rejoins sys.path before every probe, so binds persist across runs.
    # Reports loud (stderr + AGIR_PROGRESS), never raises. "" when there is
    # nothing to bind.
    if manifest_empty(manifest) { return ""; }
    lite: dict = {"py": {}, "bin": []};
    for kv in manifest.get("py", {}).items() {
        lite["py"][str(kv[0])] = str(kv[1].get("pip", kv[0]));
    }
    for kv2 in manifest.get("bin", {}).items() {
        lite["bin"].append(str(kv2[0]));
    }
    lines: list = [
        "::py::",
        "_ENV_MANIFEST = " + json.dumps(lite),
        "def _env_preflight():",
        "    # Environment binding (SkillRT AOT pass 2): probe every dependency the",
        "    # compiled tools need BEFORE the walker runs. Imports resolve in the",
        "    # hermetic closure interpreter, so nothing installed from OUTSIDE the",
        "    # artifact can fix a missing module (#149) — remediate here instead:",
        "    # bind into ./.jac/pydeps beside this module (mutates the artifact,",
        "    # never the host). SIGIL_ENV_AUTOBIND=0 opts out. Never raises.",
        "    import importlib as _il, importlib.util as _ilu, shutil as _shu, os as _os, sys as _sys, json as _jsn",
        "    try:",
        "        _here = _os.path.dirname(_os.path.abspath(__file__))",
        "    except Exception:",
        "        _here = _os.getcwd()",
        "    _bind = _os.path.join(_here, \".jac\", \"pydeps\")",
        "    if _os.path.isdir(_bind) and _bind not in _sys.path:",
        "        _sys.path.insert(0, _bind)",
        "        _il.invalidate_caches()",
        "    miss_py, miss_bin = [], []",
        "    for _m, _p in _ENV_MANIFEST.get(\"py\", {}).items():",
        "        _ok = False",
        "        try:",
        "            _ok = _ilu.find_spec(_m) is not None",
        "        except Exception:",
        "            _ok = False",
        "        if not _ok:",
        "            miss_py.append((_m, _p))",
        "    for _b in _ENV_MANIFEST.get(\"bin\", []):",
        "        if _shu.which(_b) is None:",
        "            miss_bin.append(_b)",
        "    if miss_py and _os.environ.get(\"SIGIL_ENV_AUTOBIND\", \"\") != \"0\":",
        "        # bind with _sys.executable — under jac that IS the jac binary, and",
        "        # `jac -m pip` is the closure's own pip. `which python3` would install",
        "        # into an interpreter these imports never see (the #149 dead end).",
        "        import subprocess as _sp",
        "        _bound, _can = [], True",
        "        try:",
        "            _os.makedirs(_bind, exist_ok=True)",
        "        except Exception:",
        "            _can = False",
        "        if _can and _bind not in _sys.path:",
        "            _sys.path.insert(0, _bind)",
        "        for _m, _p in (list(miss_py) if _can else []):",
        "            try:",
        "                _r = _sp.run([_sys.executable, \"-m\", \"pip\", \"install\", \"--quiet\", \"--upgrade\", \"--target\", _bind, _p], timeout=600)",
        "                _il.invalidate_caches()",
        "                if _r.returncode == 0 and _ilu.find_spec(_m) is not None:",
        "                    miss_py.remove((_m, _p))",
        "                    _bound.append(_p)",
        "            except Exception:",
        "                _bind_failed = True",
        "        if _bound:",
        "            _sys.stderr.write(\"ENV_PREFLIGHT: bound %s into %s\\n\" % (\", \".join(_bound), _bind))",
        "    notes = [\"python module '%s' missing (probed %s; bind: %s -m pip install --target %s %s)\" % (_m, _sys.executable, _sys.executable, _bind, _p) for _m, _p in miss_py]",
        "    notes += [\"command '%s' not on PATH\" % _b for _b in miss_bin]",
        "    if notes:",
        "        _sys.stderr.write(\"ENV_PREFLIGHT: \" + \"; \".join(notes) + \"\\n\")",
        "        _pf = _os.environ.get(\"AGIR_PROGRESS\", \"\")",
        "        if _pf:",
        "            try:",
        "                with open(_pf, \"a\") as _f:",
        "                    _f.write(_jsn.dumps({\"node\": \"_env_preflight\", \"missing\": notes}) + \"\\n\")",
        "            except Exception:",
        "                _trace_failed = True",
        "    return notes",
        "::py::"
    ];
    return "\n".join(lines);
}
