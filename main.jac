"""Sigil CLI — the agent has no config files. Its soul, skills and memory
all live on the graph, persisted automatically in `.jac/data/sigil.db` across runs:

    jac run main.jac -- chat                 # interactive Claude-style REPL
    jac run main.jac -- config               # interactive settings editor
    jac run main.jac -- solve "extract tables from report.pdf as csv"
    jac run main.jac -- solve "..."          # reuses / evolves the graph
    jac run main.jac -- soul
    jac run main.jac -- configure small_model ollama_chat/qwen3:8b
    jac run main.jac -- teach "the user always wants CSV with a header row"
    jac run main.jac -- serve                # REST API + Observatory web UI

`chat` and `config` live in sigil_chat.jac (rich + prompt_toolkit); both drive the
same persistent graph as the one-shot commands above — and as `serve`, which
exposes that very graph through the Observatory.
"""

import os;
import sys;
import time;
import sqlite3;
import threading;
import subprocess;
import from src.sigil {
    solve_task, library, describe_soul, configure, teach, recollect,
    add_mcp, remove_mcp, mcp_status, register_skill, compile_skill, lint_skill,
    eval_skill, relearn, forget,
    model_alias, model_set_fallback, models_info, use_claude_code,
    tool_group_set, tool_allowed, tools_policy_info,
    compile_stage_label, compile_stage_line, compile_stage_secs, verbose_mode
}
import from src.cron {
    cron_add, cron_list, cron_show, cron_runs, cron_remove, cron_enable, cron_tick,
    cron_run_now, cron_daemon, next_due_ms
}
import from src.sigil_cron { fmt_when, human_secs }
import from src.channels { channel_add, channel_list, channel_remove, message_send, inbound, react, edit, channel_history }
import from src.sigil_bridge { bridge_run, bridge_running, REPLY_MARKER }
import from src.sigil_channels_setup { channel_setup_guide, channel_bootstrap, channel_kinds }
import from src.sigil_docs { list_docs, read_doc }
import from src.hooks { hook_add, hook_list, hook_enable, hook_remove }
import from src.approvals { approvals_get, approvals_set, allowlist_add, check_exec, approve, approvals_elevate, approvals_deescalate, elevated_audit, approvals_pending, approvals_clear }
import from src.agent { run_task }
import from src.sigil_tasks { tasks_list, tasks_show }
import from src.sigil_secrets { secret_add, secret_remove, secret_list, secret_test, redact_secrets }
import from src.sigil_plugins { plugin_install, plugin_list, plugin_remove }
import from src.sigil_migrate { migrate_openclaw }
import from src.sigil_runtime { _jac_bin, read_pid, project_root }
import from src.sigil_errors { install_error_log, friendly_llm_error, log_error, error_log_path }
import from src.sigil_api { JSON_MARKER }
import from src.eject_agent { eject_agent, carries_compiler }
import from src.sigil_daemon {
    daemon_run, daemon_start, daemon_stop, daemon_status, daemon_logs, daemon_running,
    scheduler_running,
    service_install, service_uninstall, log_path, graph_path
}
import from src.sigil_sessions { session_note, session_show, session_reset, session_list }

glob _CLAUDE_MODE: bool = False;   # set by the global `--claude` flag, read at dispatch
glob _QUIET: bool = False;         # set by the global `--quiet` flag: never stream model output

def cli_args(raw: list) -> list {
    # jac leaves its own flags in sys.argv (e.g. -s <session> -- <cmd>). Take
    # everything after '--' if present, else drop argv[0] and skip -s <file>.
    args: list = [];
    if "--" in raw {
        args = raw[raw.index("--") + 1:];
    } else {
        eat_next = False;
        for a in raw[1:] {
            if eat_next { eat_next = False; continue; }
            if (a == "-s") or (a == "--session") { eat_next = True; continue; }
            args.append(a);
        }
    }
    # `--claude` is global, not per-command: strip it wherever it lands so no
    # command's positional args shift, and record it for the dispatch below.
    out: list = [];
    for a in args {
        if a == "--claude" { _CLAUDE_MODE = True; }
        elif (a == "--quiet") or (a == "-q") { _QUIET = True; }
        else { out.append(a); }
    }
    return out;
}

glob _CV: dict = {"open": "", "line": ""};          # current in-flight stage: label + rendered line
glob _HB: dict = {"on": False, "t0": 0.0, "gen": 0}; # the stage heartbeat (see _hb_tick)

def _hb_start() -> None {
    # Start a fresh heartbeat, retiring any prior one. `gen` fences a stale
    # ticker that was mid-sleep when it stopped: if a new stage (e.g. compile
    # right after lint) turns the beat back on within its 1s tick, the old
    # thread sees a bumped gen and exits instead of double-painting the line.
    _HB["gen"] = int(_HB["gen"]) + 1;
    _HB["on"] = True;
    _HB["t0"] = time.time();
    mygen = int(_HB["gen"]);
    threading.Thread(target=_hb_tick, args=(mygen,), daemon=True).start();
}

def _hb_tick(mygen: int) -> None {
    # Liveness for the quiet stage view. A raise2 stage (or the lint spec loop)
    # is a chain of frontier calls that can run for MINUTES; without this the
    # open "◐ authoring …" line sat frozen and a working compile was
    # indistinguishable from a hung one. While the beat is live, rewrite its
    # line once a second with the elapsed time. Stage events own the line the
    # moment they fire (done clears `line` first).
    while _HB["on"] and (int(_HB["gen"]) == mygen) {
        time.sleep(1.0);
        if (not _HB["on"]) or (int(_HB["gen"]) != mygen) or _VB["on"] { continue; }
        line = str(_CV["line"] or "");
        if not line { continue; }
        secs = int(time.time() - float(_HB["t0"]));
        el = (str(secs // 60) + "m" + str(secs % 60).rjust(2, "0") + "s") if secs >= 60 else (str(secs) + "s");
        sys.stdout.write(chr(13) + chr(27) + "[2K" + line + " " + chr(27) + "[2m" + chr(0x2026) + " " + el + chr(27) + "[0m");
        sys.stdout.flush();
    }
}

# ---------------------------------------------------------------------------
# The verbose build view — watching the model write the artifact.
#
# A compile is dozens of model calls that used to show nothing while they ran: a
# stage label, a spinner, minutes of silence, a verdict. But the words being
# written ARE the thing being built. With a provider that can stream (claude
# mode), every delta lands here and is printed under the stage that asked for it,
# dimmed and indented so the structure stays readable.
#
# Verbose mode drops the in-place line rewriting the quiet view uses: rewriting
# the current line only works when nothing else is writing to it, and here
# something is. Stages print as a scrolling transcript instead.
# ---------------------------------------------------------------------------
glob _VB: dict = {"on": False, "col": 0, "open": False, "w": 100, "kind": "", "nl": 0};

def _term_cols() -> int {
    # A pty with no winsize set reports 0 rather than raising, and 0 silently
    # became the minimum wrap width — a column of shredded words. Fall back
    # through COLUMNS before giving up on a default.
    n = 0;
    try { n = int(os.get_terminal_size().columns); } except Exception { n = 0; }
    if n <= 0 {
        try { n = int(os.environ.get("COLUMNS", "0")); } except Exception { n = 0; }
    }
    return n if n > 0 else 100;
}

def _stream_sink(kind: str, text: str) -> None {
    # One delta from the model. `kind` is "text" (the answer) or "thinking".
    if not text { return; }
    # A whitespace-only delta must never OPEN a block: a stream that led with
    # newlines painted a column of blank lines before its first word — which
    # read as a hung compile printing nothing.
    if (not _VB["open"]) and (not str(text).strip()) { return; }
    ind = "      ";
    sty = (chr(27) + "[2m") if kind == "text" else (chr(27) + "[2;3;38;5;98m");
    if not _VB["open"] {
        # width once per block, not once per token: this runs at token rate
        w0 = _term_cols() - len(ind) - 1;
        _VB["w"] = w0 if w0 >= 24 else 24;
        sys.stdout.write(chr(10) + ind);
        _VB["open"] = True;
        _VB["col"] = 0;
        _VB["kind"] = "";
        _VB["nl"] = 0;
    }
    if (str(_VB["kind"]) != kind) and (int(_VB["col"]) > 0) {
        # thinking and answer are styled differently, but they also deserve a
        # break: the reasoning running straight into the JSON it produced reads
        # like one garbled paragraph.
        sys.stdout.write(chr(10) + ind);
        _VB["col"] = 0;
    }
    _VB["kind"] = kind;
    w = int(_VB["w"]);
    buf = "";
    for ch in str(text) {
        if ch == chr(10) {
            # cap a newline RUN at one blank line — models love to pad JSON
            # blocks with whitespace, and every extra newline was a blank line
            # of "progress"
            if int(_VB["nl"]) >= 2 { continue; }
            _VB["nl"] = int(_VB["nl"]) + 1;
            buf += chr(10) + ind;
            _VB["col"] = 0;
        } else {
            _VB["nl"] = 0;
            if int(_VB["col"]) >= w { buf += chr(10) + ind; _VB["col"] = 0; }
            buf += ch;
            _VB["col"] = int(_VB["col"]) + 1;
        }
    }
    sys.stdout.write(sty + buf + chr(27) + "[0m");
    sys.stdout.flush();
}

def _vb_close() -> None {
    # End the streamed block before a stage line is printed over it.
    if _VB["open"] {
        sys.stdout.write(chr(10));
        _VB["open"] = False;
        _VB["col"] = 0;
    }
}

def _install_stream_view() -> bool {
    # Only claude-cc can stream today — it is the provider Sigil owns. Other
    # providers still get the stage view; making them stream means declaring the
    # compiler's byLLM slots `stream=True`, which changes every slot's return type.
    if _QUIET or (not verbose_mode()) { return False; }
    try {
        import from src.sigil_claude_cc { set_stream_sink }
        set_stream_sink(_stream_sink);
        _VB["on"] = True;
        return True;
    } except Exception as e { return False; }
}

def _compile_ev(ev: dict) -> None {
    # live build view: start opens the stage line, done rewrites it with counts
    # + timing. Only ever touches the CURRENT line (portable ANSI). The stage
    # label and summary come from sigil.jac so chat's trace says the same thing.
    label = compile_stage_label(str(ev["stage"]));
    if _VB["on"] {
        # verbose: a scrolling transcript, because the streamed output below each
        # stage makes rewriting the current line impossible.
        _vb_close();
        if str(ev.get("state")) == "start" {
            if str(ev["stage"]) == "repair" {
                sys.stdout.write("  " + chr(27) + "[38;5;135m" + chr(0x27F3) + chr(27) + "[0m repair  round " + str(ev.get("round", 1)) + ": " + str(ev.get("issues", "?")) + " issues " + chr(0x2192) + " " + str(ev.get("target", "views")) + chr(10));
            } else {
                sys.stdout.write("  " + chr(27) + "[38;5;135m" + chr(0x25D0) + chr(27) + "[0m " + label + chr(10));
            }
        } elif str(ev.get("state")) == "done" {
            sys.stdout.write("  " + chr(27) + "[38;5;51m" + chr(0x2714) + chr(27) + "[0m " + (label + "                ")[:16] + compile_stage_line(ev) + "  " + chr(27) + "[2m" + compile_stage_secs(ev) + chr(27) + "[0m" + chr(10));
        }
        sys.stdout.flush();
        return;
    }
    if str(ev.get("state")) == "start" {
        _HB["t0"] = time.time();
        if str(ev["stage"]) == "repair" {
            line = "  " + chr(27) + "[38;5;135m" + chr(0x27F3) + chr(27) + "[0m repair  round " + str(ev.get("round", 1)) + ": " + str(ev.get("issues", "?")) + " issues " + chr(0x2192) + " " + str(ev.get("target", "views"));
        } else {
            line = "  " + chr(27) + "[38;5;135m" + chr(0x25D0) + chr(27) + "[0m " + label;
        }
        # The line stays OPEN (no newline) — `done` rewrites it in place with the
        # counts, and the heartbeat rewrites it with elapsed time in between.
        # Repair rounds included: each one is a minutes-long author call, and the
        # old newline-terminated form left them tickerless.
        sys.stdout.write(chr(13) + chr(27) + "[2K" + line + " " + chr(27) + "[2m" + chr(0x2026) + chr(27) + "[0m");
        _CV["open"] = label;
        _CV["line"] = line;
        sys.stdout.flush();
    } elif str(ev.get("state")) == "done" {
        # clear BEFORE writing so a ticker firing mid-write never repaints a
        # stale open line over the finished one
        _CV["open"] = "";
        _CV["line"] = "";
        sys.stdout.write(chr(13) + chr(27) + "[2K  " + chr(27) + "[38;5;51m" + chr(0x2714) + chr(27) + "[0m " + (label + "                ")[:16] + compile_stage_line(ev) + "  " + chr(27) + "[2m" + compile_stage_secs(ev) + chr(27) + "[0m" + chr(10));
        sys.stdout.flush();
    }
}

def _arg(argv: list, i: int) -> str {
    return str(argv[i]) if len(argv) > i else "";
}

# ---------------------------------------------------------------------------
# One agent, wherever you invoke it.
#
# jac resolves the graph store relative to the WORKING DIRECTORY, so `sigil` run
# from two directories was two different agents with two different memories,
# skills and schedules — and the daemon, which has to pick one, would have been
# a third. Every entry pins cwd to the project.
#
# That would break the paths a person typed, so the invocation directory is kept
# (the `sigil` wrapper passes it as SIGIL_PWD before it cds) and every
# user-supplied path resolves against it. The installed launcher already cd'd to
# ~/.sigil/app, which is why `sigil compile ./SKILL.md` from anywhere else could
# never find the file.
# ---------------------------------------------------------------------------
glob _PWD0: str = "";

def _pin_project_dir() -> None {
    _PWD0 = os.environ.get("SIGIL_PWD") or os.getcwd();
    try {
        os.chdir(project_root());
    } except Exception {
        return None;
    }
    return None;
}

def user_path(p: str) -> str {
    s = str(p or "");
    if not s { return s; }
    s = os.path.expanduser(s);
    if os.path.isabs(s) { return s; }
    return os.path.abspath(os.path.join(_PWD0 or os.getcwd(), s));
}

def _to_int(s: str, dflt: int) -> int {
    try { return int(str(s).strip()); } except Exception { return dflt; }
}

def _json_text(payload: dict) -> str {
    # One JSON line for the `api` command. Anything the encoder cannot represent
    # becomes its string form rather than an exception — an endpoint returning a
    # slightly lossy answer beats one returning a 500 because a value was a node.
    import json;
    try { return str(json.dumps(payload, default=_stringify)); }
    except Exception { return "{\"ok\": false, \"data\": null, \"error\": \"unencodable result\"}"; }
}

def _stringify(o: any) -> str {
    return str(o);
}

def _warn_no_ticker() -> None {
    # A schedule with nothing ticking it is the failure mode this release exists
    # to end. Say so at the moment the job is written, not after a week of runs=0.
    if scheduler_running() { return None; }
    dim = chr(27) + "[2m";
    rst = chr(27) + "[0m";
    print(dim + "   nothing is ticking the schedule right now — start it with "
          + "`sigil daemon start` (background) or `sigil cron daemon` (foreground),"
          + " or these jobs never fire." + rst);
    return None;
}

# Compile-time clarification, rendered in the compile TUI's own aesthetic: an amber
# '?' marker (matching the cyan '✔' of a finished stage), a dimmed legend, and an
# inline prompt — the same shape as the ejected agent's runtime human gates. Passed
# to compile_skill as the `ask` callback when --clarify is set; each answer binds an
# underspecified obligation's modality (Do / Maybe / Don't) before authoring.
def _clarify_ask_tui(question: str) -> str {
    amber = chr(27) + "[38;5;220m";
    dim = chr(27) + "[2m";
    rst = chr(27) + "[0m";
    try {
        sys.stdout.write(chr(10) + "  " + amber + "?" + rst + " " + str(question) + chr(10));
        sys.stdout.write("      " + dim + "do" + rst + " = always · " + dim + "maybe"
                         + rst + " = when the task calls for it · " + dim + "dont" + rst + " = never" + chr(10));
        sys.stdout.write("      " + amber + "> " + rst);
        sys.stdout.flush();
    } except Exception {  }
    try { return str(input()); } except Exception { return ""; }
}

# The SKILL LINTER review loop, in the clarify TUI's aesthetic: each finding
# shows how the compiler read the skill sentence and the minimal edit that
# would make the reading unambiguous; the human accepts edits one by one.
# Accepted edits are written back to the SKILL.md — the durable form of a
# --clarify answer. Returns {source, pre_spec, applied}: the (possibly
# amended) text to compile, and the already-extracted spec for reuse when
# nothing changed (amending invalidates it — the compile re-extracts).
# One live status line for the spec loop, cooking-show style: which round, which
# phase, how many obligations found so far. `_CV["line"]` is the heartbeat's
# canvas — set it here and the ticker keeps elapsed time counting beside it.
def _lint_spec_status(ev: dict) -> None {
    purple = chr(27) + "[38;5;135m";
    dim = chr(27) + "[2m";
    rst = chr(27) + "[0m";
    phase = str(ev.get("phase", ""));
    rnd = ev.get("round", 0);
    cap = ev.get("cap", 0);
    rules = ev.get("rules", 0);
    where = (dim + "round " + str(rnd) + ("/" + str(cap) if cap else "") + rst + "  ") if rnd else "";
    verb = {"extract": "reading the obligations",
            "ground": "grounding " + str(rules) + " against the prose",
            "coverage": "hunting for gaps (" + str(ev.get("lenses", 0)) + " lenses) · " + str(rules) + " so far",
            "modality": "auditing modal force · " + str(rules) + " rules",
            "round_done": str(rules) + " rules" + ((" · " + str(ev.get("uncovered", 0)) + " gaps left") if ev.get("uncovered", 0) else " · looks complete"),
            "clarify": "flagging under-specified rules · " + str(rules) + " total"}.get(phase, phase);
    _CV["line"] = "  " + purple + chr(0x25D0) + rst + " lint  " + where + verb;
}

def _lint_review_tui(path: str, source: str) -> dict {
    import from src.compiler.ai.lint { apply_edits }
    import from src.compiler.ai.spec_loop { set_spec_progress }
    amber = chr(27) + "[38;5;220m";
    grn = chr(27) + "[32m";
    red = chr(27) + "[31m";
    dim = chr(27) + "[2m";
    rst = chr(27) + "[0m";
    # Live view instead of a frozen "this takes a few minutes": the spec loop is
    # a multi-minute chain of frontier calls and used to print one line and hang.
    _tty = False;
    try { _tty = bool(sys.stdout.isatty()); } except Exception {  }
    if _tty {
        _CV["line"] = "  " + chr(27) + "[38;5;135m" + chr(0x25D0) + rst + " lint  " + dim + "extracting the spec" + rst;
        set_spec_progress(_lint_spec_status);
        _hb_start();
    } else {
        print("  " + dim + "linting (spec extraction — this takes a few minutes)..." + rst);
    }
    try { lr = lint_skill(source); }
    finally {
        _HB["on"] = False;
        _CV["line"] = "";
        set_spec_progress(None);
        if _tty { sys.stdout.write(chr(13) + chr(27) + "[2K"); sys.stdout.flush(); }
    }
    findings = list(lr["findings"]);
    if not findings {
        print("  lint: CLEAR — every obligation states its modal force.");
        return {"source": source, "pre_spec": lr["spec"], "applied": 0};
    }
    fixable = [f for f in findings if f.applicable];
    print("  lint: " + str(len(findings)) + " finding(s), " + str(len(fixable))
          + " with a suggested fix" + (":" if fixable else "."));
    accepted: list = [];
    stop = False;
    for f in findings {
        one = str(f.quote).replace(chr(10), " ")[:90];
        if not f.applicable {
            print("    " + dim + "? " + str(f.rule_id) + " [" + str(f.kind) + "] \"" + one
                  + "\" — no safe suggestion; edit by hand or answer via --clarify" + rst);
            continue;
        }
        if stop { continue; }
        print(chr(10) + "  " + amber + "?" + rst + " " + str(f.rule_id) + " [" + str(f.kind) + "] "
              + dim + str(f.reason).replace(chr(10), " ")[:110] + rst);
        print("      " + red + "- " + str(f.old).replace(chr(10), " ") + rst);
        opts: list = [];
        for m in ["do", "maybe", "dont"] {
            if m in f.variants {
                print("      " + grn + m + " -> " + str(f.variants[m]).replace(chr(10), " ") + rst);
                opts.append(m);
            }
        }
        try {
            sys.stdout.write("      " + dim + " / ".join(opts) + rst
                             + " = apply that phrasing · " + dim + "n" + rst + " = skip · "
                             + dim + "q" + rst + " = stop reviewing" + chr(10));
            sys.stdout.write("      " + amber + "> " + rst);
            sys.stdout.flush();
        } except Exception {  }
        resp = "";
        try { resp = str(input()).strip().lower(); } except Exception { resp = "q"; }
        if resp in f.variants {
            f.new = str(f.variants[resp]);   # the human's modality picks the phrasing
            accepted.append(f);
        }
        elif resp in ["q", "quit"] { stop = True; }
    }
    if not accepted {
        print("  lint: no fixes applied.");
        return {"source": source, "pre_spec": lr["spec"], "applied": 0};
    }
    amended = apply_edits(source, accepted);
    try {
        with open(path, "w") as fh { fh.write(amended); }
        print("  lint: " + str(len(accepted)) + " fix(es) applied -> " + path);
    } except Exception as e {
        print("  lint: could not write " + path + " (" + str(e)[:80] + ") — compiling the amended text anyway");
    }
    return {"source": amended, "pre_spec": None, "applied": len(accepted)};
}

# The all-zeros superroot — the root every plain `jac run` executes against.
glob SUPERROOT: str = "00000000000000000000000000000000";

def _align_guest_root(data_dir: str) -> bool {
    # In server mode, anonymous requests to `:pub` walkers run as the internal
    # `__guest__` user, whose root defaults to a fresh anchor — a graph parallel
    # to the CLI's. Point guest at the superroot so the CLI and the Observatory
    # read and write ONE graph. Returns True once the auth store has been seen
    # (aligned or already correct); False while it doesn't exist yet.
    users = os.path.join(data_dir, "users.db");
    if not os.path.exists(users) { return False; }
    try {
        conn = sqlite3.connect(users);
        conn.execute(
            "UPDATE identity_users SET root_id = ? WHERE identities LIKE '%__guest__%' AND root_id != ?",
            (SUPERROOT, SUPERROOT)
        );
        conn.commit();
        conn.close();
        return True;
    } except Exception {
        return False;
    }
}

# The Observatory's own port — NOT jac's 8000 default, so it never collides
# with (or gets mistaken for) some other jac server. 8199 is the established
# convention: the `sigil` launcher exports SIGIL_PORT (default 8199) and the
# docs' curl examples target it. Keep all three in sync.
glob OBSERVATORY_PORT: str = "8199";

def _port_owner(port: str) -> list {
    # [pid, command] of whatever LISTENs on the port, or [] if it is free.
    try {
        r = subprocess.run(["lsof", "-ti", "tcp:" + port, "-sTCP:LISTEN"],
                           capture_output=True, text=True, timeout=5);
        pids = [x.strip() for x in str(r.stdout or "").split() if x.strip()];
        if not pids { return []; }
        rc = subprocess.run(["ps", "-p", pids[0], "-o", "command="],
                            capture_output=True, text=True, timeout=5);
        return [pids[0], str(rc.stdout or "").strip()];
    } except Exception as e { return []; }
}

def _claim_port(port: str) -> bool {
    # STRICT port policy: the Observatory runs on `port` or not at all. jac's
    # own "port in use → try the next one" fallback is exactly how you end up
    # watching a stale server's agent without knowing it — so detect the owner
    # up front and kill it (with consent) or bail with instructions.
    owner = _port_owner(port);
    if not owner { return True; }
    pid = str(owner[0]);
    cmd = str(owner[1]);
    stale = ("observatory.jac" in cmd) or ("jac start" in cmd);
    print("observatory port " + port + " is already in use by pid " + pid
          + (" (looks like a previous observatory run):" if stale else ":"));
    print("  " + cmd[:140]);
    sys.stdout.flush();   # these must land before jac start floods the log
    doit = False;
    if sys.stdin.isatty() {
        ans = str(input("kill it and take the port? [y/N] ")).strip().lower();
        doit = ans in ["y", "yes"];
    } else {
        # headless: replacing our own stale observatory is safe; anything else
        # is somebody's server — never kill it, and NEVER fall back silently.
        doit = stale;
        if stale { print("headless run — replacing the stale observatory."); }
    }
    if not doit {
        print("leaving it alone. free the port (kill " + pid + ") or pick another:  sigil serve <port>");
        sys.stdout.flush();
        return False;
    }
    try { os.kill(int(pid), 15); } except Exception as e {
        print("could not kill " + pid + ": " + str(e)[:120]);
        return False;
    }
    tries = 0;
    while (tries < 20) and _port_owner(port) { time.sleep(0.3); tries += 1; }
    if _port_owner(port) {
        print("pid " + pid + " is still holding the port — kill -9 " + pid + " yourself, or:  sigil serve <port>");
        return False;
    }
    print("port " + port + " reclaimed.");
    sys.stdout.flush();
    return True;
}

def serve_observatory(port: str) {
    # `sigil serve [port]` — run the full-stack server (REST API + Observatory
    # web UI) on the same graph as the CLI, on the Observatory's OWN port
    # (8199 unless overridden) — claimed strictly via _claim_port, never
    # silently moved. jac.toml pins the server's SQLite store to
    # `.jac/data/sigil.db` (the CLI's project db); this handles the root side.
    proj = os.path.dirname(os.path.abspath(__file__));
    data = os.path.join(proj, ".jac", "data");
    port = str(port) if port else OBSERVATORY_PORT;
    if not _claim_port(port) { return; }
    aligned = _align_guest_root(data);
    cmdline = [_jac_bin(), "start", os.path.join(proj, "observatory.jac"), "--port", port];
    p = subprocess.Popen(cmdline, cwd=proj);
    try {
        # First-ever start: the server creates the auth store moments after
        # boot; align the guest root as soon as it lands so run #1 shares the
        # graph too. Bounded poll — worst case ~5 min covers a cold client build.
        tries = 0;
        while (not aligned) and (p.poll() is None) and (tries < 600) {
            time.sleep(0.5);
            aligned = _align_guest_root(data);
            tries += 1;
        }
        p.wait();
    } except KeyboardInterrupt {
        p.terminate();
        p.wait();
    }
}

with entry:__main__ {
    # Before anything reads the graph: pin cwd to the project so every entry —
    # CLI, TUI, daemon, a job the daemon fires — is the SAME agent.
    _pin_project_dir();
    # And before any model can be called: provider failures must never smear
    # tracebacks over the terminal. byLLM's loguru output and litellm's banners
    # go to $SIGIL_HOME/log/error.log; each surface reports one sentence.
    install_error_log();
    argv = cli_args(sys.argv);
    cmd = _arg(argv, 0) if argv else "help";

    # `--claude` is a per-invocation flag, but the daemon's work happens in
    # CHILD processes — every tick, every channel message. A flag that stopped at
    # the process boundary would mean background jobs ran on a provider key the
    # user does not have, which is exactly how the first end-to-end fire failed.
    # The environment is what children inherit, so that is where the mode lives.
    if str(os.environ.get("SIGIL_CLAUDE") or "") == "1" { _CLAUDE_MODE = True; }

    # Must precede any awaken() — that is where the tiers bind.
    if _CLAUDE_MODE {
        # `--claude` promises the SUBSCRIPTION. Check before binding a single tier:
        # discovering there is no login on the first model call wastes the call and
        # reports it as a provider error, which reads like Sigil's fault.
        import from src.sigil_claude_cc { auth_status }
        _auth = auth_status();
        if str(_auth["mode"]) == "none" {
            print("xx --claude needs a Claude Code subscription login, and this machine has none.",
                  file=sys.stderr);
            print("   Run `claude` once and sign in, then re-run.", file=sys.stderr);
            print("   To bill an approved ANTHROPIC_API_KEY instead: SIGIL_CLAUDE_ALLOW_API_KEY=1",
                  file=sys.stderr);
            sys.exit(1);
        }
        use_claude_code(True);
        os.environ["SIGIL_CLAUDE"] = "1";   # every subprocess from here inherits it
        # stderr, not stdout: this is a status line, and `mcp-serve` gives stdout
        # to the JSON-RPC wire where a stray line is a protocol violation.
        _who = ("api key" if str(_auth["mode"]) == "api-key"
                else (str(_auth["account"]) if _auth["account"] else "your subscription"));
        print(chr(27) + "[2m" + chr(0x2726) + " claude mode: every tier runs on your local Claude Code CLI ("
              + _who + ")" + chr(27) + "[0m", file=sys.stderr);
    }

    if (cmd == "serve") or (cmd == "observatory") {
        serve_observatory(_arg(argv, 1));
    } elif cmd == "solve" {
        task = _arg(argv, 1);
        skill = _arg(argv, 2);
        if not task {
            print("usage: solve \"<task>\" [skill]");
        } else {
            try {
                r = run_task(task, skill);
            } except Exception as e {
                # a dead model/key/network must read as a sentence, not a stack
                log_error("solve failed: " + task[:200], e);
                print("xx " + friendly_llm_error(e), file=sys.stderr);
                sys.exit(1);
            }
            print("=== route trace ===");
            print(r["trace"]);
            print("=== signature: " + str(r["signature"]) + " ===");
            print(redact_secrets(str(r["result"])));   # never surface a resolved secret
        }
    } elif cmd == "library" {
        lib = library();
        if not lib {
            print("(empty — no compiled procedures yet)");
        } else {
            print("compiled procedures (" + str(len(lib)) + "):");
            for e in lib {
                print("  " + e["signature"] + "  v" + str(e["version"])
                      + "  [" + e["origin"] + "]  runs=" + str(e["runs"])
                      + " ok=" + str(e["successes"]));
            }
        }
    } elif cmd == "soul" {
        s = describe_soul();
        print("soul: " + str(s["name"]));
        print("  persona : " + str(s["persona"]));
        print("  models  : frontier=" + str(s["frontier_model"])
              + "  small=" + str(s["small_model"]) + "  router=" + str(s["router_model"]));
        print("  tools   : workspace=" + str(s["workspace"]) + "  sandbox=" + str(s["sandbox"]) + "  verbose=" + ("on" if s["verbose"] else "off"));
        print("  channels: " + ", ".join([str(c) for c in s["channels"]]) + "   prompt-mode: " + str(s["prompt_mode"]));
        eths = list(s["ethos"]);
        mems = list(s["memories"]);
        print("  skills  : " + str(s["skills"]) + "   memories: " + str(len(mems)));
        print("  ethos   :");
        for e in eths { print("    - " + str(e)); }
        if mems {
            print("  memory  :");
            for m in mems { print("    (" + str(m["kind"]) + ", used " + str(m["uses"]) + "x) " + str(m["content"])); }
        }
    } elif cmd == "configure" {
        key = _arg(argv, 1);
        val = _arg(argv, 2);
        if not key or not val { print("usage: configure <key> <value>"); }
        else { print(configure(key, val)); }
    } elif cmd == "models" {
        # models list | set <tier> <name> | alias <name> <model> | fallback <tier> <m1,m2,...>
        sub = _arg(argv, 1);
        if sub == "set" { print(configure(_arg(argv, 2) + "_model", _arg(argv, 3))); }
        elif sub == "alias" { print(model_alias(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "fallback" { print(model_set_fallback(_arg(argv, 2), _arg(argv, 3))); }
        elif (sub == "list") or (not sub) {
            mi = models_info();
            print("tiers:");
            print("  frontier : " + str(mi["frontier"]));
            print("  small    : " + str(mi["small"]));
            print("  router   : " + str(mi["router"]));
            al = dict(mi["aliases"]);
            if al { print("aliases:"); for (k, v) in al.items() { print("  " + str(k) + " -> " + str(v)); } }
            fb = dict(mi["fallbacks"]);
            has_fb = False;
            for (k, v) in fb.items() { if v { has_fb = True; } }
            if has_fb { print("fallbacks:"); for (k, v) in fb.items() { if v { print("  " + str(k) + " : " + str(v)); } } }
        }
        else { print("usage: models list|set <tier> <name>|alias <name> <model>|fallback <tier> <m1,m2>"); }
    } elif cmd == "teach" {
        fact = _arg(argv, 1);
        if not fact { print("usage: teach \"<fact>\""); }
        else { print(teach(fact, "fact")); }
    } elif cmd == "recall" {
        q = _arg(argv, 1);
        for m in recollect(q, 8) { print("  (" + m["kind"] + ") " + m["content"]); }
    } elif cmd == "docs" {
        # docs           -> list reference topics
        # docs <topic>   -> print one (fuzzy match)
        topic = _arg(argv, 1);
        if topic { print(read_doc(topic)); }
        else { print(list_docs()); }
    } elif cmd == "eval" {
        # eval <signature> [probe-task]  — grounded verification of a compiled skill
        sig = _arg(argv, 1); probe = _arg(argv, 2);
        if not sig { print("usage: eval <signature> [probe-task]"); }
        else {
            r = eval_skill(sig, probe);
            if not r["ok"] { print(str(r["error"])); }
            else {
                print("eval " + str(r["signature"]) + " v" + str(r["version"]) + " -> "
                      + str(r["score"]) + "/100  " + ("PASS" if r["passed"] else "FAIL"));
                print("  reason: " + str(r["reason"]));
                print("  result: " + str(r["result"]));
            }
        }
    } elif cmd == "relearn" {
        # relearn <signature> [hint]  — discard + recompile a skill fresh (frontier)
        sig = _arg(argv, 1); hint = _arg(argv, 2);
        if not sig { print("usage: relearn <signature> [hint]"); }
        else {
            r = relearn(sig, hint);
            if not r["ok"] { print(str(r["error"])); }
            else { print("relearned " + str(r["signature"]) + " -> v" + str(r["version"]) + " [" + str(r["origin"]) + "]"); }
        }
    } elif cmd == "forget" {
        # forget <signature>  — remove a skill entirely (all versions + module files)
        sig = _arg(argv, 1);
        if not sig { print("usage: forget <signature>"); }
        else {
            r = forget(sig);
            print("forgot '" + str(r["signature"]) + "' (" + str(r["removed"]) + " version(s) removed)");
        }
    } elif cmd == "add-mcp" {
        # add-mcp <name> <stdio|http|sse> <command-or-url> [args...]
        name = _arg(argv, 1); transport = _arg(argv, 2); target = _arg(argv, 3);
        rest = [str(x) for x in argv[4:]] if len(argv) > 4 else [];
        if not name or not transport or not target { print("usage: add-mcp <name> <stdio|http|sse> <command-or-url> [args...]"); }
        else { print(add_mcp(name, transport, target, rest)); }
    } elif cmd == "remove-mcp" {
        name = _arg(argv, 1);
        if not name { print("usage: remove-mcp <name>"); }
        else { print(remove_mcp(name)); }
    } elif cmd == "mcp" {
        st = mcp_status();
        if not st { print("(no MCP servers registered)"); }
        else {
            for s in st {
                tl = list(s["tools"]);
                print("  " + str(s["name"]) + "  [" + str(s["transport"]) + "]  tools: "
                      + (", ".join([str(t) for t in tl]) if tl else "(none)"));
            }
        }
    } elif cmd == "cron" {
        # cron add <name> <at|every|cron> <spec> "<task>" [tz] [channel] | list | show <name> | runs <name> | rm <name> | enable/disable <name> | tick | run <name> | daemon [interval]
        sub = _arg(argv, 1);
        if sub == "add" {
            r = cron_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5),
                         _arg(argv, 6) if len(argv) > 6 else "UTC", _arg(argv, 7), False);
            if not r.get("ok", True) {
                print("xx " + str(r["error"]), file=sys.stderr);
                sys.exit(1);
            }
            print("scheduled '" + str(r["name"]) + "' [" + str(r["kind"]) + "] next="
                  + fmt_when(int(r["next_run_ms"])));
            _warn_no_ticker();
        } elif sub == "list" {
            js = cron_list();
            if not js { print("(no cron jobs)"); }
            for j in js {
                print("  " + str(j["name"]) + "  [" + str(j["kind"]) + " " + str(j["spec"]) + "]  "
                      + ("on" if j["enabled"] else "off") + "  runs=" + str(j["runs"])
                      + " err=" + str(j["errors"]) + "  " + str(j["last_status"])
                      + "  next=" + fmt_when(int(j["next_run_ms"])));
            }
            if js { _warn_no_ticker(); }
        } elif sub == "show" { print(cron_show(_arg(argv, 2))); }
        elif sub == "runs" {
            for r in cron_runs(_arg(argv, 2)) { print("  " + ("ok " if r["ok"] else "err") + "  " + str(r["summary"])); }
        } elif sub == "rm" { print(cron_remove(_arg(argv, 2))); }
        elif sub == "enable" { print(cron_enable(_arg(argv, 2), True)); }
        elif sub == "disable" { print(cron_enable(_arg(argv, 2), False)); }
        elif sub == "tick" {
            t = cron_tick();
            # the armed count is the daemon's heartbeat: it proves the tick can
            # see the jobs on the graph, which is the whole question when a job
            # sits at runs=0.
            print("tick: fired " + str(t["count"]) + " job(s), " + str(t["armed"]) + " armed");
            for f in list(t["fired"]) { print("  " + str(f["name"]) + " -> " + ("ok" if f["ok"] else "err")); }
        } elif sub == "run" {
            nm = _arg(argv, 2);
            if not nm { print("usage: cron run <name>"); }
            else {
                out = cron_run_now(nm);
                if not out["ok"] { print("xx " + str(out["error"]), file=sys.stderr); sys.exit(1); }
                ran = dict(out["ran"]);
                print(("ok  " if ran["ok"] else "err ") + str(ran["name"]));
                print(redact_secrets(str(ran["summary"])));
            }
        } elif sub == "daemon" {
            iv = _to_int(_arg(argv, 2), 30);
            if scheduler_running() {
                print("xx a cron daemon is already running (pid "
                      + str(read_pid("cron")) + ")", file=sys.stderr);
                sys.exit(1);
            }
            cron_daemon(iv);
        } else { print("usage: cron add|list|show|runs|rm|enable|disable|tick|run|daemon ..."); }
    } elif cmd == "daemon" {
        # daemon start [interval] | stop | restart [interval] | status | logs [n]
        #        | run [interval]  (foreground supervisor — what start spawns)
        #        | install [interval] | uninstall   (launchd / systemd)
        sub = _arg(argv, 1);
        if sub == "run" {
            daemon_run(_to_int(_arg(argv, 2), 30));
        } elif (sub == "start") or (sub == "restart") {
            if sub == "restart" and daemon_running() { daemon_stop(); }
            iv = _to_int(_arg(argv, 2), 30);
            r = daemon_start(iv);
            if not r["ok"] { print("xx " + str(r["error"]), file=sys.stderr); sys.exit(1); }
            print("sigil daemon started — pid " + str(r["pid"]) + ", ticking every "
                  + str(iv) + "s");
            print("  graph : " + str(r["graph"]));
            print("  log   : " + str(r["log"]) + "   (sigil daemon logs)");
        } elif sub == "stop" {
            r = daemon_stop();
            if not r["ok"] { print("xx " + str(r["error"]), file=sys.stderr); sys.exit(1); }
            print("sigil daemon stopped (pid " + str(r["pid"]) + ")");
        } elif (sub == "status") or (not sub) {
            s = daemon_status();
            if s["running"] {
                print("sigil daemon: running — pid " + str(s["pid"])
                      + ", up " + human_secs(int(s["uptime_s"]))
                      + ", tick " + str(s["interval_s"]) + "s");
            } else {
                print("sigil daemon: NOT running   (sigil daemon start)");
            }
            print("  graph   : " + str(s["graph"]));
            print("  log     : " + str(s["log"]));
            print("  jobs    : " + str(s["jobs"]) + " scheduled, " + str(s["armed"]) + " armed");
            print("  next due: " + fmt_when(int(s["next_due_ms"])));
            brs = [str(b) for b in list(s["bridges"])];
            want = [str(c) for c in list(s["channels"])];
            if want or brs {
                missing = [c for c in want if c not in brs];
                line = ", ".join(brs) if brs else "none";
                if missing { line += "   (not connected: " + ", ".join(missing) + ")"; }
                print("  channels: " + line);
            }
            print("  at login: " + str(s["service"]) + "   (sigil daemon install)");
        } elif sub == "logs" {
            print(daemon_logs(_to_int(_arg(argv, 2), 40)));
        } elif sub == "install" {
            r = service_install(_to_int(_arg(argv, 2), 30));
            if not r["ok"] {
                print("xx could not install the service: " + str(r["error"]), file=sys.stderr);
                print("   unit file written to " + str(r["path"]), file=sys.stderr);
                sys.exit(1);
            }
            print("installed the " + str(r["manager"]) + " service — Sigil now starts at login");
            print("  unit: " + str(r["path"]));
        } elif sub == "uninstall" {
            r = service_uninstall();
            if not r["ok"] { print("xx " + str(r["error"]), file=sys.stderr); sys.exit(1); }
            print("removed " + str(r["path"]) + " — Sigil no longer starts at login");
        } else {
            print("usage: daemon start|stop|restart|status|logs|run|install|uninstall");
        }
    } elif cmd == "eject-agent" {
        # eject-agent <signature|all> <dir> [name] — the compiled skill as a WHOLE
        # agent: its own graph, memory, schedule, channels and daemon. `-e` on
        # compile still emits the one-shot single file; this is the other thing.
        sig = _arg(argv, 1);
        outd = _arg(argv, 2);
        if (not sig) or (not outd) {
            print("usage: eject-agent <signature|all> <dir> [name]");
        } else {
            sigs: list = [] if sig == "all" else [sig];
            r = eject_agent(_arg(argv, 3), user_path(outd), sigs, "");
            if not r["ok"] { print("xx " + str(r["error"]), file=sys.stderr); sys.exit(1); }
            leaks = list(r["compiler_leaks"]);
            print("ejected agent '" + str(r["name"]) + "' -> " + str(r["path"]));
            print("  skills : " + ", ".join([str(x) for x in list(r["skills"])]));
            print("  runtime: " + str(r["modules"]) + " modules, no compiler");
            if leaks {
                print("xx but it carries the compiler after all:", file=sys.stderr);
                for l in leaks { print("     " + str(l), file=sys.stderr); }
                sys.exit(1);
            }
            print("");
            print("  cd " + str(r["path"]) + " && ./" + str(r["name"]) + " solve \"<task>\"");
            print("  ./" + str(r["name"]) + " daemon start      # it keeps working without you");
        }
    } elif cmd == "where" {
        # Which agent am I talking to? One question, one answer — the graph path.
        print("graph     : " + graph_path());
        print("project   : " + project_root());
        print("invoked in: " + (_PWD0 or os.getcwd()));
        print("daemon    : " + ("running" if daemon_running() else "not running"));
        print("errors    : " + error_log_path());
    } elif cmd == "api" {
        # api <name> <json-args> — the machine-readable face of the CLI, and the
        # ONLY thing the HTTP endpoints run. Prints one JSON object behind a
        # marker so a caller can find it past jac's startup chatter. Every
        # endpoint therefore answers from this graph, in this process, which is
        # the whole reason the Observatory can now see the agent.
        import json;
        name = _arg(argv, 1);
        raw = _arg(argv, 2) if len(argv) > 2 else "{}";
        a: dict = {};
        try { a = dict(json.loads(raw or "{}")); } except Exception { a = {}; }
        payload: dict = {"ok": True, "data": None, "error": ""};
        try {
            if name == "soul" { payload["data"] = describe_soul(); }
            elif name == "graph" {
                # Serialize the typed view-model to plain dicts HERE: the payload
                # crosses the subprocess seam through json.dumps(default=str), which
                # would otherwise flatten VGraph to its repr string — and the
                # Observatory would read `nodes: undefined` forever.
                import from src.sigil { graph_snapshot }
                _vg = graph_snapshot();
                payload["data"] = {
                    "nodes": [{"id": _n.id, "label": _n.label, "group": _n.group, "detail": _n.detail}
                              for _n in _vg.nodes],
                    "edges": [{"src": _e.src, "dst": _e.dst, "kind": _e.kind} for _e in _vg.edges],
                    "skills": _vg.skills, "memories": _vg.memories, "mcp": _vg.mcp
                };
            }
            elif name == "library" { payload["data"] = library(); }
            elif name == "mcp" { payload["data"] = mcp_status(); }
            elif name == "observability" {
                # Same seam rule as "graph": VObs must leave as plain dicts.
                import from src.sigil { observability_tail }
                _vo = observability_tail(int(a.get("n", 120)));
                payload["data"] = {
                    "calls": [{"model": _c.model, "signature": _c.signature,
                               "prompt_tokens": _c.prompt_tokens,
                               "completion_tokens": _c.completion_tokens,
                               "reasoning_tokens": _c.reasoning_tokens,
                               "cache_read_tokens": _c.cache_read_tokens,
                               "cost_usd": _c.cost_usd, "content": _c.content,
                               "reasoning": _c.reasoning, "tools": _c.tools}
                              for _c in _vo.calls],
                    "tin": _vo.tin, "tout": _vo.tout, "treason": _vo.treason,
                    "cost": _vo.cost, "n": _vo.n
                };
            }
            elif name == "recall" { payload["data"] = recollect(str(a.get("query", "")), int(a.get("k", 8))); }
            elif name == "teach" { payload["data"] = teach(str(a.get("fact", "")), str(a.get("kind", "fact"))); }
            elif name == "configure" { payload["data"] = configure(str(a.get("key", "")), str(a.get("value", ""))); }
            elif name == "solve" { payload["data"] = run_task(str(a.get("task", "")), str(a.get("skill", ""))); }
            elif name == "register_skill" { payload["data"] = register_skill(str(a.get("source", "")), str(a.get("kind", "md"))); }
            elif name == "add_mcp" {
                payload["data"] = add_mcp(str(a.get("name", "")), str(a.get("transport", "stdio")),
                                          str(a.get("target", "")), list(a.get("args") or []));
            }
            elif name == "eval" { payload["data"] = eval_skill(str(a.get("signature", "")), str(a.get("probe", ""))); }
            elif name == "relearn" { payload["data"] = relearn(str(a.get("signature", "")), str(a.get("hint", ""))); }
            elif name == "forget" { payload["data"] = forget(str(a.get("signature", ""))); }
            elif name == "chat" {
                _r = run_task(str(a.get("text", "")), "");
                payload["data"] = {
                    "id": "sigil-chatcmpl", "object": "chat.completion",
                    "model": str(a.get("model", "sigil")),
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": str(_r["result"])}}]
                };
            }
            elif name == "models" {
                _data: list = [];
                for tier in ["frontier", "small", "router"] {
                    _data.append({"id": "sigil-" + tier, "object": "model", "owned_by": "sigil"});
                }
                for e in list(library()) {
                    _sk = dict(e);
                    _data.append({"id": "sigil-skill/" + str(_sk["signature"]),
                                  "object": "model", "owned_by": "sigil"});
                }
                payload["data"] = {"object": "list", "data": _data};
            }
            elif name == "tools_invoke" {
                import from src.sigil_mcp { dispatch }
                _res = dispatch(str(a.get("name", "")), [dict(a.get("arguments") or {})]);
                if _res is None {
                    payload["ok"] = False;
                    payload["error"] = "no registered tool '" + str(a.get("name", "")) + "'";
                } else { payload["data"] = _res; }
            }
            elif name == "inbound" {
                payload["data"] = inbound(str(a.get("channel", "webhook")), str(a.get("peer", "anon")),
                                          str(a.get("text", "")), str(a.get("thread_id", "")));
            }
            elif name == "cron_tick" { payload["data"] = cron_tick(); }
            elif name == "cron_list" { payload["data"] = cron_list(); }
            elif name == "tasks" { payload["data"] = tasks_list(int(a.get("n", 20))); }
            elif name == "hooks" { payload["data"] = hook_list(); }
            elif name == "channels" { payload["data"] = channel_list(); }
            elif name == "approvals" { payload["data"] = approvals_get(); }
            else {
                payload["ok"] = False;
                payload["error"] = "unknown api '" + str(name) + "'";
            }
        } except Exception as _apierr {
            payload["ok"] = False;
            payload["error"] = str(_apierr)[:600];
        }
        print(JSON_MARKER);
        print(_json_text(payload));
    } elif cmd == "register-skill" {
        # register-skill <path> [md|agir|osp]  (kind auto-detected from extension)
        path = _arg(argv, 1); kind = _arg(argv, 2);
        if not path { print("usage: register-skill <path> [md|agir|osp]"); }
        else {
            if not kind {
                low = path.lower();
                if low.endswith(".jac") { kind = "osp"; }
                elif low.endswith(".ir") or low.endswith(".agir") or low.endswith(".yaml") or low.endswith(".yml") { kind = "agir"; }
                else { kind = "md"; }
            }
            path = user_path(path);
            src = path if kind == "osp" else open(path).read();
            r = register_skill(src, kind);
            print("registered skill: " + str(r["signature"]) + "  [" + str(r["origin"]) + "]  -> " + str(r["module"]));
        }
    } elif cmd == "compile" {
        # compile <SKILL.md> [-e|--eject [out.jac]] — the gated AI lift: spec
        # loop -> spine -> flows -> assemble -> G1/G4/G5 gates + repair. Sets
        # the skill on the graph; -e also ejects one runnable .jac program.
        path = _arg(argv, 1);
        if (not path) or path.startswith("-") {
            print("usage: compile <SKILL.md> [-e|--eject [out.jac]] [--lint|--no-lint] [--clarify] [--strict] [--agent|--legacy]");
        } else {
            eject = False; eject_path = ""; agent_author = False; strict = False;
            clarify = False; frontend = ""; lint_force = False; no_lint = False;
            i = 2;
            while i < len(argv) {
                flg = _arg(argv, i);   # not `a` — the entry block is one scope and `a` is reused below as a list
                if flg == "--agent" { agent_author = True; }
                elif flg == "--strict" { strict = True; }
                elif flg == "--clarify" { clarify = True; }
                elif flg == "--lint" { lint_force = True; }
                elif flg == "--no-lint" { no_lint = True; }
                elif flg == "--legacy" { frontend = "legacy"; }
                elif flg == "--staged" { frontend = "staged"; }
                elif (flg == "-e") or (flg == "--eject") {
                    eject = True;
                    nxt = _arg(argv, i + 1);
                    if nxt and (not nxt.startswith("-")) { eject_path = nxt; i += 1; }
                }
                i += 1;
            }
            # resolve both against the directory the user typed them in, not the
            # project dir this process pinned itself to
            path = user_path(path);
            if eject_path { eject_path = user_path(eject_path); }
            _tty = False;
            try { _tty = bool(sys.stdout.isatty()); } except Exception {  }
            # --clarify asks inline; only meaningful with an interactive stdin.
            _stdin_tty = False;
            try { _stdin_tty = bool(sys.stdin.isatty()); } except Exception {  }
            ask = _clarify_ask_tui if (clarify and _stdin_tty) else None;
            if clarify and (not _stdin_tty) {
                print("  (note: --clarify needs an interactive terminal; assuming Maybe + warning instead)");
            }
            src_text = open(path).read();
            pre_spec: any = None;
            # The SKILL LINTER gate: on an interactive compile, offer to lint
            # first — suggested fixes are reviewed one by one and accepted
            # edits land in the SKILL.md before the compile reads it.
            if _stdin_tty and _tty and (not no_lint) {
                go_lint = lint_force;
                if not go_lint {
                    try {
                        sys.stdout.write(chr(10) + "  ? lint the skill first — review suggested fixes one by one? [Y/n] ");
                        sys.stdout.flush();
                        lresp = str(input()).strip().lower();
                        go_lint = (lresp in ["", "y", "yes"]);
                    } except Exception { go_lint = False; }
                }
                if go_lint {
                    try {
                        lrv = _lint_review_tui(path, src_text);
                        src_text = str(lrv["source"]);
                        pre_spec = lrv["pre_spec"];
                    } except Exception as le {
                        log_error("lint failed: " + path, le);
                        print("  lint failed (" + str(le)[:80] + ") — compiling without it");
                    }
                }
            }
            if _tty { print(chr(10) + "  Compiling " + path); }
            if _tty { _install_stream_view(); }
            if _tty and (not _VB["on"]) {
                # the quiet view's liveness thread — the verbose transcript has
                # the token stream for that
                _hb_start();
            }
            try {
                r = compile_skill(src_text, eject, eject_path,
                                  _compile_ev if _tty else None, agent_author,
                                  os.path.dirname(os.path.abspath(path)), strict, ask, frontend, pre_spec);
            } except Exception as e {
                # the frontier model died under the compile (bad name, key,
                # network) — one sentence + the log, never a provider stack
                _HB["on"] = False;
                if _tty { _vb_close(); print(""); }
                log_error("compile failed: " + path, e);
                print("xx " + friendly_llm_error(e, "", "frontier"), file=sys.stderr);
                sys.exit(1);
            }
            _HB["on"] = False;
            if _tty { _vb_close(); print(""); }
            if not r["ok"] {
                # the fix-forward exit note: what failed, what the ladder
                # tried, and the next concrete step — never a bare issue dump.
                print("compile FAILED for '" + str(r["signature"]) + "'  [status: " + str(r.get("status", "failed")) + "]");
                print(str(r.get("explain") or ""));
            } else {
                print("compiled skill: " + str(r["signature"]) + "  [status: " + str(r.get("status", "")) + "]  -> " + str(r["module"]));
                for fx in list(r.get("fixes") or []) { print("  (fix) " + str(fx)); }
                for rp in list(r["repairs"] or []) { print("  (repair) " + str(rp)); }
                # residual findings — the agent runs; these are its known edges,
                # each naming its own fix. errors first.
                fnds = list(r.get("findings") or []);
                for f in fnds {
                    if str(f.get("severity")) == "error" { print("  [error] " + str(f.get("message"))); }
                }
                for f in fnds {
                    if str(f.get("severity")) != "error" { print("  [" + str(f.get("severity")) + "] " + str(f.get("message"))); }
                }
                for pv in list(r.get("par") or []) { print("  (par) " + str(pv)); }
                for wn in list(r.get("warnings") or []) { print("  (warn) " + str(wn)); }
                if r["eject"] {
                    print("ejected runnable: " + str(r["eject"]));
                    print("  run it:  ./" + str(r["eject"]) + " \"<task>\"    (SIGIL_MODEL=... to pick the model)");
                }
            }
        }
    } elif cmd == "lint" {
        # lint <SKILL.md> [--fix] — the SKILL LINTER standalone: the same spec
        # extraction a compile runs, reported as authoring findings with
        # suggested edits. --fix (interactive) reviews and applies them one by
        # one, exactly like the compile-time gate — without compiling anything.
        path = _arg(argv, 1);
        if (not path) or path.startswith("-") {
            print("usage: lint <SKILL.md> [--fix]");
        } else {
            fix = False;
            j = 2;
            while j < len(argv) {
                if _arg(argv, j) == "--fix" { fix = True; }
                j += 1;
            }
            path = user_path(path);
            _lstdin = False;
            try { _lstdin = bool(sys.stdin.isatty()); } except Exception {  }
            src_text = open(path).read();
            if fix and _lstdin {
                _lint_review_tui(path, src_text);
            } else {
                if fix { print("  (note: --fix needs an interactive terminal; printing the report instead)"); }
                lr = lint_skill(src_text);
                lfs = list(lr["findings"]);
                if not lfs {
                    print("lint: CLEAR — every obligation states its modal force.");
                } else {
                    print("lint: " + str(len(lfs)) + " finding(s):");
                    for f in lfs {
                        print("  ? " + str(f.rule_id) + " [" + str(f.kind) + "] \""
                              + str(f.quote).replace(chr(10), " ")[:90] + "\"");
                        print("      " + str(f.reason).replace(chr(10), " ")[:120]);
                        if f.applicable {
                            print("      - " + str(f.old).replace(chr(10), " "));
                            for m in ["do", "maybe", "dont"] {
                                if m in f.variants {
                                    print("      " + m + " -> " + str(f.variants[m]).replace(chr(10), " "));
                                }
                            }
                        } else {
                            print("      (no safe suggestion — edit by hand or answer via compile --clarify)");
                        }
                    }
                    print("re-run `sigil lint " + path + " --fix` in a terminal to apply fixes interactively.");
                }
            }
        }
    } elif cmd == "mcp-serve" {
        # mcp-serve — expose this agent's compiled skills to any MCP client (a
        # Claude Code session, most usefully) as one tool per skill:
        #   claude mcp add sigil -- sigil mcp-serve
        # Sigil's own functions are passed in so the server module stays free of
        # graph imports. Nothing may print to stdout past this point — serve_stdio
        # owns it as the wire.
        import from src.sigil_mcp_serve { serve_stdio }
        sys.exit(serve_stdio(library, run_task, solve_task));
    } elif cmd == "gate" {
        # gate <file.agir> [name] — run G4 (the compile oracle) + G9-TY (typed-
        # dataflow unification) over one AG-IR and exit nonzero if either fails.
        # This is the compiler's own ground truth exposed as a command, so
        # anything outside the process (a repair agent, a CI step, a human
        # iterating on a hand-written IR) can check an IR the same way the
        # pipeline does.
        irp = _arg(argv, 1);
        if not irp {
            print("usage: gate <file.agir> [name]");
        } else {
            import from src.compiler.ai.gates { compile_gate, gate_type_unification }
            with open(user_path(irp)) as f { ir_src = f.read(); }
            gname = _arg(argv, 2) if len(argv) > 2 else os.path.splitext(os.path.basename(irp))[0];
            gv = compile_gate(ir_src, gname);
            if not gv.ok {
                print("gate: FAILED");
                print(gv.errors);
                sys.exit(1);
            }
            g9 = gate_type_unification(ir_src);
            if g9 {
                print("gate: FAILED  (G4 ok, G9-TY found " + str(len(g9)) + " issue(s))");
                for i9 in g9 { print("  - " + str(i9)); }
                sys.exit(1);
            }
            print("gate: ok  (" + str(len(gv.module_src.splitlines())) + " lines lowered)");
        }
    } elif cmd == "channel" {
        sub = _arg(argv, 1);
        if sub == "add" { r = channel_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5) if len(argv) > 5 else "per-peer"); print("channel '" + str(r["name"]) + "' [" + str(r["kind"]) + "]"); }
        elif sub == "list" {
            for c in channel_list() {
                live = "connected" if bridge_running(str(c["name"])) else "no bridge";
                print("  " + str(c["name"]) + "  [" + str(c["kind"]) + "]  "
                      + ("on" if c["enabled"] else "off") + "  msgs=" + str(c["messages"])
                      + "  " + live);
            }
        }
        elif sub == "rm" { print(channel_remove(_arg(argv, 2))); }
        elif sub == "send" {
            r = message_send(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5));
            state = "delivered" if r.get("delivered") else "recorded but NOT delivered";
            print("sent to " + str(r["peer"]) + " on " + str(r["channel"]) + "  mid=" + str(r["mid"])
                  + "  [" + state + "]");
            if r.get("delivery_error") { print("  " + str(r["delivery_error"])); }
            if r.get("note") { print("  " + str(r["note"])); }
        }
        elif sub == "inbound" {
            # The seam every bridge uses: one message in, one reply out, in a
            # FRESH process so the answer comes from the current graph. The
            # marker is how the bridge finds the reply in the output.
            r = inbound(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5));
            print(REPLY_MARKER);
            print(str(r["reply"]));
        }
        elif sub == "run" {
            # channel run <name> [port] — this channel's transport, foreground
            nm = _arg(argv, 2);
            if not nm { print("usage: channel run <name> [port]"); }
            else {
                r = bridge_run(nm, _to_int(_arg(argv, 3), 0));
                if not r["ok"] { print("xx " + str(r["error"]), file=sys.stderr); sys.exit(1); }
            }
        }
        elif sub == "setup" {
            # channel setup <discord|telegram|whatsapp|slack> — print connection guidance
            k = _arg(argv, 2);
            if not k { print("supported: " + ", ".join(channel_kinds())); print("usage: channel setup <" + "|".join(channel_kinds()) + ">"); }
            else { print(channel_setup_guide(k)); }
        }
        elif sub == "connect" {
            # channel connect <name> <kind> — register the Channel node + token SecretRef, then print next steps
            nm = _arg(argv, 2); k = _arg(argv, 3) if _arg(argv, 3) else _arg(argv, 2);
            if not nm { print("usage: channel connect <name> <discord|telegram|whatsapp|slack>"); }
            else {
                r = channel_bootstrap(nm, k, "");
                print("connected channel '" + str(r["name"]) + "'  kind=" + str(r["kind"]) + "  token-env=" + str(r["token_env"]) + " (set=" + str(r["token_set"]) + ")");
                print("inbound endpoint: " + str(r["endpoint"]));
                print("");
                print(str(r["guide"]));
            }
        }
        elif sub == "react" { print(react(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4))); }
        elif sub == "edit" { print(edit(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4))); }
        elif sub == "history" {
            for m in channel_history(_arg(argv, 2), 20) {
                rx = list(m["reactions"]);
                line = "  " + str(m["mid"]) + "  " + str(m["dir"]) + "  " + str(m["peer"]);
                if m["thread"] { line += "  thread=" + str(m["thread"]); }
                if m["edited"] { line += "  (edited)"; }
                if rx { line += "  reacts=" + ",".join([str(x) for x in rx]); }
                print(line + "  " + str(m["text"]));
            }
        }
        else { print("usage: channel add|list|rm|send|inbound|run <name>|setup <kind>|connect <name> <kind>|react <ch> <mid> <emoji>|edit <ch> <mid> <text>|history <ch>"); }
    } elif cmd == "hook" {
        sub = _arg(argv, 1);
        if sub == "add" { r = hook_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5)); print("hook '" + str(r["name"]) + "'"); }
        elif sub == "list" { for h in hook_list() { print("  " + str(h["name"]) + "  @" + str(h["event"]) + "  [" + str(h["kind"]) + "]  " + ("on" if h["enabled"] else "off") + "  fired=" + str(h["fired"])); } }
        elif sub == "enable" { print(hook_enable(_arg(argv, 2), True)); }
        elif sub == "disable" { print(hook_enable(_arg(argv, 2), False)); }
        elif sub == "rm" { print(hook_remove(_arg(argv, 2))); }
        else { print("usage: hook add|list|enable|disable|rm ..."); }
    } elif cmd == "approvals" {
        sub = _arg(argv, 1);
        if sub == "get" { g = approvals_get(); print("security=" + str(g["security"]) + " ask=" + str(g["ask"]) + "  elevated=" + ("yes (" + str(int(int(g["elevated_ms_left"]) / 60000)) + "m left)" if g["elevated"] else "no")); print("allowlist: " + ", ".join([str(x) for x in list(g["allowlist"])])); print("pending: " + str(len(list(g["pending"])))); }
        elif sub == "set" { print(approvals_set(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "allow" { print(allowlist_add(_arg(argv, 2))); }
        elif sub == "check" { print(check_exec(_arg(argv, 2))["decision"]); }
        elif sub == "approve" { print(approve(_arg(argv, 2), _arg(argv, 3) if len(argv) > 3 else "allow-once")); }
        elif sub == "elevate" { print(approvals_elevate(int(_arg(argv, 2)) if _arg(argv, 2) else 15)); }
        elif sub == "deescalate" { print(approvals_deescalate()); }
        elif sub == "audit" { a = elevated_audit(); if not a { print("(no elevated allows recorded)"); } for e in a { print("  " + str(e["cmd"])); } }
        elif sub == "pending" {
            pend = approvals_pending();
            if not pend { print("(nothing waiting on you)"); }
            for a in pend {
                print("  " + human_secs(int(a["age_s"])) + " ago  " + str(a["cmd"])[:100]);
            }
            if pend {
                print("   approve one with: sigil approvals approve \"<cmd-prefix>\" allow-always");
                if daemon_running() {
                    # A blocked command in a background run is not a hang — it
                    # ran, was refused, and said so. Point at the reason.
                    print("   (the daemon is running: nothing headless can answer these, so a"
                          + " blocked command is reported as BLOCKED and the job moves on)");
                }
            }
        }
        elif sub == "clear" { print(approvals_clear()); }
        else { print("usage: approvals get|pending|clear|set <sec> <ask>|allow <pattern>|check <cmd>|approve <cmd> <decision>|elevate <min>|deescalate|audit"); }
    } elif cmd == "tasks" {
        # tasks list [n] | show <n>  — unified ledger over solve Attempts + cron runs
        sub = _arg(argv, 1);
        if sub == "show" {
            n = int(_arg(argv, 2)) if _arg(argv, 2) else 0;
            r = tasks_show(n);
            if not r { print("no such task (try: tasks list)"); }
            else {
                print("#" + str(n) + "  [" + str(r["kind"]) + "]  " + str(r["label"]) + "  " + ("ok" if r["ok"] else "err"));
                print("  when   : " + str(r["at_ms"]));
                print("  model  : " + str(r["model"]));
                print("  task   : " + str(r["detail"]));
                print("  summary: " + str(r["summary"]));
            }
        } else {
            n = int(_arg(argv, 2)) if (sub == "list" and _arg(argv, 2)) else 20;
            items = tasks_list(n);
            if not items { print("(no task history yet)"); }
            i = 1;
            for r in items {
                oneline = str(r["summary"]).replace(chr(10), " ").replace(chr(13), " ");
                print("  " + str(i).rjust(3) + "  [" + str(r["kind"]) + "]  " + str(r["label"]).ljust(16)
                      + "  " + ("ok " if r["ok"] else "err") + "  " + oneline[:70]);
                i += 1;
            }
        }
    } elif cmd == "secret" {
        # secret add <name> <ENV_VAR> | list | rm <name> | test <name>   (values are never printed)
        sub = _arg(argv, 1);
        if sub == "add" { print(secret_add(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "rm" { print(secret_remove(_arg(argv, 2))); }
        elif sub == "test" { t = secret_test(_arg(argv, 2)); print("resolvable=" + str(t["resolvable"]) + "  length=" + str(t["length"]) + "  redacted='" + str(t["redacted"]) + "'"); }
        elif (sub == "list") or (not sub) {
            sl = secret_list();
            if not sl { print("(no secrets registered)"); }
            for s in sl { print("  " + str(s["name"]) + " -> $" + str(s["env"]) + "  [" + ("set" if s["set"] else "unset") + "]"); }
        }
        else { print("usage: secret add <name> <ENV_VAR>|list|rm <name>|test <name>"); }
    } elif cmd == "plugin" {
        # plugin install <openclaw.plugin.json> | list | rm <name>
        sub = _arg(argv, 1);
        if sub == "install" {
            if not _arg(argv, 2) { print("usage: plugin install <openclaw.plugin.json>"); }
            else { r = plugin_install(user_path(_arg(argv, 2))); print("installed '" + str(r["name"]) + "'  servers=" + str(len(list(r["servers"]))) + " skills=" + str(len(list(r["skills"])))); }
        }
        elif sub == "rm" { print(plugin_remove(_arg(argv, 2))); }
        elif (sub == "list") or (not sub) {
            pl = plugin_list();
            if not pl { print("(no plugins installed)"); }
            for p in pl { print("  " + str(p["name"]) + " v" + str(p["version"]) + "  servers=[" + ",".join([str(x) for x in list(p["servers"])]) + "]  skills=[" + ",".join([str(x) for x in list(p["skills"])]) + "]"); }
        }
        else { print("usage: plugin install <openclaw.plugin.json>|list|rm <name>"); }
    } elif cmd == "migrate" {
        # migrate openclaw <dir>  — fold an OpenClaw export (SOUL.md + config + skills) onto the graph
        sub = _arg(argv, 1); path = _arg(argv, 2);
        if (sub == "openclaw") and path {
            r = migrate_openclaw(user_path(path));
            print("migrated: persona=" + str(r["persona"]) + "  ethos+=" + str(r["ethos"])
                  + "  channels+=" + str(r["channels"]) + "  models=" + str(r["models"]) + "  skills+=" + str(r["skills"]));
        }
        else { print("usage: migrate openclaw <dir>"); }
    } elif cmd == "tools" {
        # tools policy | check <name> | group <name> <t1,t2,...>   (allow/deny via `configure tool_allow|tool_deny|tool_profile`)
        sub = _arg(argv, 1);
        if sub == "check" { print(_arg(argv, 2) + ": " + ("allowed" if tool_allowed(_arg(argv, 2)) else "DENIED")); }
        elif sub == "group" { print(tool_group_set(_arg(argv, 2), _arg(argv, 3))); }
        elif (sub == "policy") or (not sub) {
            p = tools_policy_info();
            print("allow    : " + (", ".join([str(x) for x in list(p["allow"])]) or "(any)"));
            print("deny     : " + (", ".join([str(x) for x in list(p["deny"])]) or "(none)"));
            print("profile  : " + (str(p["profile"]) or "(none)"));
            gr = dict(p["groups"]);
            if gr { print("groups   :"); for (k, v) in gr.items() { print("  " + str(k) + " = " + str(v)); } }
            print("effective allow: " + (", ".join([str(x) for x in list(p["effective_allow"])]) or "(any)"));
            print("effective deny : " + (", ".join([str(x) for x in list(p["effective_deny"])]) or "(none)"));
        }
        else { print("usage: tools policy|check <name>|group <name> <t1,t2,...>   (set allow/deny via configure tool_allow|tool_deny|tool_profile)"); }
    } elif cmd == "session" {
        # session note <ch> <peer> <role> <text> | show <ch> <peer> | reset <ch> <peer> | list
        sub = _arg(argv, 1);
        if sub == "note" { print(session_note(_arg(argv, 2), _arg(argv, 3), "per-peer", _arg(argv, 4), _arg(argv, 5))); }
        elif sub == "show" {
            ts = session_show(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4) or "per-peer");
            if not ts { print("(empty transcript)"); }
            for t in ts { print("  " + str(t["role"]) + ": " + str(t["text"])); }
        }
        elif sub == "reset" { print(session_reset(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4) or "per-peer")); }
        elif (sub == "list") or (not sub) {
            sl = session_list();
            if not sl { print("(no sessions)"); }
            for s in sl { print("  " + str(s["key"]) + "  day=" + str(s["day"]) + "  turns=" + str(s["turns"])); }
        }
        else { print("usage: session note <ch> <peer> <role> <text>|show <ch> <peer>|reset <ch> <peer>|list"); }
    } elif cmd == "chat" {
        import from src.sigil_chat { chat_repl }
        # ^C between turns (banner, prompt teardown) exits quietly, never a traceback
        try { chat_repl(); }
        except KeyboardInterrupt { print(); }
    } elif cmd == "setup" {
        import from src.sigil_chat { setup_wizard }
        setup_wizard();
    } elif cmd == "config" {
        # `config` alone -> interactive editor; `config <key> <value>` -> set one key.
        key = _arg(argv, 1); val = _arg(argv, 2);
        if key and val { print(configure(key, val)); }
        else {
            import from src.sigil_chat { config_menu }
            config_menu();
        }
    } else {
        print("Sigil — the skill compiler. Compile a SKILL.md into a runnable agent;");
        print("                            skills, config & memory all live on one graph.");
        print("");
        print("compile & run skills");
        print("  compile <SKILL.md> [-e|--eject [out.jac]] [--agent]   gated compile onto the graph; -e ejects a standalone runnable .jac");
        print("  lint <SKILL.md> [--fix]             the skill linter: authoring findings + suggested edits; --fix reviews & applies them one by one");
        print("  register-skill <path> [md|agir|osp] add a skill (SKILL.md runs the same compiler as `compile` / hand-authored AG-IR / precompiled OSP)");
        print("  solve \"<task>\" [skill]              route a task: run a compiled skill (HIT), compile a new one (MISS), or adapt one (PARTIAL)");
        print("  library                             list compiled skills, with run stats");
        print("  eval <sig> [probe]                  grounded-eval a skill — run it and judge the artifact");
        print("  relearn <sig> [hint]                recompile a skill fresh through the main compiler (task-born skills re-author via frontier)");
        print("  forget <sig>                        remove a skill entirely (all versions + files)");
        print("  gate <file.agir> [name]             run G4 (compile oracle) + G9-TY (type unification) on one AG-IR (exits nonzero if either fails)");
        print("");
        print("claude code (no API key — uses your claude CLI)");
        print("  --claude                            global flag: run EVERY model tier on your Claude Code CLI");
        print("  --claude compile <SKILL.md> --agent   let a Claude Code session author the AG-IR against the oracle");
        print("  mcp-serve                           serve compiled skills to Claude Code as tools:");
        print("                                        claude mcp add sigil -- sigil mcp-serve");
        print("");
        print("use it");
        print("  chat                                conversational tool-using REPL — the whole agent from one conversation");
        print("  serve [port]                        REST API + Observatory web UI on the CLI's graph (alias: observatory; own port 8199, claimed strictly — never falls back)");
        print("  channel setup <kind>                how to connect discord|telegram|whatsapp|slack");
        print("  channel connect <name> <kind>       register a channel + its token secret, print next steps");
        print("");
        print("identity & config");
        print("  setup                               first-run wizard (models & persona)");
        print("  soul                                show identity, config, skills & memory (all graph state)");
        print("  config [<key> <value>]              interactive settings editor (or set one key)");
        print("  configure <key> <value>             set config on the graph (persona|*_model|workspace|sandbox|verbose|add_ethos|add_channel|auto_eval|eval_threshold|prompt_mode)");
        print("  models list|set|alias|fallback      manage model tiers, aliases & fallback pools");
        print("");
        print("memory");
        print("  teach \"<fact>\"                      write a durable memory onto the graph");
        print("  recall \"<query>\"                    retrieve relevant memories");
        print("");
        print("automation & background");
        print("  cron add|list|show|runs|rm|enable|disable|tick   schedule work the agent runs later");
        print("  tasks list [n] | show <n>           background task ledger (solve runs + cron fires)");
        print("  session note|show|reset|list        per-channel conversation transcripts");
        print("");
        print("tools, MCP & safety");
        print("  add-mcp <name> <transport> <cmd-or-url> [args...]   register a BYO MCP server");
        print("  remove-mcp <name>                   unregister an MCP server");
        print("  mcp                                 list registered MCP servers + their tools");
        print("  tools policy|check <name>|group ... tool allow/deny/group policy (set via configure tool_allow|tool_deny|tool_profile)");
        print("  approvals get|set|allow|check|approve|elevate|deescalate|audit   the shell-exec approval gate");
        print("  secret add <name> <ENV_VAR>|list|rm|test        env-backed secrets (values never printed)");
        print("  hook add|list|enable|disable|rm     lifecycle hooks (before/after solve, message received, …)");
        print("");
        print("reference & import");
        print("  docs [<topic>]                      Sigil's own reference (how it works, config, tools)");
        print("  plugin install <file>|list|rm       install an openclaw.plugin.json manifest");
        print("  migrate openclaw <dir>              fold an OpenClaw export (SOUL.md + config + skills) onto the graph");
        print("");
        print("  (the graph persists in .jac/data/sigil.db across runs — CLI and server share it)");
    }
}
