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
return _data if len(_data) <= 20000000 else (_data[:20000000] + "\\n... [truncated]")
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
        "doc": "Write text to a file, creating parent directories. Returns the path. A path whose extension declares a structured format is only written when the content IS that format.",
        "body": """
import os, json as _json
p = os.path.expanduser(str(path or ""))
if not p:
    return "[write_file: no path given]"
_text = str(content or "")
# SIGIL_WRITE_GUARDS=0 (or false/no/off) writes verbatim: the escape hatch for a
# task the guards below are wrong about. On by default.
if str(os.environ.get("SIGIL_WRITE_GUARDS", "")).strip().lower() in ("0", "false", "no", "off"):
    try:
        _d = os.path.dirname(os.path.abspath(p))
        if _d:
            os.makedirs(_d, exist_ok=True)
        with open(p, "w") as _f:
            _f.write(_text)
    except Exception as _e:
        return "[write_file failed: %s]" % str(_e)[:200]
    return p
# NEVER overwrite a file the run was handed as INPUT (the registry the runtime keeps in
# _INPUT_PATHS): xlsx's repair step wrote its Python script INTO the caller's workbook
# (/root/data/openipf.xlsx) and the verifier found a corrupt zip (powerlifting 0/11, both
# runtimes). `globals()` is how a self-contained body reaches the module registry.
_reg = globals().get("_INPUT_PATHS") or set()
try:
    if p and (os.path.abspath(p) in _reg or os.path.basename(p) in _reg):
        _alt0 = p + ".out"
        with open(_alt0, "w") as _f0:
            _f0.write(_text)
        return "[write_file refused: %s is an INPUT of this run - wrote %s instead]" % (p, _alt0)
except Exception:
    pass
# a BINARY document format never accepts text content (a script, a report, JSON): the
# file would be corrupt whatever the text says. Park the text beside it and say so.
_bin_ext = (".xlsx", ".xlsm", ".xls", ".docx", ".pptx", ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".zip", ".parquet", ".h5", ".npz", ".sqlite", ".db", ".civ6map")
if os.path.splitext(p)[1].lower() in _bin_ext and _text.strip():
    _alt1 = p + ".txt"
    try:
        _d1 = os.path.dirname(os.path.abspath(_alt1))
        if _d1:
            os.makedirs(_d1, exist_ok=True)
        with open(_alt1, "w") as _f1:
            _f1.write(_text)
    except Exception as _e1:
        _alt1 = ""
    return ("[write_file refused: %s is a binary document format and this content is text (a script/report cannot be a valid %s); "
            "saved the text as %s instead. Produce the real file with the proper library.]" % (p, os.path.splitext(p)[1], _alt1 or "(not written)"))
if not _text.strip():
    # empty content never creates or overwrites a deliverable (a 0-byte answer.json
    # reads as "present" to the caller and hides that nothing was produced)
    return "[write_file skipped: nothing to write for %s (empty content); the file was not created or changed]" % p
# A deliverable path names a FORMAT, not just a location. The output-name
# fallback reads the filename out of the task, so a skill that produces a
# Markdown report will happily write it to the report.json the task asked
# for -- and the caller cannot tell a corrupt deliverable from a correct
# one (caught live: energy-ac wrote "# Network Data Report" into
# report.json; all 24 checks died on JSONDecodeError at char 0, and the
# agent, which had the analysis and could have written real JSON, found
# the file already there). Refuse the write and say so: an absent
# deliverable is recoverable, a corrupt one is not.
_ext = os.path.splitext(p)[1].lower()
if _ext == ".json" and _text.strip():
    _ok = False
    try:
        _json.loads(_text)
        _ok = True
    except Exception:
        pass
    if not _ok:
        # not JSON: recover ONE wrapped document (a code fence, or prose around
        # {...}) -- a str slot asked for a JSON deliverable does this constantly
        # (3d-scan, azure-bgp, civ6, both runtimes). Never invents content.
        import re as _re
        _t = _text.strip()
        _cands = []
        if _t.startswith("```"):
            _ls = _t.splitlines()[1:]
            if _ls and _ls[-1].strip().startswith("```"):
                _ls = _ls[:-1]
            _cands.append("\\n".join(_ls))
        _m = _re.search(r"```(?:json)?\\s*([\\[{].*?[\\]}])\\s*```", _t, _re.S)
        if _m:
            _cands.append(_m.group(1))
        # outermost document first: whichever bracket opens earlier in the text
        _pairs = [("{", "}"), ("[", "]")]
        if _t.find("[") >= 0 and (_t.find("{") < 0 or _t.find("[") < _t.find("{")):
            _pairs.reverse()
        for _o, _c in _pairs:
            _i = _t.find(_o)
            _k = _t.rfind(_c)
            if _i >= 0 and _k > _i:
                _cands.append(_t[_i:_k + 1])
        for _cnd in _cands:
            try:
                _text = _json.dumps(_json.loads(_cnd), indent=2, ensure_ascii=False)
                _ok = True
                break
            except Exception:
                continue
    if not _ok:
        # refuse: park the text in a .md sibling and say so (an absent deliverable
        # is recoverable by the caller; a corrupt one is not)
        _alt = os.path.splitext(p)[0] + ".md"
        try:
            _d2 = os.path.dirname(os.path.abspath(_alt))
            if _d2:
                os.makedirs(_d2, exist_ok=True)
            with open(_alt, "w") as _f2:
                _f2.write(_text)
        except Exception as _e2:
            _alt = ""
        if _alt:
            return ("[write_file refused: %s must contain JSON but this content is not JSON, so it was saved "
                    "as %s instead. If the task needs JSON at %s, produce it yourself from that file.]" % (p, _alt, p))
        return ("[write_file refused: %s must contain JSON but this content is not JSON, and the fallback file "
                "could not be written either (check the directory). Produce the JSON at %s yourself.]" % (p, p))
if _ext == ".csv" and _text.strip():
    # the CSV twin of the JSON guard: a .csv deliverable written with a Markdown
    # report (gravitational-wave: "Missing required columns. Found: ['# Matched
    # Filter Report']"). Rows pass; a fenced ```csv block inside prose is recovered;
    # prose/report text is parked in a .md sibling and the caller is told.
    import re as _re2
    _ls = [_l for _l in _text.strip().splitlines() if _l.strip()]
    _h = _ls[0].lstrip() if _ls else ""
    _ok = bool(_ls) and (not _h.startswith("#")) and (not _h.startswith("```")) and (("," in _h) or ("\\t" in _h) or (";" in _h) or ("|" in _h))
    if not _ok:
        _m2 = _re2.search(r"```(?:csv)?\\s*\\n(.*?)```", _text, _re2.S)
        if _m2:
            _b = _m2.group(1)
            _ls2 = [_l2 for _l2 in _b.strip().splitlines() if _l2.strip()]
            _h2 = _ls2[0].lstrip() if _ls2 else ""
            if _ls2 and (not _h2.startswith("#")) and (("," in _h2) or ("\\t" in _h2) or (";" in _h2) or ("|" in _h2)):
                _text = _b.strip() + "\\n"
                _ok = True
    if not _ok:
        _alt = os.path.splitext(p)[0] + ".md"
        try:
            _d3 = os.path.dirname(os.path.abspath(_alt))
            if _d3:
                os.makedirs(_d3, exist_ok=True)
            with open(_alt, "w") as _f3:
                _f3.write(_text)
        except Exception as _e3:
            _alt = ""
        if _alt:
            return ("[write_file refused: %s must contain CSV rows but this content is a report/prose, so it was saved "
                    "as %s instead. If the task needs CSV at %s, produce the rows yourself from that file.]" % (p, _alt, p))
        return "[write_file refused: %s must contain CSV rows but this content is a report/prose; produce the CSV at %s yourself.]" % (p, p)
try:
    _d = os.path.dirname(os.path.abspath(p))
    if _d:
        os.makedirs(_d, exist_ok=True)
    with open(p, "w") as _f:
        _f.write(_text)
    try:
        _wp = globals().get("_WRITTEN_PATHS")
        if _wp is not None:
            _wp.add(os.path.abspath(p))
            _wp.add(os.path.basename(p))
    except Exception:
        pass
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
return _body if len(_body) <= 20000000 else (_body[:20000000] + "\\n... [truncated]")
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
