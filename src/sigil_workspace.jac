"""Sandboxed workspace + the agent's general tool-belt.

This is the security boundary for chat-mode. Every file tool is *jailed* to a
single workspace directory (an escaping path is refused, not clamped); `ws_exec`
runs only through the exec-approval gate (`approvals.check_exec`) and, per the
Soul's `sandbox_mode`, either in a cwd-confined subprocess (`jail`) or a locked-down
Docker container (`docker`, `--network none --cap-drop ALL`); web tools carry an
SSRF guard that refuses loopback / private / link-local hosts.

These functions are the byLLM ReAct tools the chat agent (and its sub-agents) call.
Each carries a `sem` so the model knows when to reach for it. A live *trace sink*
lets the REPL render each tool call as it happens (set via `set_trace_sink`);
an *approver* callback lets the REPL resolve a pending exec approval inline.
"""

import os;
import re;
import json;
import shutil;
import subprocess;
import from urllib.request { Request, urlopen }
import from urllib.parse { urlparse, quote_plus }
import from .sigil { awaken, Soul }
import from .approvals { check_exec, allowlist_add }
import from .sigil_secrets { resolve_refs, redact_secrets }

# ---------------------------------------------------------------------------
# Live tool trace + inline approver (wired by the REPL; None = silent/scripted)
# ---------------------------------------------------------------------------
glob TRACE: list = [];        # [{tool, detail, ok}] — every tool call this process
glob _SINK: any = None;       # callback(tool, detail, ok) — live render hook
glob _APPROVER: any = None;   # callback(command)->bool — inline approve of a pending exec

def set_trace_sink(fn: any) -> None { global _SINK; _SINK = fn; }
def set_approver(fn: any) -> None { global _APPROVER; _APPROVER = fn; }
def drain_trace() -> list { global TRACE; out = list(TRACE); TRACE = []; return out; }

def _trace(tool: str, detail: str, ok: bool = True) -> None {
    global TRACE, _SINK;
    rec = {"tool": tool, "detail": detail[:200], "ok": ok};
    TRACE.append(rec);
    if _SINK is not None {
        try { _SINK(tool, detail, ok); } except Exception as e {}
    }
}

# ---------------------------------------------------------------------------
# Workspace jail
# ---------------------------------------------------------------------------
glob _WS_ROOT: str = "";

def ws_root() -> str {
    # The single directory every file tool is confined to. Read from the Soul
    # (config on the graph), default ~/.sigil/workspace, created on first use.
    global _WS_ROOT;
    soul = awaken();
    want = str(soul.workspace) if soul.workspace else os.path.expanduser("~/.sigil/workspace");
    want = os.path.abspath(os.path.expanduser(want));
    if want != _WS_ROOT {
        _WS_ROOT = want;
    }
    if not os.path.isdir(_WS_ROOT) {
        try { os.makedirs(_WS_ROOT, exist_ok=True); } except Exception as e {}
    }
    return _WS_ROOT;
}

def _jail(path: str) -> str {
    # Resolve `path` inside the workspace; raise ValueError if it escapes the jail.
    base = ws_root();
    p = path if os.path.isabs(path) else os.path.join(base, path);
    full = str(os.path.realpath(p));
    basereal = str(os.path.realpath(base));
    if full != basereal and not full.startswith(basereal + os.sep) {
        raise ValueError("path '" + path + "' escapes the workspace sandbox");
    }
    return full;
}

def _rel(full: str) -> str {
    try { return os.path.relpath(full, ws_root()); } except Exception as e { return full; }
}

# ---------------------------------------------------------------------------
# File tools
# ---------------------------------------------------------------------------
def ws_list(subdir: str = ".") -> str {
    try { target = _jail(subdir); } except Exception as e { _trace("list", str(e), False); return "error: " + str(e); }
    if not os.path.exists(target) { _trace("list", subdir + " (missing)", False); return "no such path: " + subdir; }
    if os.path.isfile(target) { _trace("list", _rel(target)); return _rel(target) + "  (" + str(os.path.getsize(target)) + " bytes)"; }
    rows: list = [];
    for name in sorted(os.listdir(target)) {
        full = os.path.join(target, name);
        tag = "/" if os.path.isdir(full) else ("  " + str(os.path.getsize(full)) + "b");
        rows.append("  " + name + tag);
    }
    _trace("list", _rel(target) + " (" + str(len(rows)) + " items)");
    return (_rel(target) + "/\n" + "\n".join(rows)) if rows else (_rel(target) + "/  (empty)");
}

def ws_read(path: str, offset: int = 0, limit: int = 0) -> str {
    # Read a file, optionally a line range: `offset` = 1-based start line (0 = from the
    # top), `limit` = max lines (0 = a default page of 400). Lines are numbered (cat -n
    # style) and a header states the slice's position in the file, so a large file can be
    # paged through (grep -> read around a line) and a partial read is never mistaken for
    # the whole file.
    try { full = _jail(path); } except Exception as e { _trace("read", str(e), False); return "error: " + str(e); }
    if not os.path.isfile(full) { _trace("read", path + " (missing)", False); return "no such file: " + path; }
    try {
        with open(full, "r") as f { data = f.read(); }
    } except Exception as e { _trace("read", str(e), False); return "error reading " + path + ": " + str(e); }
    lines = data.split(chr(10));
    total = len(lines);
    start = (offset - 1) if offset > 0 else 0;
    if start < 0 { start = 0; }
    if start >= total { start = max(0, total - 1); }
    page = limit if limit > 0 else 400;
    body: list = [];
    chars = 0;
    n = start;
    while n < total and len(body) < page {
        row = str(n + 1).rjust(6) + chr(9) + lines[n];
        chars += len(row) + 1;
        if chars > 20000 { break; }          # char safety per page
        body.append(row);
        n += 1;
    }
    shown_end = start + len(body);
    header = _rel(full) + "  (lines " + str(start + 1) + "-" + str(shown_end) + " of " + str(total) + ")";
    _trace("read", header);
    note = "";
    if shown_end < total {
        note = chr(10) + "… " + str(total - shown_end) + " more line(s) — continue with ws_read(\"" + path + "\", offset=" + str(shown_end + 1) + ")";
    }
    return header + chr(10) + chr(10).join(body) + note;
}

def ws_write(path: str, content: str) -> str {
    try { full = _jail(path); } except Exception as e { _trace("write", str(e), False); return "error: " + str(e); }
    try {
        os.makedirs(os.path.dirname(full), exist_ok=True);
        with open(full, "w") as f { f.write(resolve_refs(content)); }   # secret:<name> resolves at write-time only
    } except Exception as e { _trace("write", str(e), False); return "error writing " + path + ": " + str(e); }
    _trace("write", _rel(full) + " (" + str(len(content)) + " chars)");
    return "wrote " + _rel(full) + " (" + str(len(content)) + " chars)";
}

def ws_edit(path: str, old: str, new: str) -> str {
    try { full = _jail(path); } except Exception as e { _trace("edit", str(e), False); return "error: " + str(e); }
    if not os.path.isfile(full) { _trace("edit", path + " (missing)", False); return "no such file: " + path; }
    with open(full, "r") as f { data = f.read(); }
    n = data.count(old);
    if n == 0 { _trace("edit", path + " (no match)", False); return "no occurrence of the target text in " + path; }
    if n > 1 { _trace("edit", path + " (" + str(n) + " matches)", False); return "target text is not unique in " + path + " (" + str(n) + " matches) — include more context"; }
    with open(full, "w") as f { f.write(data.replace(old, resolve_refs(new))); }
    _trace("edit", _rel(full));
    return "edited " + _rel(full);
}

# ---------------------------------------------------------------------------
# Survey tools — read-only, jailed, NO approval (unlike ws_exec). These let the
# agent understand a codebase before diving in: ws_tree for structure, ws_grep to
# locate. Noise dirs are pruned so a repo with node_modules/.git stays readable.
# ---------------------------------------------------------------------------
glob _SKIP_DIRS: list = [".git", "node_modules", "__pycache__", ".jac", ".venv", "venv",
                         "dist", "build", ".mypy_cache", ".pytest_cache", ".idea",
                         ".next", "target", ".gradle", "vendor"];

def ws_tree(subdir: str = ".", depth: int = 3) -> str {
    # Recursive directory survey (structure only). Skips noise dirs, bounds depth and
    # entry count — for getting the shape of a repo before reading files.
    try { base = _jail(subdir); } except Exception as e { _trace("tree", str(e), False); return "error: " + str(e); }
    if not os.path.isdir(base) { _trace("tree", subdir + " (not a dir)", False); return "not a directory: " + subdir; }
    d = depth if depth > 0 else 3;
    cap = 500;
    rows: list = [];
    stopped = False;
    for (dirpath, dirnames, filenames) in os.walk(base) {
        rel = os.path.relpath(str(dirpath), base);
        level = 0 if rel == "." else len(rel.split(os.sep));
        # prune noise + hidden dirs, and don't descend past the depth limit
        dirnames[:] = sorted([x for x in dirnames if (x not in _SKIP_DIRS) and not str(x).startswith(".")]) if level < d else [];
        indent = "  " * level;
        label = _rel(base) if rel == "." else str(rel).split(os.sep)[-1];
        rows.append(indent + label + "/");
        for fn in sorted(filenames) {
            if str(fn).startswith(".") { continue; }
            rows.append(indent + "  " + str(fn));
            if len(rows) >= cap { stopped = True; break; }
        }
        if stopped { break; }
    }
    _trace("tree", _rel(base) + " (" + str(len(rows)) + " entries, depth " + str(d) + ")");
    out = "\n".join(rows);
    if stopped { out += "\n… (truncated at " + str(cap) + " entries — narrow with a subdir or smaller depth)"; }
    return out;
}

def _is_texty(path: str) -> bool {
    # cheap binary sniff: reject files with a NUL byte in the first 1KB
    try {
        with open(path, "rb") as f { head = f.read(1024); }
        return b"\x00" not in head;
    } except Exception as e { return False; }
}

def ws_grep(pattern: str, path: str = ".") -> str {
    # Search file contents for a regex (read-only). `path` may be a file or a directory
    # (searched recursively, noise dirs pruned). Returns relpath:line: text, capped.
    try { base = _jail(path); } except Exception as e { _trace("grep", str(e), False); return "error: " + str(e); }
    if not os.path.exists(base) { _trace("grep", path + " (missing)", False); return "no such path: " + path; }
    try { rx = re.compile(pattern); } except Exception as e { _trace("grep", "bad regex", False); return "bad regex: " + str(e)[:120]; }
    targets: list = [];
    if os.path.isfile(base) { targets = [base]; }
    else {
        for (dirpath, dirnames, filenames) in os.walk(base) {
            dirnames[:] = [x for x in dirnames if (x not in _SKIP_DIRS) and not str(x).startswith(".")];
            for fn in sorted(filenames) {
                if not str(fn).startswith(".") { targets.append(os.path.join(str(dirpath), str(fn))); }
            }
            if len(targets) > 4000 { break; }
        }
    }
    hits: list = [];
    max_hits = 100;
    for fp in targets {
        fpath = str(fp);
        if len(hits) >= max_hits { break; }
        if not _is_texty(fpath) { continue; }
        try {
            with open(fpath, "r") as f { flines = f.read().split(chr(10)); }
        } except Exception as e { continue; }
        i = 0;
        for ln in flines {
            i += 1;
            if rx.search(ln) {
                hits.append(_rel(fpath) + ":" + str(i) + ": " + ln.strip()[:200]);
                if len(hits) >= max_hits { break; }
            }
        }
    }
    _trace("grep", pattern + " (" + str(len(hits)) + " hits)");
    if not hits { return "no matches for /" + pattern + "/ under " + _rel(base); }
    out = "\n".join(hits);
    if len(hits) >= max_hits { out += "\n… (stopped at " + str(max_hits) + " matches — refine the pattern or scope to a subdir)"; }
    return out;
}

# ---------------------------------------------------------------------------
# Shell exec — approval-gated + sandboxed by Soul.sandbox_mode
# ---------------------------------------------------------------------------
def _docker_available() -> bool {
    return shutil.which("docker") is not None;
}

def _run_jail(command: str, timeout: int) -> dict {
    # cwd-confined subprocess on the host (secrets resolved into argv, then redacted from output)
    try {
        p = subprocess.run(resolve_refs(command), shell=True, cwd=ws_root(), capture_output=True,
                           text=True, timeout=timeout);
        out = (str(p.stdout) + (("\n[stderr] " + str(p.stderr)) if p.stderr else ""));
        return {"code": p.returncode, "out": out};
    } except subprocess.TimeoutExpired as e { return {"code": 124, "out": "timed out after " + str(timeout) + "s"}; }
    except Exception as e { return {"code": 1, "out": str(e)}; }
}

def _run_docker(command: str, timeout: int) -> dict {
    if not _docker_available() { return {"code": 127, "out": "docker not available; set sandbox_mode=jail or install docker"}; }
    img = os.getenv("SIGIL_SANDBOX_IMAGE", "python:3.13-slim");
    argv = ["docker", "run", "--rm", "--network", "none", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "1g",
            "-v", ws_root() + ":/work", "-w", "/work", img, "sh", "-c", resolve_refs(command)];
    try {
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout);
        out = (str(p.stdout) + (("\n[stderr] " + str(p.stderr)) if p.stderr else ""));
        return {"code": p.returncode, "out": out};
    } except subprocess.TimeoutExpired as e { return {"code": 124, "out": "timed out after " + str(timeout) + "s"}; }
    except Exception as e { return {"code": 1, "out": str(e)}; }
}

def ws_exec(command: str) -> str {
    soul = awaken();
    mode = str(soul.sandbox_mode) if soul.sandbox_mode else "jail";
    if mode == "off" { _trace("exec", command + " (disabled)", False); return "exec is disabled (sandbox_mode=off)"; }
    # exec-approval gate — the same policy the whole agent shares
    gate = check_exec(command);
    dec = str(gate["decision"]);
    if dec == "approval-pending" {
        approved = False;
        if _APPROVER is not None {
            try { approved = bool(_APPROVER(command)); } except Exception as e { approved = False; }
        }
        if approved { allowlist_add(command.strip().split(" ")[0]); }
        else { _trace("exec", command + " (needs approval)", False); return "BLOCKED: '" + command + "' needs operator approval (exec policy). Ask the operator to approve, or run it manually."; }
    } elif dec == "deny" {
        _trace("exec", command + " (denied)", False);
        return "DENIED by exec policy: " + str(gate["reason"]);
    }
    _trace("exec", command + "  [" + mode + "]");
    res = _run_docker(command, 120) if mode == "docker" else _run_jail(command, 120);
    body = redact_secrets(str(res["out"]))[:8000];
    return "exit=" + str(res["code"]) + "\n" + (body if body else "(no output)");
}

# ---------------------------------------------------------------------------
# Web tools — SSRF-guarded fetch + keyless search
# ---------------------------------------------------------------------------
def _ssrf_ok(url: str) -> bool {
    try { u = urlparse(url); } except Exception as e { return False; }
    if u.scheme not in ["http", "https"] { return False; }
    host = (u.hostname or "").lower();
    if host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "metadata.google.internal"] { return False; }
    bad_prefixes = ["10.", "192.168.", "169.254.", "127.", "0."];
    for p in bad_prefixes { if host.startswith(p) { return False; } }
    if host.startswith("172.") {
        parts = host.split(".");
        if len(parts) > 1 and parts[1].isdigit() and 16 <= int(parts[1]) <= 31 { return False; }
    }
    return True;
}

def _strip_html(html: str) -> str {
    txt = re.sub(r"(?is)<script.*?</script>|<style.*?</style>", " ", html);
    txt = re.sub(r"(?s)<[^>]+>", " ", txt);
    txt = re.sub(r"&nbsp;|&amp;|&lt;|&gt;|&#39;|&quot;", " ", txt);
    return re.sub(r"[ \t\r\f]+", " ", re.sub(r"\n\s*\n\s*\n+", "\n\n", txt)).strip();
}

def web_fetch(url: str) -> str {
    if not _ssrf_ok(url) { _trace("web_fetch", url + " (blocked)", False); return "refused: '" + url + "' is not a permitted (public http/https) URL"; }
    try {
        req = Request(url, headers={"User-Agent": "sigil/0.1 (+https://sigil.dev)"});
        resp = urlopen(req, timeout=20);
        raw = resp.read();
        resp.close();
        text = _strip_html(str(raw.decode("utf-8", "replace")));
    } except Exception as e { _trace("web_fetch", url + " err", False); return "fetch error: " + str(e)[:200]; }
    _trace("web_fetch", url + " (" + str(len(text)) + " chars)");
    return text if len(text) <= 12000 else (text[:12000] + "\n… [truncated]");
}

# Web search goes through a real provider API (keyless engines now serve bot
# challenges, not results — same reason OpenClaw uses Brave/Firecrawl/LLM-native
# search, never scraping). Keys come from the environment (document them with
# `secret add` if you like). Brave is tried first, then Firecrawl.
def _fmt_results(items: list) -> str {
    out: list = [];
    i = 0;
    for it in items[:6] {
        d = dict(it);
        out.append(str(i + 1) + ". " + str(d.get("title", "")) + "\n   " + str(d.get("url", "")) + "\n   " + str(d.get("desc", ""))[:220]);
        i += 1;
    }
    return "\n".join(out);
}

def _search_brave(query: str, key: str) -> list {
    url = "https://api.search.brave.com/res/v1/web/search?count=6&q=" + quote_plus(query);
    req = Request(url, headers={"X-Subscription-Token": key, "Accept": "application/json", "User-Agent": "sigil/0.1"});
    resp = urlopen(req, timeout=20);
    body = json.loads(str(resp.read().decode("utf-8", "replace")));
    resp.close();
    results = ((dict(body).get("web") or {}).get("results")) or [];
    return [{"title": str(r.get("title", "")), "url": str(r.get("url", "")), "desc": str(r.get("description", ""))} for r in results];
}

def _search_firecrawl(query: str, key: str) -> list {
    data = json.dumps({"query": query, "limit": 6}).encode("utf-8");
    req = Request("https://api.firecrawl.dev/v1/search", data=data,
                  headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "User-Agent": "sigil/0.1"});
    resp = urlopen(req, timeout=25);
    body = json.loads(str(resp.read().decode("utf-8", "replace")));
    resp.close();
    results = dict(body).get("data") or [];
    return [{"title": str(r.get("title", "")), "url": str(r.get("url", "")), "desc": str(r.get("description", ""))} for r in results];
}

def web_search(query: str) -> str {
    brave = os.getenv("BRAVE_API_KEY") or os.getenv("BRAVE_SEARCH_API_KEY");
    fire = os.getenv("FIRECRAWL_API_KEY");
    if brave {
        try {
            items = _search_brave(query, str(brave));
            _trace("web_search", query + " (brave, " + str(len(items)) + ")");
            return _fmt_results(items) if items else "no results for: " + query;
        } except Exception as e { _trace("web_search", "brave err", False); }
    }
    if fire {
        try {
            items = _search_firecrawl(query, str(fire));
            _trace("web_search", query + " (firecrawl, " + str(len(items)) + ")");
            return _fmt_results(items) if items else "no results for: " + query;
        } except Exception as e { _trace("web_search", "firecrawl err", False); }
    }
    _trace("web_search", query + " (no provider key)", False);
    return ("web_search needs a search-provider API key — keyless engines now block automated queries.\n"
            "Set one of:\n"
            "  • Brave      export BRAVE_API_KEY=…       (free tier: https://brave.com/search/api/)\n"
            "  • Firecrawl  export FIRECRAWL_API_KEY=…   (https://firecrawl.dev)\n"
            "Without a key I can still fetch a specific URL with web_fetch — including keyless JSON APIs, "
            "e.g. GitHub: web_fetch('https://api.github.com/repos/<org>/<repo>/pulls').");
}

def workspace_info() -> dict {
    soul = awaken();
    base = ws_root();
    n = 0;
    try { n = len(list(os.listdir(base))); } except Exception as e {}
    return {"root": base, "sandbox_mode": (str(soul.sandbox_mode) if soul.sandbox_mode else "jail"),
            "docker": _docker_available(), "items": n};
}
