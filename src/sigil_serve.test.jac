# Tests for sigil_serve — annex of sigil_serve.jac (`jac test sigil_serve.jac`).
# No server is started here: what is asserted is the decisions made BEFORE a
# spawn, which is where a mistake would be expensive (a ~25s web-client build
# kicked off by a command that should have declined, or a deliberate stop
# undone by the next thing anyone types).

# --- autostart ------------------------------------------------------------
# Same contract as the scheduler's: the Observatory comes up behind the scenes,
# but a deliberate `serve stop` keeps it down and nothing here ever blocks on a
# ~25s web-client build.

test "a deliberate serve stop sticks, and an explicit start lifts it" {
    # Own run dir, for the same reason as the scheduler's twin in
    # sigil_daemon.test.jac: the pidfile check runs first, so against the real
    # $SIGIL_HOME this reads "already running" on any machine whose Observatory
    # is up — which, since autostart, is any machine sigil has been used on.
    import os;
    import tempfile;
    prev = os.environ.get("SIGIL_HOME") or "";
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp(prefix="sigil-serve-test-");
    clear_serve_stopped();
    assert serve_optout() == False;
    mark_serve_stopped();
    assert serve_optout() == True;
    r = ensure_server();
    assert r["started"] == False;
    assert r["reason"] == "stopped deliberately";
    clear_serve_stopped();
    assert serve_optout() == False;
    if prev { os.environ["SIGIL_HOME"] = prev; } else { del os.environ["SIGIL_HOME"]; }
}

test "SIGIL_NO_SERVE and api children decline before anything is spawned" {
    import os;
    clear_serve_stopped();
    for (var, why) in [("SIGIL_NO_SERVE", "SIGIL_NO_SERVE"), ("SIGIL_API_CHILD", "api child")] {
        prev = os.environ.get(var) or "";
        os.environ[var] = "1";
        r = ensure_server();
        assert r["started"] == False, var;
        assert r["reason"] == why, str(r);
        if prev { os.environ[var] = prev; } else { del os.environ[var]; }
    }
}

test "a freshly spawned supervisor reads as starting, not as down" {
    # It needs several seconds of imports before it claims the pidfile — longer
    # than any wait an interactive command should impose — so the report has to
    # treat a recent attempt as COMING UP or it calls a server it just started
    # "not running".
    import os;
    try { os.remove(_serve_attempt_path()); } except Exception as e { }
    assert serve_starting() == False;
    import time;
    Path(_serve_attempt_path()).write_text(str(int(time.time() * 1000)));
    assert serve_starting() == True;
    try { os.remove(_serve_attempt_path()); } except Exception as e2 { }
}


test "work the daemon fired never starts an Observatory of its own" {
    # The other half of the duplicate-supervisor regression: see the matching
    # test in sigil_daemon.test.jac for how two servers ended up on port 8199.
    import os;
    clear_serve_stopped();
    prev = os.environ.get("SIGIL_CHILD") or "";
    os.environ["SIGIL_CHILD"] = "1";
    r = ensure_server();
    assert r["started"] == False;
    assert r["reason"] == "internal child";
    if prev { os.environ["SIGIL_CHILD"] = prev; } else { del os.environ["SIGIL_CHILD"]; }
}
