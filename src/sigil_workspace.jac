"""The agent's workspace and its general tool-belt.

By default the tools work on the REAL filesystem, with the operator's own reach:
file tools resolve relative paths against the workspace directory but accept any
absolute path, and `ws_exec` runs unconfined in a normal subprocess. That default
is deliberate — Sigil's job here is to drive the tools and agents already installed
on this machine (`claude`, a build, a test suite), and containment would cut it off
from exactly those.

Containment is a switch, not a fact: `configure sandbox <off|jail|docker>` (default
`off`). `jail` puts the file tools back inside the workspace and starts shell jobs
there; `docker` additionally runs each command in a locked-down container. What
holds in every mode is the exec-approval policy (`approvals.check_exec`) in front of
every shell command and an SSRF guard that refuses loopback / private / link-local
hosts on the web tools.

Nothing is killed on a timer. `ws_exec` starts a background job and returns the
output so far after a soft wait; the model then decides whether to keep watching
(`ws_watch`), leave it running, or stop it (`ws_kill`). And `sigil compile` is not
a shell command at all — it is `sigil_compile`, run in this process against this
agent's graph.

These functions are the byLLM ReAct tools the chat agent (and its sub-agents) call.
Each carries a `sem` so the model knows when to reach for it. A live *trace sink*
lets the REPL render each tool call as it happens (set via `set_trace_sink`);
an *approver* callback lets the REPL resolve a pending exec approval inline.
"""

import os;
import re;
import json;
import time;
import tempfile;
import subprocess;
import from urllib.request { Request, urlopen }
import from urllib.parse { urlparse, quote_plus }
import from .sigil { awaken, Soul, compile_skill }
import from .approvals { check_exec, allowlist_add }
import from .sigil_secrets { resolve_refs, redact_secrets }

# ---------------------------------------------------------------------------
# Live tool trace + inline approver (wired by the REPL; None = silent/scripted)
# ---------------------------------------------------------------------------
glob TRACE: list = [];        # [{tool, detail, ok}] — every tool call this process
glob _SINK: any = None;       # callback(tool, detail, ok) — live render hook
glob _APPROVER: any = None;   # callback(command)->bool — inline approve of a pending exec

def set_trace_sink(fn: any) -> None { _SINK = fn; }
def set_approver(fn: any) -> None { _APPROVER = fn; }
def drain_trace() -> list { out = list(TRACE); TRACE = []; return out; }

def _trace(tool: str, detail: str, ok: bool = True) -> None {
    rec = {"tool": tool, "detail": detail[:200], "ok": ok};
    TRACE.append(rec);
    if _SINK is not None {
        try { _SINK(tool, detail, ok); } except Exception as e {}
    }
}

# ---------------------------------------------------------------------------
# Workspace — the default working directory, NOT a jail
# ---------------------------------------------------------------------------
glob _WS_ROOT: str = "";

def ws_root() -> str {
    # Where relative paths resolve and where shell jobs start. Read from the Soul
    # (config on the graph), default ~/.sigil/workspace, created on first use. An
    # absolute path hands the tools anywhere on the host, on purpose.
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

def sandbox_mode() -> str {
    # off (default) | jail | docker — see `configure sandbox`.
    soul = awaken();
    return str(soul.sandbox) if soul.sandbox else "off";
}

def _resolve(path: str) -> str {
    # Absolute (or ~-rooted) paths as given; relative ones against the workspace.
    # With the sandbox OFF (the default) that is the whole story — the agent reads
    # and writes the same filesystem the operator does, so it can work on real
    # projects alongside other agents. Turn the sandbox on and the workspace becomes
    # a jail again: an escaping path is refused, not clamped.
    p = os.path.expanduser(path);
    if not os.path.isabs(p) { p = os.path.join(ws_root(), p); }
    full = str(os.path.realpath(p));
    if sandbox_mode() != "off" {
        basereal = str(os.path.realpath(ws_root()));
        if (full != basereal) and (not full.startswith(basereal + os.sep)) {
            raise ValueError("path '" + path + "' escapes the workspace sandbox");
        }
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
    try { target = _resolve(subdir); } except Exception as e { _trace("list", str(e), False); return "error: " + str(e); }
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
    try { full = _resolve(path); } except Exception as e { _trace("read", str(e), False); return "error: " + str(e); }
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
    try { full = _resolve(path); } except Exception as e { _trace("write", str(e), False); return "error: " + str(e); }
    try {
        os.makedirs(os.path.dirname(full), exist_ok=True);
        with open(full, "w") as f { f.write(resolve_refs(content)); }   # secret:<name> resolves at write-time only
    } except Exception as e { _trace("write", str(e), False); return "error writing " + path + ": " + str(e); }
    _trace("write", _rel(full) + " (" + str(len(content)) + " chars)");
    return "wrote " + _rel(full) + " (" + str(len(content)) + " chars)";
}

def ws_edit(path: str, old: str, new: str) -> str {
    try { full = _resolve(path); } except Exception as e { _trace("edit", str(e), False); return "error: " + str(e); }
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
    try { base = _resolve(subdir); } except Exception as e { _trace("tree", str(e), False); return "error: " + str(e); }
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
    try { base = _resolve(path); } except Exception as e { _trace("grep", str(e), False); return "error: " + str(e); }
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
# Shell exec — approval-gated, unconfined, and NEVER killed on a timer.
#
# A deadline is the wrong instrument here: a build, a test suite or another agent
# CLI routinely outlives any number you would pick, and killing it throws the work
# away exactly when it was about to pay off. So every command runs as a background
# job spooling to a file, and `ws_exec` only *waits* — up to a soft window — before
# handing back the output so far. If the job is still alive the model gets a job id
# and decides what a person would: keep watching (`ws_watch`), go do something else
# and come back, or stop it (`ws_kill`). The process itself is never interrupted.
# ---------------------------------------------------------------------------
obj ShellJob {
    has id: str;
    has proc: any;          # subprocess.Popen — still running until IT decides otherwise
    has spool: str;         # file the command's merged stdout/stderr streams into
    has cmd: str;
    has started: float;
    has read: int = 0;      # how much of the spool has already been reported
}

glob _JOBS: dict[str, ShellJob] = {};
glob _JOB_N: int = 0;

def _docker_available() -> bool {
    import shutil;
    return shutil.which("docker") is not None;
}

def _docker_argv(command: str) -> list {
    # sandbox=docker: the command runs in a locked-down container with only the
    # workspace mounted. Still no timeout — a container is a boundary, not a clock.
    img = os.getenv("SIGIL_SANDBOX_IMAGE", "python:3.13-slim");
    return ["docker", "run", "--rm", "--network", "none", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges", "--pids-limit", "256", "--memory", "1g",
            "-v", ws_root() + ":/work", "-w", "/work", img, "sh", "-c", resolve_refs(command)];
}

def _job_start(command: str) -> ShellJob {
    # Spool to a file rather than a pipe: a pipe fills at ~64KB and then blocks the
    # very long-running process we are trying to keep alive, with nobody draining it.
    _JOB_N += 1;
    jid = "j" + str(_JOB_N);
    spool = os.path.join(tempfile.gettempdir(), "sigil-exec-" + str(os.getpid()) + "-" + jid + ".log");
    fh = open(spool, "w");
    if sandbox_mode() == "docker" {
        p = subprocess.Popen(_docker_argv(command), cwd=ws_root(),
                             stdout=fh, stderr=subprocess.STDOUT, text=True);
    } else {
        p = subprocess.Popen(resolve_refs(command), shell=True, cwd=ws_root(),
                             stdout=fh, stderr=subprocess.STDOUT, text=True);
    }
    job = ShellJob(id=jid, proc=p, spool=spool, cmd=command, started=time.time());
    _JOBS[jid] = job;
    return job;
}

def _job_wait(job: ShellJob, seconds: float) -> None {
    p = job.proc;
    deadline = time.time() + (seconds if seconds > 0.0 else 0.0);
    while (p.poll() is None) and (time.time() < deadline) { time.sleep(0.2); }
}

def _job_new_output(job: ShellJob) -> str {
    # Everything written since the last look, so watching a job reads like a tail
    # instead of re-reading the whole log every turn.
    data = "";
    try {
        with open(job.spool, "r") as f { data = f.read(); }
    } except Exception as e { return ""; }
    seen = job.read;
    job.read = len(data);
    return data[seen:];
}

def _job_report(job: ShellJob, chunk: str) -> str {
    p = job.proc;
    rc = p.poll();
    age = time.time() - job.started;
    jid = job.id;
    body = redact_secrets(chunk);
    if len(body) > 12000 { body = "… [earlier output trimmed]" + chr(10) + body[-12000:]; }
    if not body.strip() { body = "(no output yet)"; }
    if rc is None {
        return ("[job " + jid + "] STILL RUNNING after " + ("%.0f" % age) + "s — output so far:" + chr(10)
                + body + chr(10) + chr(10)
                + "The command was NOT killed. Decide from the output above: keep watching with "
                + "ws_watch(\"" + jid + "\") (pass a bigger wait_seconds for slow work), leave it "
                + "running and do something else, or stop it with ws_kill(\"" + jid + "\").");
    }
    return "[job " + jid + "] exit=" + str(rc) + " after " + ("%.0f" % age) + "s" + chr(10) + body;
}

sem ws_exec = """Run a shell command. By default it runs unconfined on the real host, so it
can drive whatever is installed here — builds, test suites, git, other agent CLIs. NOTHING
is killed on a timer: the command runs as a background job and this returns the output so
far once `wait_seconds` elapses. If the result says STILL RUNNING, read that output and
decide — ws_watch to keep watching, or ws_kill to stop it.""";
sem ws_exec.command = "The shell command to run.";
sem ws_exec.wait_seconds = "How long to wait before reporting back (default 30). Use a larger value for work you expect to be slow.";
def ws_exec(command: str, wait_seconds: int = 30) -> str {
    # `sigil compile` is this agent's own compiler, not a shell command — a nested
    # CLI would fight this process for the session file and outlive any wait.
    routed = _route_sigil(command);
    if routed is not None { return str(routed); }
    if (sandbox_mode() == "docker") and (not _docker_available()) {
        _trace("exec", command + " (no docker)", False);
        return "sandbox=docker is set but docker isn't available — install it, or `configure sandbox off`.";
    }
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
    mode = sandbox_mode();
    _trace("exec", command + ("" if mode == "off" else ("  [" + mode + "]")));
    try { job = _job_start(command); }
    except Exception as e { _trace("exec", str(e)[:120], False); return "could not start the command: " + str(e)[:300]; }
    _job_wait(job, float(wait_seconds if wait_seconds > 0 else 30));
    return _job_report(job, _job_new_output(job));
}

sem ws_watch = """Keep watching a shell job from ws_exec that was still running. Returns
what it has printed SINCE THE LAST LOOK plus whether it has finished. The job keeps
running whether or not you watch it.""";
sem ws_watch.job_id = "The job id ws_exec reported, e.g. 'j1'.";
sem ws_watch.wait_seconds = "How long to wait for more output before reporting back (default 30).";
def ws_watch(job_id: str, wait_seconds: int = 30) -> str {
    jid = str(job_id).strip();
    job = _JOBS.get(jid);
    if job is None { return "no such job '" + jid + "' — ws_jobs() lists this session's jobs"; }
    _trace("watch", jid);
    _job_wait(job, float(wait_seconds if wait_seconds > 0 else 30));
    return _job_report(job, _job_new_output(job));
}

sem ws_kill = "Stop a running shell job started by ws_exec.";
sem ws_kill.job_id = "The job id to stop, e.g. 'j1'.";
def ws_kill(job_id: str) -> str {
    jid = str(job_id).strip();
    job = _JOBS.get(jid);
    if job is None { return "no such job '" + jid + "' — ws_jobs() lists this session's jobs"; }
    p = job.proc;
    rc = p.poll();
    if rc is not None { return "job " + jid + " had already finished (exit=" + str(rc) + ")"; }
    try { p.kill(); p.wait(); } except Exception as e {}
    _trace("kill", jid, False);
    return "stopped job " + jid + ": " + job.cmd[:120];
}

sem ws_jobs = "List the shell jobs started this session — which are still running, how long each has been going, and its command.";
def ws_jobs() -> str {
    if not _JOBS { return "(no shell jobs this session)"; }
    rows: list = [];
    for jid in sorted(_JOBS.keys()) {
        job = _JOBS[jid];
        rc = job.proc.poll();
        state = "running" if rc is None else ("exit=" + str(rc));
        age = ("%.0f" % (time.time() - job.started)) + "s";
        rows.append(jid + "  " + state.ljust(10) + age.rjust(6) + "  " + job.cmd[:100]);
    }
    return chr(10).join(rows);
}

# ---------------------------------------------------------------------------
# Sigil's own compiler — a tool, not a shell command
#
# `sigil compile SKILL.md` is a many-minute gated lift. Run through the shell it is
# a SECOND sigil process contending with this one for the same session file, and its
# progress stays invisible until it ends. In-process it shares this agent's graph,
# reports each stage on the live trace, and has no time limit at all.
# ---------------------------------------------------------------------------
def _compile_stage(ev: dict) -> None {
    try {
        if str(ev.get("state")) == "start" { _trace("compile", str(ev.get("stage", "")) + " …"); }
    } except Exception as e {}
}

sem sigil_compile = """Compile a SKILL.md into a runnable skill on this agent's graph —
Sigil's own compiler. ALWAYS use this instead of running `sigil compile` through the
shell: it runs in this process, on this graph, with no time limit. A compile takes
several minutes and reports each stage as it goes.""";
sem sigil_compile.path = "Path to the SKILL.md file to compile.";
sem sigil_compile.eject_path = "Optional path to also write a standalone runnable .jac program to.";
sem sigil_compile.eject = "Set true to also eject a standalone runnable program under its default name.";
def sigil_compile(path: str, eject_path: str = "", eject: bool = False) -> str {
    try { full = _resolve(path); } except Exception as e { _trace("compile", str(e), False); return "error: " + str(e); }
    if not os.path.isfile(full) { _trace("compile", path + " (missing)", False); return "no such file: " + path; }
    try {
        with open(full, "r") as f { src = f.read(); }
    } except Exception as e { _trace("compile", str(e), False); return "error reading " + path + ": " + str(e); }
    _trace("compile", _rel(full));
    want_eject = bool(eject) or bool(eject_path);
    try { r = compile_skill(src, want_eject, eject_path, _compile_stage, False); }
    except Exception as e { _trace("compile", str(e)[:120], False); return "compile error: " + str(e)[:400]; }
    if not r["ok"] {
        lines: list[str] = ["compile FAILED for '" + str(r["signature"]) + "':"];
        for iss in list(r["issues"] or []) { lines.append("  - " + str(iss)); }
        if r["compile_errors"] { lines.append("  compile: " + str(r["compile_errors"])[:400]); }
        _trace("compile", "failed: " + str(r["signature"]), False);
        return chr(10).join(lines);
    }
    out = "compiled skill: " + str(r["signature"]) + "  ->  " + str(r["module"]);
    for rp in list(r["repairs"] or []) { out += chr(10) + "  (repair) " + str(rp); }
    if r["eject"] { out += chr(10) + "  ejected runnable: " + str(r["eject"]); }
    return out;
}

def _route_sigil(command: str) -> any {
    # Recognise `sigil compile <SKILL.md> [-e [out.jac]]`, however `sigil` is spelled
    # on the path, and answer it in-process. Everything else is a real shell command.
    toks = [str(t) for t in command.strip().split()];
    if len(toks) < 2 { return None; }
    head = toks[0];
    if not ((head == "sigil") or head.endswith("/sigil")) { return None; }
    if toks[1] != "compile" { return None; }
    path = "";
    eject = False;
    eject_path = "";
    i = 2;
    while i < len(toks) {
        t = toks[i];
        if (t == "-e") or (t == "--eject") {
            eject = True;
            nxt = toks[i + 1] if (i + 1) < len(toks) else "";
            if nxt and (not nxt.startswith("-")) { eject_path = nxt; i += 1; }
        } elif (not t.startswith("-")) and (not path) { path = t; }
        i += 1;
    }
    if not path { return "usage: sigil_compile(\"<SKILL.md>\") — the in-process compiler; don't shell out to `sigil compile`"; }
    return sigil_compile(path, eject_path, eject);
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
    base = ws_root();
    n = 0;
    try { n = len(list(os.listdir(base))); } except Exception as e {}
    running = 0;
    for j in _JOBS.values() { if j.proc.poll() is None { running += 1; } }
    mode = sandbox_mode();
    return {"root": base, "items": n, "jobs": len(_JOBS), "running": running,
            "sandbox": mode, "docker": (_docker_available() if mode == "docker" else False)};
}
