"""The Sigil daemon — the part that keeps working once you close the TUI.

Sigil's scheduler, and later its channel bridges, need a process that outlives a
command. This module is that process and the controls around it:

    sigil daemon start | stop | restart | status | logs | run
    sigil daemon install | uninstall        # launchd (macOS) / systemd (Linux)

`run` is the supervisor loop itself and blocks; `start` spawns it detached and
returns. Everything else inspects or signals it through the pidfile under
`$SIGIL_HOME/run`.

Two decisions worth stating, because both were forced by measurement rather than
taste:

**The daemon is a `jac run` process, not a `jac start` server.** A server puts
scheduled work on its own system-user root — a different graph from the one the
CLI writes to. `allroots()` from inside a server lists a zeros root it cannot
read, and `jobj()` on the CLI's root returns None. A server-hosted scheduler
would tick an empty Soul forever, which is indistinguishable from the bug this
exists to fix.

**Each unit of work runs in a fresh subprocess.** A long-lived jac process serves
the graph it loaded at startup, so a supervisor that did the work in-process
would never see anything added after it booted. The loop supervises; the
subprocesses do the work and see the current graph.
"""

import os;
import sys;
import json;
import time;
import signal;
import platform;
import subprocess;
import from pathlib { Path }
import from .sigil_runtime {
    sigil_home, run_dir, pid_path, read_pid, pid_alive, write_pidfile,
    clear_pidfile, process_running, project_root, entry_script, _jac_bin
}
import from .cron { tick_isolated, next_due_ms, cron_list, cron_daemon_running }
import from .channels { channel_list as cron_channel_list }
import from .sigil_bridge { bridge_running, channel_config, running_bridges, stop_bridge }
import from .sigil_transports { supports_polling }
import from .sigil_cron { now_ms, fmt_when, human_secs }
import from .hooks { fire_hooks }

glob DAEMON_PID: str = "daemon";        # pidfile name under $SIGIL_HOME/run
glob SERVICE_LABEL: str = "com.sigilagent.sigil";
glob _STOP: dict = {"now": False};
glob _WARNED: dict[str, bool] = {};   # channels already reported as unconfigured

# ---------------------------------------------------------------------------
# Where the daemon leaves its traces
# ---------------------------------------------------------------------------
def log_dir() -> str {
    d = os.path.join(sigil_home(), "log");
    try {
        Path(d).mkdir(parents=True, exist_ok=True);
    } except Exception as e {
        return d;
    }
    return d;
}

def log_path() -> str {
    return os.path.join(log_dir(), "daemon.log");
}

def state_path() -> str {
    return os.path.join(run_dir(), "daemon.json");
}

def graph_path() -> str {
    # The store the CLI and the daemon share. jac resolves it relative to the
    # working directory, which is why every entry path pins cwd to the project.
    return os.path.join(project_root(), ".jac", "data", "sigil.db");
}

def _write_state(interval_s: int) -> None {
    try {
        Path(state_path()).write_text(json.dumps({
            "pid": os.getpid(), "started_ms": now_ms(),
            "interval_s": interval_s, "graph": graph_path()
        }));
    } except Exception as e {
        return None;
    }
    return None;
}

def _read_state() -> dict {
    p = Path(state_path());
    if not p.exists() { return {}; }
    try {
        return dict(json.loads(p.read_text() or "{}"));
    } except Exception as e {
        return {};
    }
}

def _clear_state() -> None {
    try {
        p = Path(state_path());
        if p.exists() { p.unlink(); }
    } except Exception as e {
        return None;
    }
    return None;
}

def _log(msg: str) -> None {
    # The daemon's stdout IS its log file (start redirects it). Timestamp every
    # line: a scheduler log without times cannot answer "did it run at 9am".
    stamp = time.strftime("%Y-%m-%d %H:%M:%S");
    print(stamp + "  " + str(msg), flush=True);
    return None;
}

# ---------------------------------------------------------------------------
# The supervisor loop
# ---------------------------------------------------------------------------
def _stop_signal(signum: int, frame: any) -> None {
    _STOP["now"] = True;
    return None;
}

def _install_stop_handlers() -> None {
    try {
        signal.signal(int(signal.SIGTERM), _stop_signal);
        signal.signal(int(signal.SIGINT), _stop_signal);
    } except Exception as e {
        return None;   # not the main thread; the caller owns shutdown
    }
    return None;
}

def _nap(seconds: int) -> None {
    # Sliced so a stop signal lands in about a second. PEP 475 resumes an
    # interrupted sleep, so slicing is what makes shutdown prompt.
    left = seconds;
    while (left > 0) and (not _STOP["now"]) {
        time.sleep(1 if left > 1 else left);
        left -= 1;
    }
    return None;
}

def wanted_bridges() -> list[dict] {
    # Every enabled channel that has a transport worth holding open. A `cli`
    # channel has no wire; a channel whose token env is unset would spin on
    # startup failures, so it is reported rather than launched.
    out: list[dict] = [];
    for c in cron_channel_list() {
        name = str(c["name"]);
        kind = str(c["kind"]);
        if not c["enabled"] { continue; }
        if kind in ["cli", ""] { continue; }
        cfg = channel_config(name);
        if supports_polling(kind) and (not cfg["token"]) {
            out.append({"name": name, "kind": kind, "ready": False,
                        "why": "its token env var is unset"});
            continue;
        }
        out.append({"name": name, "kind": kind, "ready": True, "why": ""});
    }
    return out;
}

def _spawn_bridge(name: str) -> bool {
    argv = [_jac_bin(), "run", entry_script(), "--", "channel", "run", name];
    try {
        handle = open(log_path(), "a");
        subprocess.Popen(argv, cwd=project_root(), stdout=handle, stderr=handle,
                         stdin=subprocess.DEVNULL, start_new_session=True);
    } except Exception as e {
        _log("could not start bridge for '" + name + "': " + str(e)[:200]);
        return False;
    }
    return True;
}

def _supervise_children() -> None {
    # Keep a bridge running for every channel that wants one. A bridge that died
    # — provider outage, a crash, a kill — comes back on the next tick, which is
    # the difference between "connected" and "connected until something happened".
    for b in wanted_bridges() {
        name = str(b["name"]);
        if not b["ready"] {
            if not _WARNED.get(name) {
                _log("channel '" + name + "' has no bridge: " + str(b["why"]));
                _WARNED[name] = True;   # once, not every tick
            }
            continue;
        }
        _WARNED[name] = False;
        if bridge_running(name) { continue; }
        if _spawn_bridge(name) { _log("started bridge for channel '" + name + "'"); }
    }
    return None;
}

def daemon_run(interval_s: int = 30, max_ticks: int = 0) -> dict {
    # The supervisor. Blocks. `sigil daemon start` runs this detached.
    _STOP["now"] = False;
    _install_stop_handlers();
    write_pidfile(DAEMON_PID);
    _write_state(interval_s);
    _log("sigil daemon up — pid " + str(os.getpid()) + ", tick " + str(interval_s)
         + "s, graph " + graph_path());
    # `gateway_start` has been a declared hook event with no call site since
    # hooks shipped. The daemon coming up IS the gateway starting.
    try { fire_hooks("gateway_start", "daemon pid " + str(os.getpid())); }
    except Exception as _hkerr { _log("gateway_start hooks failed: " + str(_hkerr)[:160]); }
    ticks = 0;
    try {
        while not _STOP["now"] {
            try {
                _supervise_children();
                res = tick_isolated();
                if not res["ok"] {
                    _log("tick failed: " + str(res["err"])[:300]);
                } else {
                    for line in str(res["out"]).splitlines() {
                        s = line.strip();
                        if s.startswith("tick: ") or s.startswith("  ") { _log(s); }
                    }
                }
            } except Exception as e {
                _log("supervisor error: " + str(e)[:300]);
            }
            ticks += 1;
            if (max_ticks > 0) and (ticks >= max_ticks) { break; }
            _nap(interval_s if interval_s > 0 else 30);
        }
    } except KeyboardInterrupt as e {
        _STOP["now"] = True;
    } finally {
        # Take the bridges with it. A supervisor that exits and leaves its
        # children holding provider connections is how you get two bots
        # answering the same message after a restart.
        for chan in running_bridges() {
            if stop_bridge(chan) { _log("stopped bridge for channel '" + chan + "'"); }
        }
        clear_pidfile(DAEMON_PID);
        _clear_state();
        _log("sigil daemon stopped");
    }
    return {"ticks": ticks};
}

# ---------------------------------------------------------------------------
# Controls
# ---------------------------------------------------------------------------
def daemon_running() -> bool {
    return process_running(DAEMON_PID);
}

def scheduler_running() -> bool {
    # Either way of ticking counts. The question every caller actually asks is
    # "will my job fire?", not "which process is holding the loop?".
    return daemon_running() or cron_daemon_running();
}

def daemon_start(interval_s: int = 30) -> dict {
    if daemon_running() {
        return {"ok": False, "error": "already running (pid " + str(read_pid(DAEMON_PID)) + ")"};
    }
    argv = [_jac_bin(), "run", entry_script(), "--", "daemon", "run", str(interval_s)];
    try {
        handle = open(log_path(), "a");
    } except Exception as e {
        return {"ok": False, "error": "cannot open log " + log_path() + ": " + str(e)[:120]};
    }
    try {
        # start_new_session detaches it from this terminal's process group, so
        # closing the shell (or the TUI) does not take the scheduler with it —
        # which is the entire point.
        proc = subprocess.Popen(argv, cwd=project_root(), stdout=handle, stderr=handle,
                                stdin=subprocess.DEVNULL, start_new_session=True);
    } except Exception as ex {
        return {"ok": False, "error": "could not spawn: " + str(ex)[:200]};
    }
    # The child writes the pidfile; confirm it actually came up rather than
    # reporting success at a process that died on import.
    waited = 0.0;
    while waited < 30.0 {
        if daemon_running() {
            return {"ok": True, "pid": read_pid(DAEMON_PID), "log": log_path(),
                    "graph": graph_path(), "interval_s": interval_s};
        }
        if proc.poll() is not None {
            return {"ok": False, "error": "daemon exited immediately (rc="
                    + str(proc.returncode) + ") — see " + log_path()};
        }
        time.sleep(0.5);
        waited += 0.5;
    }
    return {"ok": False, "error": "daemon did not report ready in 30s — see " + log_path()};
}

def daemon_stop(timeout_s: int = 30) -> dict {
    pid = read_pid(DAEMON_PID);
    if (pid <= 0) or (not pid_alive(pid)) {
        clear_pidfile(DAEMON_PID);
        _clear_state();
        return {"ok": False, "error": "not running"};
    }
    try {
        os.kill(pid, int(signal.SIGTERM));
    } except Exception as e {
        return {"ok": False, "error": "could not signal pid " + str(pid) + ": " + str(e)[:120]};
    }
    waited = 0.0;
    while waited < timeout_s {
        if not pid_alive(pid) {
            clear_pidfile(DAEMON_PID);
            _clear_state();
            return {"ok": True, "pid": pid};
        }
        time.sleep(0.5);
        waited += 0.5;
    }
    # A tick that is mid-solve can legitimately outlast the grace period. Say so
    # instead of escalating to SIGKILL behind the operator's back.
    return {"ok": False, "error": "pid " + str(pid) + " still running after "
            + str(timeout_s) + "s (a job may be mid-run) — `kill -9 " + str(pid) + "` to force"};
}

def daemon_status() -> dict {
    running = daemon_running();
    st = _read_state();
    jobs = cron_list();
    armed = len([j for j in jobs if j["enabled"] and (int(j["next_run_ms"]) > 0)]);
    out = {
        "running": running,
        "pid": read_pid(DAEMON_PID) if running else 0,
        "graph": graph_path(),
        "log": log_path(),
        "jobs": len(jobs),
        "armed": armed,
        "next_due_ms": next_due_ms(),
        "interval_s": int(st.get("interval_s", 0)) if st else 0,
        "uptime_s": 0,
        "service": service_status(),
        "bridges": running_bridges(),
        "channels": [b["name"] for b in wanted_bridges() if b["ready"]]
    };
    if running and st.get("started_ms") {
        out["uptime_s"] = int((now_ms() - int(st["started_ms"])) / 1000);
    }
    return out;
}

def daemon_logs(n: int = 40) -> str {
    p = Path(log_path());
    if not p.exists() { return "(no daemon log yet at " + log_path() + ")"; }
    try {
        lines = p.read_text(errors="replace").splitlines();
    } except Exception as e {
        return "(could not read " + log_path() + ": " + str(e)[:120] + ")";
    }
    return "\n".join(lines[-n:]) if lines else "(daemon log is empty)";
}

# ---------------------------------------------------------------------------
# OS service integration — start at login, restart on crash
# ---------------------------------------------------------------------------
def _launcher() -> str {
    # Prefer the `sigil` wrapper next to the project; it pins cwd and PATH the
    # same way an interactive run does. Fall back to the jac binary directly.
    cand = os.path.join(project_root(), "sigil");
    if os.path.exists(cand) { return cand; }
    return _jac_bin();
}

def _is_mac() -> bool {
    return platform.system() == "Darwin";
}

def plist_path() -> str {
    return os.path.expanduser("~/Library/LaunchAgents/" + SERVICE_LABEL + ".plist");
}

def unit_path() -> str {
    return os.path.expanduser("~/.config/systemd/user/sigil.service");
}

def service_path() -> str {
    return plist_path() if _is_mac() else unit_path();
}

def service_status() -> str {
    # installed | absent — whether the OS will start the daemon at login.
    return "installed" if os.path.exists(service_path()) else "absent";
}

def _plist_body(interval_s: int) -> str {
    launcher = _launcher();
    return ('<?xml version="1.0" encoding="UTF-8"?>' + chr(10)
        + '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        + '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">' + chr(10)
        + '<plist version="1.0"><dict>' + chr(10)
        + '  <key>Label</key><string>' + SERVICE_LABEL + '</string>' + chr(10)
        + '  <key>ProgramArguments</key><array>' + chr(10)
        + '    <string>' + launcher + '</string>' + chr(10)
        + '    <string>daemon</string>' + chr(10)
        + '    <string>run</string>' + chr(10)
        + '    <string>' + str(interval_s) + '</string>' + chr(10)
        + '  </array>' + chr(10)
        + '  <key>WorkingDirectory</key><string>' + project_root() + '</string>' + chr(10)
        + '  <key>RunAtLoad</key><true/>' + chr(10)
        + '  <key>KeepAlive</key><true/>' + chr(10)
        + '  <key>StandardOutPath</key><string>' + log_path() + '</string>' + chr(10)
        + '  <key>StandardErrorPath</key><string>' + log_path() + '</string>' + chr(10)
        + '</dict></plist>' + chr(10));
}

def _unit_body(interval_s: int) -> str {
    launcher = _launcher();
    return ("[Unit]" + chr(10)
        + "Description=Sigil agent daemon (scheduler and channels)" + chr(10)
        + "After=network-online.target" + chr(10) + chr(10)
        + "[Service]" + chr(10)
        + "Type=simple" + chr(10)
        + "WorkingDirectory=" + project_root() + chr(10)
        + "ExecStart=" + launcher + " daemon run " + str(interval_s) + chr(10)
        + "Restart=always" + chr(10)
        + "RestartSec=10" + chr(10)
        + "StandardOutput=append:" + log_path() + chr(10)
        + "StandardError=append:" + log_path() + chr(10) + chr(10)
        + "[Install]" + chr(10)
        + "WantedBy=default.target" + chr(10));
}

def _run(argv: list) -> str {
    try {
        p = subprocess.run(argv, capture_output=True, text=True, timeout=60);
    } except Exception as e {
        return str(e)[:200];
    }
    return "" if p.returncode == 0 else (str(p.stderr or p.stdout or "")[:300]);
}

def service_install(interval_s: int = 30) -> dict {
    path = service_path();
    body = _plist_body(interval_s) if _is_mac() else _unit_body(interval_s);
    try {
        Path(path).parent.mkdir(parents=True, exist_ok=True);
        Path(path).write_text(body);
    } except Exception as e {
        return {"ok": False, "error": "could not write " + path + ": " + str(e)[:160]};
    }
    if _is_mac() {
        _run(["launchctl", "unload", path]);          # idempotent re-install
        err = _run(["launchctl", "load", "-w", path]);
    } else {
        _run(["systemctl", "--user", "daemon-reload"]);
        err = _run(["systemctl", "--user", "enable", "--now", "sigil.service"]);
    }
    return {"ok": not err, "path": path, "error": err,
            "manager": "launchd" if _is_mac() else "systemd"};
}

def service_uninstall() -> dict {
    path = service_path();
    if not os.path.exists(path) {
        return {"ok": False, "error": "no service installed at " + path};
    }
    if _is_mac() {
        _run(["launchctl", "unload", "-w", path]);
    } else {
        _run(["systemctl", "--user", "disable", "--now", "sigil.service"]);
    }
    try {
        Path(path).unlink();
    } except Exception as e {
        return {"ok": False, "error": "could not remove " + path + ": " + str(e)[:160]};
    }
    if not _is_mac() { _run(["systemctl", "--user", "daemon-reload"]); }
    return {"ok": True, "path": path};
}
