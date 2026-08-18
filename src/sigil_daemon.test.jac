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
