"""Observatory lifecycle — `serve start | stop | status | logs`.

The scheduler has been a managed service since the daemon landed: start it, stop
it, ask whether it is up. The Observatory never was. `sigil serve` occupied the
terminal until Ctrl-C, so running the web UI meant either keeping a window open
forever or reaching for `nohup … &` and `pkill -f observatory.jac` — which is
exactly the "is anything actually running?" guesswork the daemon exists to end.

This gives the server the same shape as the daemon, and reuses its mechanics:
`start` spawns the ordinary foreground `sigil serve` DETACHED (start_new_session,
output to a log file), so the supervisor that already knows how to align the
guest root and reap the jac child is unchanged — it simply is not attached to a
terminal. The prompt comes back immediately; nothing is streamed to it.

Stopping is two-stage on purpose. SIGTERM goes to the supervisor, which reaps its
own `jac start` child; then, if the port is somehow still held, the holder is
identified and signalled too. A supervisor killed with SIGKILL (or a crash) can
leave that child holding 8199, and a stale listener on the Observatory's port is
the specific failure `_claim_port` exists to prevent — so `stop` must be able to
clear it. Nothing that fails the "is this an observatory?" test is ever signalled.
"""

import os;
import time;
import signal;
import subprocess;
import from pathlib { Path }
import from .sigil_runtime {
    read_pid, write_pidfile, clear_pidfile, pid_alive, log_dir, run_dir, project_root
}

glob SERVE_PID: str = "observatory";     # pidfile name under $SIGIL_HOME/run
glob DEFAULT_PORT: str = "8199";

def serve_log_path() -> str {
    return os.path.join(log_dir(), "observatory.log");
}

def _port_owner(port: str) -> list {
    # [pid, command] of whatever LISTENs on the port, or [] if it is free.
    try {
        r = subprocess.run(["lsof", "-ti", "tcp:" + str(port), "-sTCP:LISTEN"],
                           capture_output=True, text=True, timeout=5);
        pids = [x.strip() for x in str(r.stdout or "").split() if x.strip()];
        if not pids { return []; }
        rc = subprocess.run(["ps", "-p", pids[0], "-o", "command="],
                            capture_output=True, text=True, timeout=5);
        return [pids[0], str(rc.stdout or "").strip()];
    } except Exception as e { return []; }
}

def _is_observatory(cmd: str) -> bool {
    # Only ever signal something we can positively identify as ours. Anything
    # else on the port is somebody's server and is left alone, loudly.
    c = str(cmd or "");
    return ("observatory.jac" in c) or ("-- serve" in c);
}

def serve_running() -> bool {
    pid = read_pid(SERVE_PID);
    if pid <= 0 { return False; }
    if pid_alive(pid) { return True; }
    clear_pidfile(SERVE_PID);      # a pidfile pointing at a corpse makes status lie
    return False;
}

def serve_port() -> str {
    # The port the running server claimed, recorded beside the pidfile so
    # `status` and `stop` do not have to guess when it is not the default.
    p = Path(os.path.join(run_dir(), "observatory.port"));
    try {
        if p.exists() { return str((p.read_text() or "").strip() or DEFAULT_PORT); }
    } except Exception as e { }
    return DEFAULT_PORT;
}

def _write_port(port: str) -> None {
    p = Path(os.path.join(run_dir(), "observatory.port"));
    try {
        p.write_text(str(port));
    } except Exception as e { }
    return None;
}

def mark_serving(port: str) -> None {
    # Called by the foreground supervisor itself, so `status` is honest whether
    # the server was started detached or run in a terminal.
    write_pidfile(SERVE_PID);
    _write_port(port);
    return None;
}

def unmark_serving() -> None {
    clear_pidfile(SERVE_PID);
    return None;
}

def serve_start(port: str = "", ready_timeout_s: int = 5) -> dict {
    # Spawn the ordinary foreground supervisor, detached: the prompt comes back
    # and the build output goes to the log, never to the terminal.
    #
    # The wait is short and does NOT gate success. jac re-serves the web client
    # on every boot, so "listening" is ~30s away even warm — blocking on it would
    # make `start` feel like the foreground command it exists to replace. So we
    # wait only long enough to catch the failure that matters (a process that
    # dies on import) and otherwise report honestly that it is still coming up.
    import from .sigil_runtime { _jac_bin, entry_script }
    prt = str(port or DEFAULT_PORT);
    if serve_running() {
        return {"ok": False, "error": "already running (pid " + str(read_pid(SERVE_PID))
                + ") on port " + serve_port() + " — `sigil serve stop` first"};
    }
    owner = _port_owner(prt);
    if owner {
        return {"ok": False, "error": "port " + prt + " is already in use by pid "
                + str(owner[0]) + ": " + str(owner[1])[:120]};
    }
    try {
        handle = open(serve_log_path(), "a");
    } except Exception as e {
        return {"ok": False, "error": "cannot open log " + serve_log_path() + ": " + str(e)[:120]};
    }
    argv = [_jac_bin(), "run", entry_script(), "--", "serve", prt];
    try {
        # start_new_session detaches it from this terminal's process group, so
        # closing the shell does not take the server with it, and its output
        # never lands on the prompt.
        proc = subprocess.Popen(argv, cwd=project_root(), stdout=handle, stderr=handle,
                                stdin=subprocess.DEVNULL, start_new_session=True);
    } except Exception as ex {
        return {"ok": False, "error": "could not spawn: " + str(ex)[:200]};
    }
    # Confirm it actually came up rather than reporting success at a process that
    # died on import. A cold client build is genuinely slow, hence the wide bound.
    waited = 0.0;
    while waited < float(ready_timeout_s) {
        if _port_owner(prt) {
            return {"ok": True, "pid": read_pid(SERVE_PID) or proc.pid, "port": prt,
                    "url": "http://localhost:" + prt, "log": serve_log_path()};
        }
        if proc.poll() is not None {
            return {"ok": False, "error": "the server exited immediately (rc="
                    + str(proc.returncode) + ") — see " + serve_log_path()};
        }
        time.sleep(0.5);
        waited += 0.5;
    }
    # Alive, not listening yet: the client build is still running. That is the
    # normal path, not a failure — say so rather than reporting a false error.
    return {"ok": True, "pid": read_pid(SERVE_PID) or proc.pid, "port": prt,
            "url": "http://localhost:" + prt, "log": serve_log_path(),
            "starting": True};
}

def serve_stop(timeout_s: int = 30) -> dict {
    prt = serve_port();
    pid = read_pid(SERVE_PID);
    signalled: list = [];
    # No supervisor of ours. Decide from the port alone rather than polling for
    # 30s to discover there was never anything to wait for.
    if (pid <= 0) or (not pid_alive(pid)) {
        owner = _port_owner(prt);
        if not owner {
            clear_pidfile(SERVE_PID);
            return {"ok": False, "error": "not running"};
        }
        if not _is_observatory(str(owner[1])) {
            return {"ok": False, "error": "port " + prt + " is held by pid " + str(owner[0])
                    + ", which is not a sigil observatory — leaving it alone: "
                    + str(owner[1])[:110]};
        }
        # An observatory we did not start (or lost the pidfile for): adopt and stop it.
        try { os.kill(int(owner[0]), int(signal.SIGTERM)); signalled.append(int(owner[0])); }
        except Exception as e {
            return {"ok": False, "error": "could not signal pid " + str(owner[0]) + ": " + str(e)[:120]};
        }
        pid = int(owner[0]);
    }
    if (pid > 0) and pid_alive(pid) and (pid not in signalled) {
        try { os.kill(pid, int(signal.SIGTERM)); signalled.append(pid); }
        except Exception as e {
            return {"ok": False, "error": "could not signal pid " + str(pid) + ": " + str(e)[:120]};
        }
    }
    waited = 0.0;
    while waited < float(timeout_s) {
        if (not _port_owner(prt)) and ((pid <= 0) or (not pid_alive(pid))) {
            clear_pidfile(SERVE_PID);
            return {"ok": True, "pid": pid, "port": prt};
        }
        time.sleep(0.5);
        waited += 0.5;
    }
    # The supervisor is gone but its jac child still holds the port — the orphan
    # case. Identify it before signalling; never kill an unrelated listener.
    owner = _port_owner(prt);
    if owner and _is_observatory(str(owner[1])) {
        try { os.kill(int(owner[0]), int(signal.SIGTERM)); signalled.append(int(owner[0])); }
        except Exception as e { }
        waited = 0.0;
        while waited < 10.0 {
            if not _port_owner(prt) {
                clear_pidfile(SERVE_PID);
                return {"ok": True, "pid": pid, "port": prt, "orphan": int(owner[0])};
            }
            time.sleep(0.5);
            waited += 0.5;
        }
    }
    if not signalled {
        clear_pidfile(SERVE_PID);
        return {"ok": False, "error": "not running"};
    }
    held = _port_owner(prt);
    return {"ok": False, "error": "port " + prt + " is still held after " + str(timeout_s)
            + "s by pid " + (str(held[0]) if held else "?")
            + ((" (" + str(held[1])[:100] + ")") if held else "")
            + " — `kill -9` it if you are sure"};
}

def serve_status() -> dict {
    prt = serve_port();
    owner = _port_owner(prt);
    pid = read_pid(SERVE_PID);
    running = bool(owner) or serve_running();
    out: dict = {
        "running": running,
        "pid": pid if (pid > 0) else (int(owner[0]) if owner else 0),
        "port": prt,
        "url": "http://localhost:" + prt,
        "log": serve_log_path(),
        "graph": os.path.join(project_root(), ".jac", "data", "sigil.db"),
        "owner": (str(owner[1])[:140] if owner else ""),
        # a listener we did not start (or an orphan we lost the pidfile for)
        "adopted": bool(owner) and (pid <= 0)
    };
    return out;
}

def serve_logs(n: int = 40) -> str {
    p = Path(serve_log_path());
    if not p.exists() { return "(no log yet at " + serve_log_path() + ")"; }
    try {
        lines = p.read_text(errors="replace").splitlines();
    } except Exception as e {
        return "(could not read " + serve_log_path() + ": " + str(e)[:120] + ")";
    }
    tail = lines[0 - int(n):] if (len(lines) > int(n)) else lines;
    return "\n".join(tail) if tail else "(log is empty)";
}
