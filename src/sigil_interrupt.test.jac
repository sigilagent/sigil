# Tests for sigil_interrupt — annex of sigil_interrupt.jac. No model, no turn.

import tempfile;

def _stops() -> bool {
    try { interrupt_point(); } except KeyboardInterrupt as k { return True; }
    return False;
}

test "a turn asked to stop stops at its next safe point, once" {
    was = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp();
    try {
        begin_turn("web");
        assert not _stops(), "nobody asked";
        assert request_interrupt("web") == True, "the turn runs in this process";
        assert _stops();
        assert not _stops(), "one request, one stop";
        end_turn();
    } finally {
        if was is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = was; }
    }
}

test "another process asks through the turn's flag file" {
    was = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp();
    try {
        scope = channel_scope(4242);
        begin_turn(scope);
        # what the bridge does for its `channel inbound` child
        with open(flag_path(scope), "w") as f { f.write("1"); }
        time.sleep(0.3);
        assert _stops();
        assert not os.path.exists(flag_path(scope)), "the flag is consumed";
        end_turn();
        # with no turn open, a stray flag stops nothing
        with open(flag_path(scope), "w") as f2 { f2.write("1"); }
        time.sleep(0.3);
        assert not _stops();
        clear_interrupt(scope);
    } finally {
        if was is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = was; }
    }
}

test "the note an interrupted turn leaves says what was done and to carry on" {
    n = interrupted_note("Here are the first two", ["web_fetch https://news.ycombinator.com", "ws_write hn.txt"]);
    assert n.startswith("(Interrupted by the user's next message");
    assert "web_fetch https://news.ycombinator.com; ws_write hn.txt" in n;
    assert "Here are the first two" in n;
    assert "taking the new message into account" in n;
}
