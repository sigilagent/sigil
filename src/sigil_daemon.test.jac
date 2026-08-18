# Tests for sigil_daemon — annex of sigil_daemon.jac (`jac test sigil_daemon.jac`).
# No daemon is started here: what is asserted is the paths it would use and the
# service units it would write, which is where a silent mistake would hide (a
# unit pointing at the wrong directory starts a DIFFERENT agent).

import os;

test "the daemon reports the same graph the CLI uses" {
    # This asserted `sigil.db` by name and so kept passing while it was false:
    # jac keys a SUBDIRECTORY entry's store to that script's filename, and
    # sigil enters through src/main.jac, so the CLI has been writing main.db
    # since main.jac moved out of the root. The invariant is that the daemon
    # names whatever the entry script actually resolves to — not a fixed name.
    g = graph_path();
    assert g == store_path(), g;
    assert g.endswith(os.path.basename(entry_script()).replace(".jac", ".db")), g;
    assert g.startswith(project_root()), "the graph must live under the project, not the caller's cwd";
}

test "state, logs and pidfiles live under SIGIL_HOME" {
    assert log_path().startswith(sigil_home());
    assert state_path().startswith(sigil_home());
    assert log_path().endswith("daemon.log");
}

test "status is honest when nothing is running" {
    s = daemon_status();
    assert "running" in s;
    assert "graph" in s and str(s["graph"]) == graph_path();
    assert int(s["armed"]) >= 0;
    assert str(s["service"]) in ["installed", "absent"];
}

test "stopping a daemon that is not running is refused, not pretended" {
    if not daemon_running() {
        r = daemon_stop();
        assert not r["ok"];
        assert "not running" in str(r["error"]);
    }
}

test "the launchd plist names the label, the project dir and the log" {
    body = _plist_body(45);
    assert SERVICE_LABEL in body;
    assert "<string>daemon</string>" in body;
    assert "<string>run</string>" in body;
    assert "<string>45</string>" in body;
    # the working directory is the whole ballgame: jac resolves the graph store
    # against it, so a unit that omits it would boot a second, empty agent
    assert project_root() in body;
    assert log_path() in body;
    assert "<key>KeepAlive</key><true/>" in body;
}

test "the systemd unit restarts, pins the directory, and appends to the log" {
    body = _unit_body(45);
    assert "ExecStart=" in body;
    assert "daemon run 45" in body;
    assert ("WorkingDirectory=" + project_root()) in body;
    assert "Restart=always" in body;
    assert log_path() in body;
    assert "WantedBy=default.target" in body;
}

test "the service unit runs the launcher, which pins cwd for itself" {
    launcher = _launcher();
    assert launcher, "a service with no program to run is not a service";
    assert os.path.isabs(launcher);
}

# --- autostart ------------------------------------------------------------
# The scheduler comes up because someone used the CLI. What has to hold is that
# it stays DOWN when it was put down on purpose, and that eight terminals
# reaching this at once produce one daemon rather than eight.

test "a deliberate stop sticks, and an explicit start lifts it" {
    clear_stopped();
    assert daemon_optout() == False;
    mark_stopped();
    assert daemon_optout() == True;
    # ensure_daemon must decline while the marker is there, and say why
    r = ensure_daemon();
    assert r["started"] == False;
    assert r["reason"] == "stopped deliberately";
    clear_stopped();
    assert daemon_optout() == False;
}

test "SIGIL_NO_DAEMON declines before anything is spawned" {
    import os;
    clear_stopped();
    prev = os.environ.get("SIGIL_NO_DAEMON") or "";
    os.environ["SIGIL_NO_DAEMON"] = "1";
    r = ensure_daemon();
    assert r["started"] == False;
    assert r["reason"] == "SIGIL_NO_DAEMON";
    if prev { os.environ["SIGIL_NO_DAEMON"] = prev; } else { del os.environ["SIGIL_NO_DAEMON"]; }
}

test "an api_call child never starts a scheduler of its own" {
    # api_call spawns one child per HTTP request; a daemon per request is not a
    # daemon. The guard is the env var the proxy already sets.
    import os;
    clear_stopped();
    prev = os.environ.get("SIGIL_API_CHILD") or "";
    os.environ["SIGIL_API_CHILD"] = "1";
    r = ensure_daemon();
    assert r["started"] == False;
    assert r["reason"] == "api child";
    if prev { os.environ["SIGIL_API_CHILD"] = prev; } else { del os.environ["SIGIL_API_CHILD"]; }
}

test "the autostart backoff stops a broken daemon costing every command a spawn" {
    _note_attempt();
    assert _backoff_ok() == False;
    import os;
    try { os.remove(_attempt_path()); } except Exception as e { }
    assert _backoff_ok() == True;
}


test "work the daemon fired never starts services of its own" {
    # Regression: the daemon runs each tick as `jac run main.jac -- cron ...`,
    # an ORDINARY command, so it took the CLI autostart and every tick spawned
    # another Observatory. One `sigil daemon start` left two supervisors racing
    # for port 8199 — and `serve stop` knows a single pidfile, so the surplus
    # could not be cleaned up. daemon_run exports SIGIL_CHILD for every child.
    import os;
    clear_stopped();
    prev = os.environ.get("SIGIL_CHILD") or "";
    os.environ["SIGIL_CHILD"] = "1";
    r = ensure_daemon();
    assert r["started"] == False;
    assert r["reason"] == "internal child";
    if prev { os.environ["SIGIL_CHILD"] = prev; } else { del os.environ["SIGIL_CHILD"]; }
}
