"""Sigil runtime glue — the parts that touch the disk and the OS.

The AG-IR -> OSP *compile* itself lives in Jac (``compiler/compiler.jac``'s
``transpile_ir``); this module only

  1. persists the lowered OSP source to disk as a compiled module, and
  2. runs a compiled module in an *isolated subprocess*.

The isolation matters: a compiled OSP agent builds its own task-graph off
``root`` when it runs. If we ran it in-process it would splice its throwaway
task-graph into Sigil's *persistent* agent graph. A subprocess gives each
execution a fresh, disposable ``root`` — Sigil keeps only the compiled
*procedure* (source + AG-IR + stats) on its own graph, never the run artifacts.
"""

import os;
import re;
import sys;
import time;
import shutil;
import subprocess;
import from pathlib { Path }

glob CRYSTAL_DIR: str = "crystallized";   # legacy dir name — existing installs keep modules here
glob _MARKER: str = "<<<SIGIL_REPORT>>>";
glob OBS_LOG: str = "observability/live.jsonl";

# The driver we write next to each compiled module: it imports the module's
# `run`, binds the small model, installs the token observer, and prints the report
# behind a marker. Kept as a `.format()` template — `{{`/`}}` are literal braces.
# It is a jac program like any other, so jac 0.37's type gate applies: a bare
# `dict` (E1036) or an untyped value from a ::py:: module (E1001) fails the run
# before `run` is ever called, and every solve reported "DONE fail" with no output.
glob _DRIVER: str = "import from crystallized.{mod} {{ run }}\n"
    "import from jaclang.byllm.lib {{ Model }}\n"
    "import sigil_observe;\n"
    "import sigil_claude_cc;\n"
    "import sigil_chatgpt;\n"
    "import os;\n"
    "\n"
    "with entry:__main__ {{\n"
    "    obs = os.getenv(\"SIGIL_OBS\", \"\");\n"
    "    sig = os.getenv(\"SIGIL_SIG\", \"\");\n"
    "    sigil_observe.install(obs, sig);\n"
    "    model_name: str = str(os.getenv(\"SIGIL_MODEL\", \"gpt-4o-mini\"));\n"
    "    cfg: dict[str, any] = {{}};\n"
    "    if sigil_claude_cc.is_claude_cc(model_name) {{\n"
    "        sigil_claude_cc.install();\n"
    "        cfg = {{\"native_tools\": False}};\n"
    "    }}\n"
    "    if sigil_chatgpt.is_chatgpt(model_name) {{\n"
    "        sigil_chatgpt.install();\n"
    "        model_name = str(sigil_chatgpt.plan_model(model_name));\n"
    "        cfg = {{\"native_tools\": False}};\n"
    "    }}\n"
    "    if model_name.startswith(\"ollama-cloud/\") {{\n"
    "        m = Model(model_name=\"ollama_chat/\" + model_name[len(\"ollama-cloud/\"):], api_base=\"https://ollama.com\", api_key=os.getenv(\"OLLAMA_API_KEY\", \"\"));\n"
    "    }} else {{\n"
    "        m = Model(model_name=model_name, config=cfg);\n"
    "    }}\n"
    "    task = os.getenv(\"SIGIL_TASK\", \"\");\n"
    "    skill = os.getenv(\"SIGIL_SKILL\", \"\");\n"
    "    out = run(task, m, skill);\n"
    "    print(\"{marker}\");\n"
    "    print(out);\n"
    "}}\n";


# Directory that owns this runtime module (the Sigil project root).
def _here() -> Path {
    return Path(os.path.abspath(__file__)).parent;
}

# The installed native `jac` binary — the self-contained zig bundle that ships its
# own Python + jaclang + byllm runtime (no conda / separate pypi). Resolution:
# `SIGIL_JAC` override; else the `jac` we are already running under (native launch);
# else the `jac` on PATH; else a jac next to this interpreter.
def _jac_bin() -> str {
    env = os.getenv("SIGIL_JAC");
    if env {
        return env;
    }
    exe = sys.executable or "";
    if (os.path.basename(exe) == "jac") and os.path.exists(exe) {
        return exe;
    }
    found = shutil.which("jac");
    if found {
        return found;
    }
    cand = os.path.join(os.path.dirname(exe), "jac");
    return cand if os.path.exists(cand) else "jac";
}

# Directory that owns this runtime — the Sigil project root.
def repo_root() -> str {
    return str(_here());
}

# The project directory (this module lives in `src/`) and its CLI entry point
# (`src/main.jac`, next to this module). Both are absolute so a subprocess can be
# spawned from anywhere and still land on the same graph — the store is resolved
# relative to the working directory, so `cwd` is not a detail here, it decides
# which agent you are talking to.
def project_root() -> str {
    return str(_here().parent);
}

def entry_script() -> str {
    return str(_here() / "main.jac");
}

def project_name(fallback: str = "sigil") -> str {
    # [project] name from jac.toml — the store name jac uses for a root entry.
    t = os.path.join(project_root(), "jac.toml");
    try {
        import tomllib;
        with open(t, "rb") as fh {
            return str(dict(tomllib.load(fh)).get("project", {}).get("name", fallback) or fallback);
        }
    } except Exception as e { return fallback; }
}

def store_path() -> str {
    # The .db this agent actually reads and writes.
    #
    # Measured on jac 0.34.5: an entry script sitting at the PROJECT ROOT keys
    # its store to the [project] name from jac.toml; an entry in a SUBDIRECTORY
    # keys it to that script's own filename. sigil enters through src/main.jac
    # and the Observatory through root-level observatory.jac, so the two doors
    # resolve to DIFFERENT files — .jac/data/main.db and .jac/data/sigil.db.
    #
    # This used to be hardcoded to sigil.db, which stopped being true when
    # main.jac moved into src/ (#153): `sigil where` — the one command whose
    # whole job is answering "which agent am I talking to?" — then named a
    # store the CLI had not written to since.
    data = os.path.join(project_root(), ".jac", "data");
    entry_p = Path(entry_script());
    try { at_root = (str(entry_p.parent.resolve()) == str(Path(project_root()).resolve())); }
    except Exception as e { at_root = False; }
    stem = project_name() if at_root else entry_p.stem;
    return os.path.join(data, stem + ".db");
}

# ---------------------------------------------------------------------------
# Process bookkeeping. Anything that runs longer than one command — the cron
# loop today, the full daemon next — leaves a pidfile under `$SIGIL_HOME/run`,
# so a second copy can tell whether the first is still alive and the CLI can
# answer "is anything actually ticking?" without guessing.
# ---------------------------------------------------------------------------
def sigil_home() -> str {
    d = os.getenv("SIGIL_HOME") or os.path.expanduser("~/.sigil");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def run_dir() -> str {
    d = os.path.join(sigil_home(), "run");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def log_dir() -> str {
    d = os.path.join(sigil_home(), "log");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def pid_path(name: str) -> str {
    return os.path.join(run_dir(), name + ".pid");
}

def pid_alive(pid: int) -> bool {
    if pid <= 0 {
        return False;
    }
    try {
        os.kill(pid, 0);
    } except ProcessLookupError as e {
        return False;
    } except PermissionError as e {
        return True;      # it exists, it just isn't ours to signal
    } except Exception as e {
        return False;
    }
    return True;
}

def read_pid(name: str) -> int {
    p = Path(pid_path(name));
    if not p.exists() {
        return 0;
    }
    try {
        return int((p.read_text() or "0").strip() or "0");
    } except Exception as e {
        return 0;
    }
}

def clear_pidfile(name: str) -> None {
    p = Path(pid_path(name));
    try {
        if p.exists() {
            p.unlink();
        }
    } except Exception as e {
        return None;
    }
    return None;
}

def write_pidfile(name: str, pid: int = 0) -> str {
    path = pid_path(name);
    try {
        Path(path).write_text(str(pid or os.getpid()));
    } except Exception as e {
        return "";
    }
    return path;
}

def process_running(name: str) -> bool {
    # A pidfile pointing at a dead process is worse than no pidfile — it makes
    # `daemon status` lie. Clear it on the way past.
    pid = read_pid(name);
    if pid <= 0 {
        return False;
    }
    if pid_alive(pid) {
        return True;
    }
    clear_pidfile(name);
    return False;
}

# The AG-IR authoring contract handed to the frontier compiler. Prefer the
# compiler-exact template (a concrete working AG-IR to mimic) over the abstract
# primitive-standard — zero-shot authoring needs the exact schema.
def default_contract() -> str {
    for name in ["agir-template.md", "agir-standard.md", "agir-primitives.md"] {
        p = _here() / "contracts" / name;
        if p.exists() {
            return p.read_text();
        }
    }
    return "";
}

def _slug(s: str) -> str {
    slugged = re.sub(r"[^a-z0-9]+", "_", (s or "").lower()).strip("_");
    return slugged[:48] or "task";
}

def module_name(signature: str, version: int) -> str {
    return f"{_slug(signature)}_v{int(version)}";
}

# Best-effort skill signature from an AG-IR: the frontmatter `name:` field, else a slug.
def agir_name(text: str) -> str {
    for line in (text or "").splitlines() {
        s = line.strip();
        if s.startswith("name:") {
            return _slug(s.split(":", 1)[1].strip().strip('"').strip("'"));
        }
        if s and (not s.startswith("#")) and (not s.startswith("---")) and (":" not in s) {
            break;
        }
    }
    return _slug((text or "")[:48]);
}

# Best-effort human description from a SKILL.md: its frontmatter `description:`.
# A SKILL.md description is written to be a TRIGGER — "use when …" — so it is the
# one string that tells another harness when to reach for the compiled skill.
# Carry it through the compile instead of replacing it with provenance boilerplate
# (see sigil_mcp_serve, where it becomes the MCP tool description).
def skill_description(text: str) -> str {
    lines = (text or "").splitlines();
    started = False;
    i = 0;
    n = len(lines);
    while i < n {
        line = lines[i];
        s = line.strip();
        if not started {
            if not s { i += 1; continue; }
            if s != "---" { return ""; }   # no frontmatter at all
            started = True;
            i += 1;
            continue;
        }
        if s == "---" { break; }           # end of frontmatter
        if s.lower().startswith("description:") {
            inline = s.split(":", 1)[1].strip();
            # A YAML block/folded scalar (`>`, `|`, with optional chomp/indent
            # like `>-`, `|-`, `>+`, `|2`) puts NO content on the key line —
            # the value is the indented lines that follow. Returning the raw
            # `>-` marker (the old behavior) made it the skill's intent, which
            # eval_skill then used as the probe task: the auto-eval judged a
            # real run against an empty/meaningless task and forced a needless
            # relearn. Gather the block body instead.
            if inline and (inline[0] in "|>") {
                body: list = [];
                j = i + 1;
                while j < n {
                    bl = lines[j];
                    bs = bl.strip();
                    if bs == "---" { break; }                 # frontmatter end
                    # a dedented, non-empty `key:` line ends the block
                    if bs and (not bl.startswith((" ", "\t"))) { break; }
                    body.append(bs);
                    j += 1;
                }
                # folded scalar semantics: join non-empty lines with spaces
                folded = " ".join([b for b in body if b]);
                return folded.strip().strip('"').strip("'");
            }
            return inline.strip('"').strip("'");
        }
        i += 1;
    }
    return "";
}

# Drop a precompiled OSP module into crystallized/ and return its new path.
def install_osp(src_path: str, signature: str, workdir: str = ".", version: int = 1) -> str {
    d = Path(workdir) / CRYSTAL_DIR;
    d.mkdir(parents=True, exist_ok=True);
    (d / "__init__.jac").touch(exist_ok=True);
    # versioned filename: re-registering an existing signature must not
    # silently overwrite the module file an older TaskGraph still points at
    dst = d / f"{module_name(signature, version)}.jac";
    dst.write_text(Path(src_path).read_text());
    return str(dst);
}

# Persist a lowered OSP agent as ``crystallized/<sig>_v<n>.jac`` and return its path.
def write_module(osp_source: str, signature: str, version: int, workdir: str = ".") -> str {
    d = Path(workdir) / CRYSTAL_DIR;
    d.mkdir(parents=True, exist_ok=True);
    (d / "__init__.jac").touch(exist_ok=True);   # make it an importable package dir
    mod = module_name(signature, version);
    path = d / f"{mod}.jac";
    path.write_text(osp_source);
    return str(path);
}

# ---------------------------------------------------------------------------
# Eager graph commit for long-lived processes. jac commits a process's graph
# writes ONCE, at exit, with a per-anchor optimistic version check — and one
# stale anchor rolls back the WHOLE changeset. The chat REPL sits open for
# hours while the daemon commits every 30s, so its exit commit is guaranteed
# to lose that race on any anchor both sides touch (the Registry hub, every
# time a skill runs in-process). Committing immediately after each mutation
# shrinks the dirty window from session-length to sub-second.
# Returns "" on success, else one short sentence for the terminal; the full
# story lands in $SIGIL_HOME/log/error.log either way. Never raises.
# ---------------------------------------------------------------------------
def commit_now(context: str = "") -> str {
    # jac >=0.37 moved both out of jac0core/runtimelib into jaclang.runtime
    import from jaclang.runtime.runtime { JacRuntime }
    import from jaclang.runtime.exceptions { WriteConflict }
    import from .sigil_errors { log_error }
    try {
        JacRuntime.commit();
    } except WriteConflict as wc {
        path = log_error("commit_now(" + context + ")", wc);
        return ("graph writes from " + (context or "this session")
                + " lost a version race with a concurrent commit (a daemon tick or "
                + "another sigil process) and were discarded — detail: " + path);
    } except Exception as e {
        # Non-conflict commit trouble (store locked, disk): logged, not fatal —
        # the writes stay dirty and the exit commit retries them.
        log_error("commit_now(" + context + ")", e);
        return "";
    }
    return "";
}

# ---------------------------------------------------------------------------
# Transaction checkpoints — never hold the graph across slow work.
#
# Every graph read joins this process's open transaction, and the store runs it
# SERIALIZABLE, so a transaction stays open until something commits it. A cron
# fire read the skill, ran it for minutes in a subprocess, bumped its run count,
# then called the judge and the distiller (two more model calls) before anything
# committed. Every graph read in between flushed that bumped row into the still-open
# transaction, so the row stayed locked, and everything that touched the skill
# meanwhile either waited ("canceling statement due to lock timeout ... relation
# anchors") or lost a version race ("WriteConflict: anchor <TaskGraph> changed
# concurrently"). Measured on one install: every scheduled fire's own save failed
# for a day, and channel turns failed beside them.
#
# A checkpoint commits what this process has written so far and ends its
# transaction, so the next read starts a fresh one. It goes at the edges of slow
# work: before and after a skill run, when a tool call finishes, between compile
# stages, before the daemon waits on a tick. SIGIL_TXN_CHECKPOINTS=0 turns them off.
# ---------------------------------------------------------------------------
def txn_checkpoints_on() -> bool {
    v = str(os.environ.get("SIGIL_TXN_CHECKPOINTS") or "").strip().lower();
    return v not in ["0", "false", "no", "off"];
}

def checkpoint(context: str = "") -> str {
    # "" when committed (or there was nothing to commit, or checkpoints are off);
    # otherwise commit_now's message for a write that lost a race.
    if not txn_checkpoints_on() { return ""; }
    return commit_now(context);
}

# ---------------------------------------------------------------------------
# iCloud Drive files that are not on this Mac.
#
# With "Optimize Mac Storage" on, iCloud evicts files it thinks are unused (the
# Desktop and Documents too, when they sync) and leaves "dataless" placeholders.
# A process macOS has not allowed to download one gets EDEADLK ("Resource
# deadlock avoided") on read instead of the file. Sigil's daemon runs detached,
# so a scheduled skill that appends to a log on the Desktop worked for weeks and
# then failed once iCloud evicted the log, and so did the chat agent reading it.
# The policy is per process and children inherit it (shell tools, skill runs,
# bridges), so every Sigil process sets it once at import.
# SIGIL_CLOUD_DOWNLOADS=0 leaves the system default.
# ---------------------------------------------------------------------------
glob _CLOUD_POLICY: dict[str, any] = {"set": False, "ok": False};

def allow_cloud_downloads() -> bool {
    # True when this process may now download dataless files on read. Never raises.
    if _CLOUD_POLICY["set"] { return bool(_CLOUD_POLICY["ok"]); }
    _CLOUD_POLICY["set"] = True;
    if sys.platform != "darwin" { return False; }
    v = str(os.environ.get("SIGIL_CLOUD_DOWNLOADS") or "").strip().lower();
    if v in ["0", "false", "no", "off"] { return False; }
    try {
        import ctypes;
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True);
        # <sys/resource.h>: IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3,
        # IOPOL_SCOPE_PROCESS = 0, IOPOL_MATERIALIZE_DATALESS_FILES_ON = 2
        _CLOUD_POLICY["ok"] = (int(libc.setiopolicy_np(3, 0, 2)) == 0);
    } except Exception as e {
        _CLOUD_POLICY["ok"] = False;
    }
    return bool(_CLOUD_POLICY["ok"]);
}

def cloud_file_hint(err: any, path: str = "") -> str {
    # A sentence to add to a read error that is really "this is in iCloud and not
    # downloaded", or "" for any other error.
    import errno;
    if getattr(err, "errno", None) != errno.EDEADLK { return ""; }
    where = path if path else "the file";
    return (where + " is in iCloud Drive and not downloaded to this Mac. Open it in Finder, "
            + "or run `brctl download '" + where + "'`, then try again. To stop iCloud evicting it, "
            + "right-click it in Finder and choose Keep Downloaded.");
}

with entry {
    allow_cloud_downloads();
}

# ---------------------------------------------------------------------------
# Cross-process write serialization.
#
# Every sigil surface is a separate OS process against ONE store: the CLI, each
# daemon-fired job, each api_call subprocess, and every parallel terminal a user
# has open. jac's per-anchor optimistic versioning is what keeps them honest,
# but honest here means LOSING: when two processes read the Soul and both
# commit, the second raises WriteConflict and its ENTIRE changeset is rolled
# back. Measured on this repo: 8 concurrent `sigil teach` -> 3 died on
# "anchor <soul> changed concurrently (expected v3, found v4)", after each had
# already printed its success line.
#
# Retrying the commit cannot fix that on its own — the changeset was built from
# a read that is now stale, so a retry re-commits stale data or conflicts again.
# The fix is to not have the race: a mutation runs as a critical section that
# spans its READ and its COMMIT, serialized across processes by an advisory
# lock on the store directory. The lock is held for the length of one
# read-modify-commit (sub-second), never for the length of a command — a
# `compile` still runs its model calls fully in parallel with every other
# process, and only its final graph write is ordered.
# ---------------------------------------------------------------------------
glob GRAPH_LOCK_NAME: str = ".write.lock";

def graph_lock_path() -> str {
    # Beside the store itself, so one lock covers exactly one graph: a second
    # project (or ~/.sigil/app vs a checkout) has its own store and its own lock.
    d = os.path.join(project_root(), ".jac", "data");
    try { Path(d).mkdir(parents=True, exist_ok=True); } except Exception as e { }
    return os.path.join(d, GRAPH_LOCK_NAME);
}

def _lock_acquire(path: str = "", timeout_s: float = 60.0) -> any {
    # Exclusive advisory lock, polled so a wedged holder cannot block forever.
    # Returns the open handle (the lock lives as long as it does), or None when
    # locking is unavailable — in which case the caller proceeds UNSERIALIZED
    # rather than refusing to work, exactly as it behaved before this existed.
    # `path` defaults to the graph lock; the daemon's single-spawn claim passes
    # its own, so a slow daemon start cannot block a graph write.
    try { import fcntl; } except Exception as e { return None; }
    try { fh = open(str(path) if path else graph_lock_path(), "a+"); } except Exception as e2 { return None; }
    waited = 0.0;
    while waited < float(timeout_s) {
        try {
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB);
            return fh;
        } except Exception as e3 {
            time.sleep(0.05);
            waited += 0.05;
        }
    }
    try { fh.close(); } except Exception as e4 { }
    return None;
}

def _lock_release(fh: any) -> None {
    if fh is None { return None; }
    try {
        import fcntl;
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN);
    } except Exception as e { }
    try { fh.close(); } except Exception as e2 { }
    return None;
}

def graph_write(mutate: any, context: str = "") -> dict[str, any] {
    # Run `mutate` — a zero-arg callable that READS the graph and mutates it —
    # as a serialized critical section, then commit it. Returns
    # {"ok": bool, "data": <mutate's return>, "error": str}; never raises, so
    # callers decide how loud a failed write should be.
    #
    # The read MUST happen inside `mutate`, not before the call: a value read
    # outside the lock is exactly the stale anchor this exists to prevent.
    fh = _lock_acquire();
    out: any = None;
    try {
        out = mutate();
    } except Exception as e {
        _lock_release(fh);
        import from .sigil_errors { log_error }
        log_error("graph_write(" + str(context) + ")", e);
        return {"ok": False, "data": None, "error": str(e)[:300]};
    } except BaseException as be {
        # ^C or an interrupted turn (sigil_interrupt): let it through, but never
        # with the cross-process lock still held by a long-lived process.
        _lock_release(fh);
        raise;
    }
    err = commit_now(context);
    _lock_release(fh);
    return {"ok": (err == ""), "data": out, "error": err};
}

def module_argv(jacbin: str, driver: str) -> list[str] {
    # How a compiled skill is run: standalone (--no-takeover), off the agent's
    # graph. Its driver sits in src/, so a plain `jac run` took the project over:
    # the module's walker attached its nodes to the agent's superroot and
    # committed on exit, while the process that launched it (a scheduled job,
    # `solve`, the Observatory) still held a transaction over that same root, so
    # that process's commit failed every time ("could not serialize access due
    # to concurrent update", "WriteConflict ... expected v0, found v1"). And each
    # run rewrote the project's client build, which broke an Observatory starting
    # at the same moment ("Sources changed during preparation"). A skill run's
    # graph is scratch; nothing reads it back. SIGIL_SKILL_STANDALONE=0 restores
    # the takeover run.
    if not skill_standalone() { return [jacbin, "run", "--no-serve", driver]; }
    return [jacbin, "run", "--no-serve", "--no-takeover", driver];
}

def skill_standalone() -> bool {
    v = str(os.environ.get("SIGIL_SKILL_STANDALONE") or "").strip().lower();
    return v not in ["0", "false", "no", "off"];
}

def skill_run_dir() -> str {
    # Where a compiled skill runs: $SIGIL_HOME/skill-runs, outside the project.
    # --no-takeover alone was not enough. jac picks the store from the working
    # directory, so a run started in src/ still committed its whole walker graph
    # onto the agent's superroot (47 dead run trees, 676 nodes, on one install),
    # and the process that launched it, holding a transaction across the run,
    # then failed its commit ("could not serialize access", then jac's retry
    # "WriteConflict ... expected v1, found v0"). The compiled runtime also
    # stages its bundle directory into the working directory, which put a copy
    # of every crystallized module into src/. Out here both land in scratch.
    d = os.path.join(sigil_home(), "skill-runs");
    try { Path(d).mkdir(parents=True, exist_ok=True); } except Exception as e { }
    return d;
}

def module_cwd(workdir: str) -> str {
    return skill_run_dir() if skill_standalone() else str(workdir);
}

# Run a compiled module in an isolated ``jac run`` subprocess. Returns
# ``{ok, report, error}``. Never raises — a crash/timeout is a typed failure the
# walker escalates (mutate + retry), never a walker abort. ``mcp_json`` is the
# user's registered MCP servers (JSON), exposed to the run's ``_live_tool`` via
# ``SIGIL_MCP``, and the sibling-skill shelf via ``SIGIL_SKILL_TOOLS``.
def execute_module(module_path: str, task: str, model_name: str,
                   skill: str = "", workdir: str = ".", timeout: int = 1800,
                   mcp_json: str = "", signature: str = "",
                   skill_tools: str = "", channels: str = "") -> dict[str, any] {
    mod = Path(module_path).stem;
    wd = os.path.abspath(str(workdir));
    driver = Path(wd) / f"_driver_{mod}.jac";
    driver.write_text(_DRIVER.format(mod=mod, marker=_MARKER));
    env = dict(os.environ);
    env.update(SIGIL_MODEL=model_name, SIGIL_TASK=task, SIGIL_SKILL=skill);
    env["SIGIL_OBS"] = str(Path(wd) / OBS_LOG);
    # The run starts outside src/ (module_cwd), so put src/ back on the path for
    # the runtime's own Python imports (`import sigil_mcp` in _live_tool).
    env["PYTHONPATH"] = os.pathsep.join([p for p in [wd, str(env.get("PYTHONPATH") or "")] if p]);
    env["SIGIL_SIG"] = signature;
    if mcp_json {
        env["SIGIL_MCP"] = mcp_json;
    }
    if skill_tools {
        # The OTHER compiled skills this run may call, as tools on its autonomy
        # slots (built by `_skill_tools()` in the emitted prelude). Absent, a
        # compiled module is exactly as standalone as it has always been — which
        # is what an ejected artifact, or anyone else's harness, gets.
        env["SIGIL_SKILL_TOOLS"] = skill_tools;
    }
    jacbin = _jac_bin();
    if channels {
        # The user's connected channels, for the `send_message` builtin
        # (compiler/mechanical/toolib.jac), and the way back to this Sigil it
        # sends through. Without them the builtin says it has nowhere to send.
        env["SIGIL_CHANNELS"] = channels;
        env["SIGIL_ENTRY"] = entry_script();
        env["SIGIL_PROJECT"] = project_root();
        env["SIGIL_JAC"] = jacbin;
    }
    try {
        p = subprocess.run(module_argv(jacbin, str(driver)), cwd=module_cwd(wd), env=env,
                           capture_output=True, text=True, timeout=timeout);
    } except subprocess.TimeoutExpired as e {
        return {"ok": False, "report": "", "error": f"timeout after {timeout}s"};
    } except FileNotFoundError as ex {
        return {"ok": False, "report": "", "error": f"jac not found: {ex}"};
    } finally {
        if driver.exists() {
            driver.unlink();
        }
    }
    out = p.stdout or "";
    if _MARKER in out {
        rep = out.split(_MARKER, 1)[1].strip();
        # a clean exit with an empty or INCOMPLETE report is a silent failure —
        # the superpowers sweep's escape-hatch runs exited 0 with empty hands.
        ok = (p.returncode == 0) and bool(rep) and (not rep.startswith("INCOMPLETE"));
    } else {
        rep = out.strip();
        ok = False;
    }
    return {"ok": ok, "report": rep, "error": ("" if ok else (p.stderr or "")[-2000:])};
}
