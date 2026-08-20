"""The common tool library — the standard embodiments every skill can bind.

A code-owned node has to lower through a tool, and a tool has to carry a body. So
until now the frontier had to hand-write Python for every mundane step: read this
file, grep that directory, run that script. When it didn't, the node lowered to a
marker comment and the assemble gate killed the compile — which is exactly how
`n4_read_primer`, `npm_install` and `potx_handling` died. The work was never hard,
it was just never offered.

These are the operations a skill written for any agent runtime already assumes it
has: Anthropic's own skills declare `allowed-tools: Bash Read Grep Glob`. Naming
them the same way means a lift maps onto them without translation — the author
binds `read_file` by name and gets a body for free.

INLINED, NOT IMPORTED. Each body is self-contained stdlib Python, spliced into the
generated module at lower time exactly like `osp_runtime.py.txt`. That is not a
style choice:

  - a compiled skill runs in a subprocess with cwd=workdir, where Sigil is NOT
    importable — `import sigil_mcp` in the live-tool path has always raised
    ModuleNotFoundError and been swallowed, which is why registered MCP tools
    have never actually dispatched from a compiled skill;
  - `compile -e` ejects a standalone program that must run with no repo at all.

A library that had to be imported at run time would reproduce the first bug and
break the second. So the library is a library at COMPILE time only.

No new blast radius: a generated module already runs arbitrary model-authored
Python, so `run_command` grants nothing `import subprocess` did not.
"""

# Each entry: sig (canonical — used INSTEAD of the author's, so the body's
# parameter names always match), surface, doc, and a self-contained body.
glob BUILTINS: dict = {
    "read_file": {
        "sig": "(path: str) -> str",
        "surface": "SENSE",
        "doc": "Read a text file and return its contents.",
        "body": """
import os
p = os.path.expanduser(str(path or ""))
if not p:
    return "[read_file: no path given]"
if not os.path.isfile(p):
    return "[read_file: no such file: %s]" % p
try:
    with open(p, "r", errors="replace") as _f:
        _data = _f.read()
except Exception as _e:
    return "[read_file failed: %s]" % str(_e)[:200]
return _data if len(_data) <= 200000 else (_data[:200000] + "\\n... [truncated]")
"""
    },
    "list_dir": {
        "sig": "(path: str) -> str",
        "surface": "SENSE",
        "doc": "List one directory level (names, with a / suffix on directories).",
        "body": """
import os
p = os.path.expanduser(str(path or "."))
if not os.path.isdir(p):
    return "[list_dir: not a directory: %s]" % p
try:
    _names = sorted(os.listdir(p))
except Exception as _e:
    return "[list_dir failed: %s]" % str(_e)[:200]
_rows = []
for _n in _names:
    _rows.append(_n + ("/" if os.path.isdir(os.path.join(p, _n)) else ""))
return "\\n".join(_rows) if _rows else "(empty)"
"""
    },
    "glob_files": {
        "sig": "(pattern: str, path: str) -> str",
        "surface": "SENSE",
        "doc": "Find files matching a glob pattern, recursively, under `path`.",
        "body": """
import os, glob as _g
_root = os.path.expanduser(str(path or "."))
_pat = str(pattern or "*")
try:
    _hits = _g.glob(os.path.join(_root, "**", _pat), recursive=True)
except Exception as _e:
    return "[glob_files failed: %s]" % str(_e)[:200]
_hits = [h for h in sorted(_hits) if os.path.isfile(h)][:500]
return "\\n".join(_hits) if _hits else "no files match %s under %s" % (_pat, _root)
"""
    },
    "grep": {
        "sig": "(pattern: str, path: str) -> str",
        "surface": "SENSE",
        "doc": "Regex-search file contents under `path`; returns `file:line: text`.",
        "body": """
import os, re as _re
_root = os.path.expanduser(str(path or "."))
try:
    _rx = _re.compile(str(pattern or ""))
except Exception as _e:
    return "[grep: bad regex: %s]" % str(_e)[:120]
_skip = {".git", "node_modules", "__pycache__", ".venv", "venv", "dist", "build", ".jac"}
_targets = []
if os.path.isfile(_root):
    _targets = [_root]
else:
    for (_dp, _dn, _fn) in os.walk(_root):
        _dn[:] = [d for d in _dn if d not in _skip and not d.startswith(".")]
        for _f in sorted(_fn):
            if not _f.startswith("."):
                _targets.append(os.path.join(_dp, _f))
        if len(_targets) > 4000:
            break
_hits = []
for _t in _targets:
    if len(_hits) >= 200:
        break
    try:
        with open(_t, "rb") as _fh:
            if b"\\x00" in _fh.read(1024):
                continue
        with open(_t, "r", errors="replace") as _fh:
            for _i, _ln in enumerate(_fh, 1):
                if _rx.search(_ln):
                    _hits.append("%s:%d: %s" % (_t, _i, _ln.strip()[:200]))
                    if len(_hits) >= 200:
                        break
    except Exception:
        continue
return "\\n".join(_hits) if _hits else "no matches for /%s/ under %s" % (pattern, _root)
"""
    },
    "write_file": {
        "sig": "(path: str, content: str) -> str",
        "surface": "ACT.artifact",
        "doc": "Write text to a file, creating parent directories. Returns the path.",
        "body": """
import os
p = os.path.expanduser(str(path or ""))
if not p:
    return "[write_file: no path given]"
try:
    _d = os.path.dirname(os.path.abspath(p))
    if _d:
        os.makedirs(_d, exist_ok=True)
    with open(p, "w") as _f:
        _f.write(str(content or ""))
except Exception as _e:
    return "[write_file failed: %s]" % str(_e)[:200]
return p
"""
    },
    "run_command": {
        "sig": "(command: str) -> str",
        "surface": "ACT.artifact",
        "doc": "Run a shell command and return exit code + combined output.",
        "body": """
import subprocess as _sp
import shutil as _shutil
_cmd = str(command or "").strip()
if not _cmd:
    return "[run_command: no command given]"
try:
    # /bin/sh is dash on Debian; a bash-drafted command dies at the first "(".
    # `import shutil` above is load-bearing: a tool body is emitted as a
    # self-contained function body, so a name it does not import is a NameError
    # the surrounding `try` swallows into "[run_command failed: ...]" -- every
    # call, silently, with nothing run.
    _sh = _shutil.which("bash") or "/bin/sh"
    _p = _sp.run(_cmd, shell=True, capture_output=True, text=True, executable=_sh)
except Exception as _e:
    return "[run_command failed: %s]" % str(_e)[:200]
_out = (_p.stdout or "") + (("\\n[stderr] " + _p.stderr) if _p.stderr else "")
if len(_out) > 100000:
    _out = _out[:100000] + "\\n... [truncated]"
return "exit=%d\\n%s" % (_p.returncode, _out if _out.strip() else "(no output)")
"""
    },
    "http_get": {
        "sig": "(url: str) -> str",
        "surface": "SENSE",
        "doc": "Fetch a public http(s) URL and return the response body as text.",
        "body": """
import urllib.request as _u
_url = str(url or "").strip()
if not (_url.startswith("http://") or _url.startswith("https://")):
    return "[http_get: not an http(s) url: %s]" % _url[:120]
try:
    _rq = _u.Request(_url, headers={"User-Agent": "sigil-skill/1.0"})
    with _u.urlopen(_rq, timeout=30) as _r:
        _body = _r.read().decode("utf-8", "replace")
except Exception as _e:
    return "[http_get failed: %s]" % str(_e)[:200]
return _body if len(_body) <= 200000 else (_body[:200000] + "\\n... [truncated]")
"""
    }
};


def builtin_names() -> list {
    return sorted(list(BUILTINS));
}


def builtin(name: any) -> any {
    # The definition for `name`, or None. Matched on the exact name, the same way
    # the contract already tells the author to bind a registered MCP tool.
    return BUILTINS.get(str(name or ""));
}


def builtin_catalogue() -> str {
    # The author-facing listing. Without this the frontier has no idea these
    # exist and hand-writes a body for every mundane step — or leaves the node
    # unserved, which is a failed compile.
    rows: list = [
        "STANDARD TOOLS (always available — bind one by using its EXACT name as a",
        "tool name, with `serves:` naming the nodes it lowers; omit `body`/`command`",
        "and the compiler supplies the implementation):"
    ];
    for n in builtin_names() {
        b = dict(BUILTINS[str(n)]);
        args = str(b["sig"]).split("->")[0].strip();
        rows.append("- " + str(n) + args + "  [" + str(b["surface"]) + "]  " + str(b["doc"]));
    }
    return "\n".join(rows);
}
