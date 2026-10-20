# Tests for sigil_tui — annex of sigil_tui.jac (`jac test src/sigil_tui.jac`).
# Everything below runs offline and headless: no terminal, no model, no graph.
# The app itself (prompt_toolkit on the alternate screen) needs a real pty; what
# is tested here is everything it draws and every decision it makes.

def _st() -> TuiState {
    return TuiState(lock=threading.RLock(), events=queue.Queue(), approval_lock=threading.Lock(),
                    main_ident=threading.get_ident());
}

def _plain(lines: list[any]) -> list[str] {
    return ["".join([str(f[1]) for f in ln]) for ln in lines];
}

def _ft_text(ft: any) -> str {
    return "".join([str(f[1]) for f in ft]);
}

def _visible(ctl: any, w: int, h: int) -> list[str] {
    content = ctl.create_content(w, h);
    return ["".join([str(f[1]) for f in content.get_line(i)]) for i in range(content.line_count)];
}

# ---------------------------------------------------------------------------
# when to use it
# ---------------------------------------------------------------------------
test "the classic flag, SIGIL_TUI=0 and a dumb terminal all keep the inline REPL" {
    assert not tui_wanted(["--classic"]);
    assert not tui_wanted(["--inline"]);
    old = os.environ.get("SIGIL_TUI");
    os.environ["SIGIL_TUI"] = "0";
    try { assert not tui_wanted([]); }
    finally {
        if old is None { os.environ.pop("SIGIL_TUI", None); }
        else { os.environ["SIGIL_TUI"] = old; }
    }
    old_term = os.environ.get("TERM");
    os.environ["TERM"] = "dumb";
    try { assert not tui_wanted([]); }
    finally {
        if old_term is None { os.environ.pop("TERM", None); }
        else { os.environ["TERM"] = old_term; }
    }
}

test "a run whose stdin is not a terminal never gets the full screen" {
    # jac test's stdin is not a TTY — the piped / scripted case
    if not sys.stdin.isatty() { assert not tui_wanted([]); }
}

# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
test "a line wider than the screen hard-wraps without losing text or style" {
    line = [("class:a", "abcdef"), ("class:b", "ghij")];
    rows = _wrap(line, 4);
    assert _plain(rows) == ["abcd", "efgh", "ij"];
    assert rows[1] == [("class:a", "ef"), ("class:b", "gh")];
    assert _wrap(line, 40) == [line];          # fits: untouched
    assert _plain(_wrap([("", "日本語")], 4)) == ["日本", "語"];   # wide characters count double
}

test "rich's hyperlinks are stripped before prompt_toolkit parses the ANSI" {
    esc = chr(27);
    s = esc + "]8;id=1;https://x.dev" + esc + "\\link" + esc + "]8;;" + esc + "\\" + chr(10);
    assert _plain(_frag_lines(s, 80)) == ["link"];
}

test "the trailing newline of a rich print leaves no blank line behind" {
    c = _console(40);
    c.print("[bold]hi[/bold]");
    assert _plain(_frag_lines(c.file.getvalue(), 40)) == ["hi"];
}

test "a reply draws its header and hangs the gutter off every line" {
    rows = _plain(_render(Block(kind="reply", text="**bold** and `code`"), 60));
    assert rows[0].strip() == "◆ sigil";
    for r in rows[1:] { assert r.startswith(chr(0x2502)); }
    assert "bold" in rows[1] and "**" not in rows[1];
    cont = _plain(_render(Block(kind="reply", text="more", head=False), 60));
    assert cont[0].startswith(chr(0x2502)) and "sigil" not in cont[0];
}

test "a user turn keeps its text and fits the screen" {
    rows = _plain(_render(Block(kind="user", text="please " * 20), 40));
    assert len(rows) > 1 and "›" in rows[0];
    for r in rows { assert len(r) <= 40; }
    assert "please" in rows[-1];
}

test "a tool row is the inline REPL's trace row" {
    ok = _plain(_render(Block(kind="tool", tool="exec", text="npm test"), 80));
    assert ok[0].startswith("  ✓ exec") and "npm test" in ok[0];
    bad = _plain(_render(Block(kind="tool", tool="read", text="missing.txt", ok=False), 80));
    assert bad[0].startswith("  ✗ read");
}

test "text from the model or a tool cannot inject rich markup" {
    t = _plain(_render(Block(kind="tool", tool="exec", text="[red]x[/red] [j1]"), 80));
    assert "[red]x[/red] [j1]" in t[0];
    u = _plain(_render(Block(kind="user", text="[bold]hi"), 80));
    assert "[bold]hi" in u[0];
}

test "a verdict says what was approved or denied" {
    yes = _plain(_render(Block(kind="verdict", ok=True, tool="shell", text="ls"), 80));
    assert "✓" in yes[0] and "approved shell" in yes[0] and "ls" in yes[0];
    no = _plain(_render(Block(kind="verdict", ok=False, tool="skill", text="clean_csv"), 80));
    assert "✗" in no[0] and "denied skill" in no[0];
}

test "a long captured log line wraps inside its gutter, not back to the margin" {
    rows = _plain(_render(Block(kind="log", text="x" * 120), 50));
    assert len(rows) > 1;
    assert rows[0].startswith("  │ ");
    for r in rows[1:] { assert r.startswith("    "); }
}

test "a block is redrawn only when it changes or the width does" {
    b = Block(kind="notice", text="one");
    first = _render(b, 60);
    assert _render(b, 60) is first;
    b.text = "two";
    b.ver += 1;
    assert "two" in _plain(_render(b, 60))[0];
    again = _render(b, 60);
    assert _render(b, 50) is not again;
}

test "entries are spaced; runs of trace rows and log lines are not" {
    assert not _gap("", "user");
    assert _gap("user", "tool");
    assert not _gap("tool", "tool");
    assert not _gap("tool", "verdict") and not _gap("verdict", "tool");
    assert not _gap("log", "log");
    assert _gap("tool", "reply");
}

# ---------------------------------------------------------------------------
# status row + footer
# ---------------------------------------------------------------------------
test "elapsed time reads as seconds, then minutes" {
    assert _elapsed(4.9) == "4s";
    assert _elapsed(65.0) == "1m 05s";
}

test "the status row shows phase, clock, queue and scroll position" {
    st = _st();
    assert _ft_text(_status_ft(st)) == "";
    st.busy = True;
    st.phase = "running npm test";
    st.t0 = time.monotonic() - 3.2;
    st.events.put(["send", "next"]);
    st.scroll = 5;
    t = _ft_text(_status_ft(st));
    assert "running npm test…" in t and "3s" in t and "esc to interrupt" in t;
    assert "1 queued" in t and "scrolled back" in t;
}

test "a narrow footer drops the least essential hints first" {
    st = _st();
    full = _hints(st, 200);
    assert full.startswith("⏎ send") and full.endswith("^C^C quit");
    short = _hints(st, 24);
    assert short.endswith("^C^C quit") and ("⏎ send" not in short) and (len(short) <= 24);
    st.busy = True;
    assert "esc interrupt" in _hints(st, 200);
    st.approval = {"cmd": "ls", "ok": False, "ev": threading.Event()};
    assert _hints(st, 200) == "y run · n deny";
}

test "the approval prompt names the command and what y means for a skill" {
    st = _st();
    st.approval = {"cmd": "skill:clean_csv tidy it", "ok": False, "ev": threading.Event()};
    t = _ft_text(_approval_ft(st));
    assert "approve skill" in t and "clean_csv tidy it" in t and "from now on" in t;
    st.approval = {"cmd": "rm -rf build/", "ok": False, "ev": threading.Event()};
    t2 = _ft_text(_approval_ft(st));
    assert "approve shell" in t2 and "rm -rf build/" in t2 and "from now on" not in t2;
}

# ---------------------------------------------------------------------------
# the transcript window
# ---------------------------------------------------------------------------
test "the transcript follows the tail, scrolls back, and holds still while scrolled" {
    st = _st();
    for i in range(30) { st.blocks.append(Block(kind="log", text="line " + str(i))); }
    ctl = TranscriptControl(st);
    vis = _visible(ctl, 60, 10);
    assert len(vis) == 10 and vis[-1].endswith("line 29");
    st.scroll = 5;
    assert _visible(ctl, 60, 10)[-1].endswith("line 24");
    # new output while scrolled back must not move what is being read
    st.blocks.append(Block(kind="log", text="line 30"));
    assert _visible(ctl, 60, 10)[-1].endswith("line 24");
    # past the top clamps to the first line
    st.scroll = 999;
    assert _visible(ctl, 60, 10)[0].endswith("line 0");
}

# the handler reads only the event type; prompt_toolkit's MouseEvent wants a
# Point the checker cannot type
obj _Wheel { has event_type: any; }

test "the mouse wheel scrolls the transcript" {
    st = _st();
    ctl = TranscriptControl(st);
    ctl.mouse_handler(_Wheel(event_type=MouseEventType.SCROLL_UP));
    assert st.scroll == 3;
    ctl.mouse_handler(_Wheel(event_type=MouseEventType.SCROLL_DOWN));
    ctl.mouse_handler(_Wheel(event_type=MouseEventType.SCROLL_DOWN));
    assert st.scroll == 0;
}

# ---------------------------------------------------------------------------
# turns, hooks, approvals, slash commands
# ---------------------------------------------------------------------------
test "a turn that never streamed renders its reply once, and the clock stops" {
    st = _st();
    def turn(msg: str) -> dict[str, any] { return {"reply": "pong: " + msg, "interrupted": False}; }
    _turn(st, "ping", turn);
    assert [b.kind for b in st.blocks] == ["user", "reply"];
    assert st.blocks[1].text == "pong: ping";
    assert (not st.busy) and st.last_reply == "pong: ping" and st.turns == 1;
}

test "an error note after a streamed reply is not lost" {
    st = _st();
    h = _hooks(st);
    def turn(msg: str) -> dict[str, any] {
        h["token"]("partial answer");
        return {"reply": "partial answer\n\n⚠ the model call failed", "interrupted": False};
    }
    _turn(st, "go", turn);
    replies = [b for b in st.blocks if b.kind == "reply"];
    assert len(replies) == 2 and replies[0].head and (not replies[1].head);
    assert "model call failed" in replies[1].text;
}

test "an interrupt that escapes the turn ends the turn, not the chat" {
    st = _st();
    def turn(msg: str) -> dict[str, any] { raise KeyboardInterrupt(); }
    _turn(st, "slow", turn);
    assert not st.busy;
    assert st.blocks[-1].kind == "notice" and "interrupted" in st.blocks[-1].text;
}

test "a tool row splits the streamed reply; the rest continues below it" {
    st = _st();
    h = _hooks(st);
    h["token"]("first ");
    h["trace"]("exec", "ls", True);
    h["token"]("second");
    assert [b.kind for b in st.blocks] == ["reply", "tool", "reply"];
    assert st.blocks[0].head and (not st.blocks[2].head);
    assert st.streamed == "first second";
    h["start"]("exec", "npm test");
    assert st.phase == "running npm test";
}

test "an approval nobody can answer is a no" {
    st = _st();
    st.ui_alive = False;
    assert not _approve(st, "rm -rf build/");
    assert st.approval is None;
    v = st.blocks[-1];
    assert v.kind == "verdict" and (not v.ok) and v.tool == "shell";
}

test "a y from the UI thread approves, and a skill is labelled as one" {
    st = _st();
    st.ui_alive = True;
    def answer() -> None {
        deadline = time.monotonic() + 3.0;
        while (st.approval is None) and (time.monotonic() < deadline) { time.sleep(0.01); }
        _answer(st, True);
    }
    t = threading.Thread(target=answer, daemon=True);
    t.start();
    assert _approve(st, "skill:clean_csv tidy it");
    t.join(timeout=3.0);
    v = st.blocks[-1];
    assert v.ok and v.tool == "skill" and v.text == "clean_csv tidy it";
}

test "slash commands draw into the transcript; the screen-owning ones are handled here" {
    st = _st();
    st.blocks.append(Block(kind="notice", text="old"));
    assert _slash(st, "/exit") == "exit";
    assert _slash(st, "/config") == "config";
    assert _slash(st, "/clear") == "" and len(st.blocks) == 0;
    assert _slash(st, "/help") == "";
    txt = st.blocks[-1].text;
    assert "/copy" in txt and "keys" in txt and "interrupt the agent" in txt;
    _slash(st, "/copy");
    assert "nothing to copy yet" in st.blocks[-1].text;
    _slash(st, "/nope");
    assert "unknown command" in st.blocks[-1].text;
}

# ---------------------------------------------------------------------------
# the fd jail
# ---------------------------------------------------------------------------
test "whatever reaches the jailed stdout lands in the transcript, \\r progress collapsed" {
    st = _st();
    (r, w) = os.pipe();
    os.write(w, ("plain" + chr(10) + "10%" + chr(13) + "100%" + chr(10) + "tail").encode("utf-8"));
    os.close(w);
    _drain(st, r);
    assert len(st.blocks) == 1 and st.blocks[0].kind == "log";
    assert st.blocks[0].text.split(chr(10)) == ["plain", "100%", "tail"];
}

test "the jail captures fd 1 and 2, gives children /dev/null for stdin, and puts it all back" {
    st = _st();
    def ident(fd: int) -> any { s = os.fstat(fd); return [s.st_dev, s.st_ino]; }
    before = [ident(0), ident(1), ident(2)];
    jail = FdJail(st=st);
    jail.enter();
    got_eof = False;
    try {
        os.write(1, ("to stdout" + chr(10)).encode("utf-8"));
        os.write(2, ("to stderr" + chr(10)).encode("utf-8"));
        got_eof = os.read(0, 16) == b"";
    } finally { jail.leave(); }
    assert [ident(0), ident(1), ident(2)] == before;
    assert got_eof;
    def captured() -> str { return chr(10).join([b.text for b in st.blocks]); }
    deadline = time.monotonic() + 3.0;
    while (time.monotonic() < deadline) and ("to stderr" not in captured()) { time.sleep(0.02); }
    assert "to stdout" in captured() and "to stderr" in captured();
}
