"""Sigil's full-screen chat — `sigil chat` on the terminal's alternate screen.

The same conversation, agent and graph as the inline REPL in sigil_chat.jac; only
the drawing differs. The app takes the screen over the way vim, htop, Claude Code
and Codex do (DEC private mode 1049: the shell's screen is set aside, not erased,
and comes back exactly as it was on exit) and lays out

  · a scrollable transcript — your turns, the streamed markdown reply, every tool
    the agent calls, approvals, slash-command output, anything a tool prints
  · a status row — spinner, phase, elapsed time; an approval prompt takes it over
  · a bordered multiline input with the "/" palette and history
  · a footer — model · sandbox · skills, and the keys that apply right now

Threads. The agent turn stays on the MAIN thread, exactly where the inline REPL
runs it, and prompt_toolkit's application runs on a second one (it supports that:
off the main thread it polls the terminal size instead of using SIGWINCH). The
split is what lets Esc mean what ^C means inline: the UI sends SIGINT to the main
thread with pthread_kill, the turn gets the KeyboardInterrupt chat_turn already
handles, and a blocking network read is woken the way a real ^C wakes it. The UI
thread never touches the graph — every graph read and write stays on the main
thread, the sub-agents' own threads aside, as before.

File descriptors. While the app owns the terminal nothing else may draw on it, so
fd 1 and fd 2 point at a pipe whose lines land in the transcript, and fd 0 points
at /dev/null so a shell job can never read the keystrokes meant for the input box.
The app draws through private duplicates of the real terminal.

`sigil chat --classic` (or SIGIL_TUI=0) keeps the inline REPL, and so does any run
whose stdin or stdout is not a terminal.
"""

import sys;
import os;
import io;
import re;
import time;
import queue;
import signal;
import threading;
import traceback;
import from .sigil_chat {
    _banner, _help, _handle_slash, _guttered_markdown, _trace_rows, _tool_style,
    _sync_toolbar, chat_repl, config_menu, copy_to_clipboard, _TRACE_GUTTER
}
import from .sigil_input { SlashCompleter, _style, _TOOLBAR }
import from .chat_agent { chat_turn, set_token_sink }
import from .sigil_workspace { set_trace_sink, set_start_sink, set_approver }
import from .sigil_runtime { commit_now }
import from rich.console { Console }
import from rich.text { Text }
import from rich.table { Table }
import from rich.padding { Padding }
import from rich.markup { escape }
import from prompt_toolkit.application { Application }
import from prompt_toolkit.buffer { Buffer }
import from prompt_toolkit.history { FileHistory }
import from prompt_toolkit.auto_suggest { AutoSuggestFromHistory }
import from prompt_toolkit.filters { Condition }
import from prompt_toolkit.formatted_text { ANSI, to_formatted_text }
import from prompt_toolkit.formatted_text.utils { split_lines, fragment_list_width }
import from prompt_toolkit.input.defaults { create_input }
import from prompt_toolkit.output.defaults { create_output }
import from prompt_toolkit.output.color_depth { ColorDepth }
import from prompt_toolkit.key_binding { KeyBindings }
import from prompt_toolkit.layout {
    Layout, HSplit, VSplit, Window, FloatContainer, Float, ConditionalContainer, WindowAlign
}
import from prompt_toolkit.layout.controls { UIControl, UIContent, BufferControl, FormattedTextControl }
import from prompt_toolkit.layout.dimension { Dimension }
import from prompt_toolkit.layout.menus { CompletionsMenu }
import from prompt_toolkit.layout.processors { AppendAutoSuggestion, AfterInput, ConditionalProcessor }
import from prompt_toolkit.mouse_events { MouseEventType }
import from prompt_toolkit.styles { Style, merge_styles }
import from prompt_toolkit.utils { get_cwidth }
import from prompt_toolkit.cursor_shapes { CursorShape }

# ---------------------------------------------------------------------------
# when to use it
# ---------------------------------------------------------------------------
def tui_wanted(args: list[str]) -> bool {
    # On by default; the inline REPL is one flag or one variable away, and any
    # run that is not a real terminal on both ends keeps it (scripts, pipes, CI).
    if ("--classic" in args) or ("--inline" in args) { return False; }
    if os.environ.get("SIGIL_TUI", "").strip().lower() in ["0", "off", "false", "no"] { return False; }
    if os.environ.get("TERM", "") == "dumb" { return False; }
    try { return bool(sys.stdin.isatty() and sys.stdout.isatty()); }
    except Exception { return False; }
}

# ---------------------------------------------------------------------------
# the transcript model — written by the main thread, drawn by the UI thread
# ---------------------------------------------------------------------------
# kind: ansi (pre-rendered: banner, slash-command output) · user · cmd · reply ·
# tool · verdict (an approval's outcome) · log (captured stdout/stderr) · notice
obj Block {
    has kind: str,
        text: str = "",
        tool: str = "",
        ok: bool = True,
        head: bool = True,     # a reply's "◆ sigil" header; off for a continuation
        ver: int = 0,          # bumped on every change; the render cache keys on it
        cache_w: int = -1,
        cache_v: int = -1,
        cache: list[any] = [];
}

obj TuiState {
    has blocks: list[Block] = [],
        lock: any = None,          # RLock over blocks and the turn fields
        events: any = None,        # UI -> main: ["send", text] | ["exit", ""] | ["ui-down", ""]
        approval_lock: any = None, # one approval question on screen at a time
        busy: bool = False,
        phase: str = "",
        t0: float = 0.0,
        reply: Block | None = None,   # the reply block tokens stream into right now
        streamed: str = "",           # every token this turn, across reply blocks
        approval: dict[str, any] | None = None,
        interrupting: bool = False,
        scroll: int = 0,              # lines scrolled up from the bottom; 0 = follow
        seen_total: int = 0,
        width: int = 80,
        height: int = 24,
        flash: str = "",
        flash_until: float = 0.0,
        quit_armed: float = 0.0,
        main_ident: int = 0,
        tty_fd: int = -1,
        app: any = None,
        ui_alive: bool = False,
        ui_hung: bool = False,        # the UI thread outlived its stop: restore the terminal by hand
        ui_error: str = "",
        closing: bool = False,
        turns: int = 0,
        last_reply: str = "",
        last_poke: float = 0.0;

    def add(b: Block) -> Block {
        with self.lock { self.blocks.append(b); }
        self.poke(True);
        return b;
    }

    def say(text: str, kind: str = "notice") -> None { self.add(Block(kind=kind, text=text)); }

    def poke(now: bool = False) -> None {
        # A repaint request from any thread. Streaming tokens are throttled to
        # ~20fps here; the ticker repaints every 100ms during a turn anyway, so a
        # dropped request only delays a frame, never loses one.
        t = time.monotonic();
        if (not now) and ((t - self.last_poke) < 0.05) { return; }
        self.last_poke = t;
        app = self.app;
        if app is not None { try { app.invalidate(); } except Exception {} }
    }
}

def _flash(st: TuiState, text: str, secs: float) -> None {
    st.flash = text;
    st.flash_until = time.monotonic() + secs;
    st.poke(True);
}

# ---------------------------------------------------------------------------
# rendering — rich draws each block off-screen, prompt_toolkit shows the lines
# ---------------------------------------------------------------------------
# rich writes OSC 8 hyperlinks for markdown links; prompt_toolkit's ANSI parser
# does not know them and would print the escape as text.
glob _OSC: any = re.compile("\x1b\\][^\x07\x1b]*(?:\x07|\x1b\\\\)");

def _console(width: int) -> any {
    return Console(file=io.StringIO(), width=max(20, width), force_terminal=True,
                   color_system="truecolor", legacy_windows=False);
}

def _wrap(line: list[any], width: int) -> list[any] {
    # Hard-wrap one fragment line to the screen. Live blocks are rendered at the
    # current width already; this is for pre-rendered ones (the banner, slash
    # output) after the terminal is made narrower.
    if (width <= 0) or (fragment_list_width(line) <= width) { return [line]; }
    out: list[any] = [];
    cur: list[any] = [];
    cw = 0;
    for frag in line {
        style = frag[0];
        piece = "";
        for ch in str(frag[1]) {
            w = get_cwidth(ch);
            if (cw + w) > width {
                if piece { cur.append((style, piece)); piece = ""; }
                out.append(cur);
                cur = [];
                cw = 0;
            }
            piece += ch;
            cw += w;
        }
        if piece { cur.append((style, piece)); }
    }
    out.append(cur);
    return out;
}

def _frag_lines(ansi: str, width: int) -> list[any] {
    frags = to_formatted_text(ANSI(_OSC.sub("", ansi)));
    lines: list[any] = [list(ln) for ln in split_lines(frags)];
    # every rich print ends in a newline, and the style reset after it parses as
    # a zero-width line: drop those, the transcript spaces entries itself
    while lines and (fragment_list_width(lines[-1]) == 0) { lines.pop(); }
    out: list[any] = [];
    for ln in lines { out.extend(_wrap(ln, width)); }
    return out;
}

def _draw(c: any, b: Block, text: str) -> None {
    k = b.kind;
    if k == "user" {
        g = Table.grid(padding=(0, 1));
        g.add_column(width=1);
        g.add_column(ratio=1);
        g.add_row(Text("›", style="bold #a78bfa"), Text(text, style="#e6e6f0"));
        c.print(Padding(g, (0, 1), style="on #1e1c2a", expand=True));
    } elif k == "cmd" {
        c.print(Text("› " + text, style="#8a80bd"));
    } elif k == "reply" {
        if b.head { c.print(Text.from_markup("[#a78bfa]◆[/] [dim]sigil[/]")); }
        if text { c.print(_guttered_markdown(c, text)); }
    } elif k == "tool" {
        # the inline REPL's trace row, column for column
        mark = "✓" if b.ok else "✗";
        col = _tool_style(b.tool) if b.ok else "red";
        first = True;
        for row in _trace_rows(text, int(c.width) - _TRACE_GUTTER) {
            body = "[dim]" + str(escape(str(row))) + "[/dim]";
            if first {
                c.print("  [dim]" + mark + "[/dim] [" + col + "]" + str(escape(b.tool.ljust(11))) + "[/" + col + "] " + body);
                first = False;
            } else { c.print((" " * _TRACE_GUTTER) + body); }
        }
    } elif k == "verdict" {
        t = Text.from_markup("  [green]✓[/green] " if b.ok else "  [red]✗[/red] ");
        t.append(("approved " if b.ok else "denied ") + b.tool + "  ", style="dim");
        t.append(text, style="dim");
        c.print(t);
    } elif k == "log" {
        # a grid, not prefixed text, so a long line wraps INSIDE the gutter
        g = Table.grid(padding=0);
        g.add_column(width=4, style="#45455a");
        g.add_column(ratio=1);
        for ln in text.split(chr(10)) { g.add_row("  │ ", Text.from_ansi(ln, style="dim")); }
        c.print(g);
    } elif k == "error" {
        c.print(Text("  " + text, style="red"));
    } else {
        c.print(Text("  " + text, style="dim"));
    }
}

def _render(b: Block, width: int) -> list[any] {
    if (b.cache_w == width) and (b.cache_v == b.ver) { return b.cache; }
    # read the version BEFORE the text: a token landing in between bumps ver
    # past what is cached, so the next frame redraws instead of keeping a stale one
    v = b.ver;
    text = b.text;
    lines: list[any] = [];
    try {
        if b.kind == "ansi" { lines = _frag_lines(text, width); }
        else {
            c = _console(width);
            _draw(c, b, text);
            lines = _frag_lines(c.file.getvalue(), width);
        }
    } except Exception as e {
        lines = [[("class:error", "  ⚠ could not draw this entry: " + str(e)[:160])]];
    }
    b.cache = lines;
    b.cache_w = width;
    b.cache_v = v;
    return lines;
}

def _gap(prev: str, cur: str) -> bool {
    # one blank line between entries, none inside a run of trace rows or log lines
    if not prev { return False; }
    if (prev == cur) and (cur in ["tool", "verdict", "log", "notice", "reply"]) { return False; }
    if (prev in ["tool", "verdict"]) and (cur in ["tool", "verdict"]) { return False; }
    return True;
}

# prompt_toolkit's UIControl is ABCMeta-driven — a `class` archetype, like
# sigil_input's SlashCompleter. It hands the window only the visible lines, so
# scrolling is ours: `scroll` counts lines up from the bottom, 0 follows the tail,
# and new output arriving while scrolled up does not move what you are reading.
class TranscriptControl(UIControl) {
    def __init__(self: any, st: any) -> None { self.st = st; }

    def is_focusable(self: any) -> bool { return False; }

    def create_content(self: any, width: int, height: int) -> any {
        st = self.st;
        st.width = width;
        st.height = height;
        vis: list[any] = [];
        try {
            with st.lock { blocks = list(st.blocks); }
            flat: list[any] = [];
            prev = "";
            for b in blocks {
                if _gap(prev, b.kind) { flat.append([]); }
                flat.extend(_render(b, width));
                prev = b.kind;
            }
            total = len(flat);
            if (st.scroll > 0) and (total > st.seen_total) { st.scroll += total - st.seen_total; }
            st.seen_total = total;
            st.scroll = max(0, min(st.scroll, total - height));
            start = max(0, total - height - st.scroll);
            vis = flat[start:start + height];
        } except Exception as e {
            vis = [[("class:error", "  ⚠ transcript: " + str(e)[:160])]];
        }
        def line(i: int) -> any { return vis[i]; }
        return UIContent(get_line=line, line_count=len(vis), show_cursor=False);
    }

    def mouse_handler(self: any, mouse_event: any) -> any {
        t = mouse_event.event_type;
        if t == MouseEventType.SCROLL_UP { self.st.scroll += 3; return None; }
        if t == MouseEventType.SCROLL_DOWN { self.st.scroll = max(0, self.st.scroll - 3); return None; }
        return NotImplemented;
    }
}

# ---------------------------------------------------------------------------
# status row, approval prompt, footer
# ---------------------------------------------------------------------------
glob _SPIN: list[str] = ["◇", "◈", "◆", "◈"];

def _elapsed(sec: float) -> str {
    s = int(sec);
    if s < 60 { return str(s) + "s"; }
    return str(s // 60) + "m " + str(s % 60).zfill(2) + "s";
}

def _status_ft(st: TuiState) -> any {
    out: list[any] = [];
    now = time.monotonic();
    if st.busy {
        out.append(("class:status.spin", " " + _SPIN[int(now * 6) % len(_SPIN)] + " "));
        if st.interrupting { out.append(("class:status.warn", "interrupting…")); }
        else { out.append(("class:status.phase", st.phase + "…")); }
        out.append(("class:status.dim", "  " + _elapsed(now - st.t0) + " · esc to interrupt"));
    }
    extra: list[any] = [];
    q = int(st.events.qsize()) if st.events is not None else 0;
    if q > 0 { extra.append(("class:status.dim", str(q) + " queued")); }
    if st.flash and (now < st.flash_until) { extra.append(("class:status.warn", st.flash)); }
    if st.scroll > 0 { extra.append(("class:status.dim", "↑ scrolled back — PgDn or End for the latest")); }
    for x in extra {
        out.append(("class:status.dim", " · " if out else " "));
        out.append(x);
    }
    return out;
}

def _approval_ft(st: TuiState) -> any {
    req = st.approval;
    if req is None { return []; }
    cmd = str(req["cmd"]);
    skill = cmd.startswith("skill:");
    what = cmd[6:] if skill else cmd;
    return [
        ("class:approve.mark", " ⚠ approve " + ("skill" if skill else "shell") + "  "),
        ("class:approve.cmd", what),
        ("", chr(10)),
        ("class:approve.keys", "   y"),
        ("class:approve.dim", (" run it, and allow this skill from now on" if skill else " run it") + "    "),
        ("class:approve.keys", "n"),
        ("class:approve.dim", " or esc  deny")
    ];
}

def _hints(st: TuiState, room: int) -> str {
    # the keys that apply right now, least essential first: a narrow terminal
    # drops hints from the front instead of overlapping the model/sandbox side
    keys = ["⏎ send", "^J newline", "/ commands", "^C^C quit"];
    if st.approval is not None { keys = ["y run", "n deny"]; }
    elif st.busy { keys = ["⏎ queues a message", "esc interrupt"]; }
    while keys and (len(" · ".join(keys)) > room) { keys = keys[1:]; }
    return " · ".join(keys);
}

glob _TUI_STYLE: dict[str, str] = {
    "frame": "#6d5bb0",
    "frame.busy": "#3b3652",
    "frame.approve": "#d7af5f",
    "prompt": "#a78bfa bold",
    "status.spin": "#c084fc bold",
    "status.phase": "#c9c9dc",
    "status.dim": "#6b6b85",
    "status.warn": "#d7af5f",
    "approve.mark": "#e5c07b bold",
    "approve.cmd": "#e8e8f0",
    "approve.keys": "#a78bfa bold",
    "approve.dim": "#8a8aa3",
    "footer": "#6b6b85",
    "error": "#ff6b6b"
};

# ---------------------------------------------------------------------------
# keys + layout
# ---------------------------------------------------------------------------
def _answer(st: TuiState, ok: bool) -> None {
    req = st.approval;
    if req is None { return; }
    req["ok"] = ok;
    req["ev"].set();
}

def _interrupt(st: TuiState) -> None {
    # SIGINT to the MAIN thread specifically: a process-directed signal may be
    # taken by any thread, and only one aimed at the main thread both raises
    # KeyboardInterrupt there and wakes the syscall it is blocked in.
    if not st.busy { return; }
    st.interrupting = True;
    try { signal.pthread_kill(st.main_ident, signal.SIGINT); } except Exception {}
}

def _build_app(st: TuiState, buf: any, inp: any, out: any) -> any {
    kb = KeyBindings();
    def approving() -> bool { return st.approval is not None; }
    def not_approving() -> bool { return st.approval is None; }
    def input_empty() -> bool { return not buf.text; }
    asking = Condition(approving);
    typing = Condition(not_approving);

    @kb.add("enter", filter=typing)
    def _enter(event: any) -> None {
        cs = buf.complete_state;
        if cs and cs.current_completion {
            buf.apply_completion(cs.current_completion);
            # an applied verb ends in " " when it takes arguments — reopen the
            # menu so its argument vocabulary is on screen without a keypress
            if str(buf.text).endswith(" ") { buf.start_completion(select_first=False); }
            return;
        }
        text = str(buf.text).strip();
        if not text { return; }
        buf.reset(append_to_history=True);
        st.scroll = 0;
        st.events.put(["send", text]);
        event.app.invalidate();
    }

    @kb.add("c-j", filter=typing)
    @kb.add("escape", "enter", filter=typing)
    def _newline(_event: any) -> None { buf.insert_text(chr(10)); }

    @kb.add("y", filter=asking)
    @kb.add("Y", filter=asking)
    def _yes(_event: any) -> None { _answer(st, True); }

    @kb.add("n", filter=asking)
    @kb.add("N", filter=asking)
    @kb.add("enter", filter=asking)
    @kb.add("escape", filter=asking)
    def _no(_event: any) -> None { _answer(st, False); }

    @kb.add("escape", filter=typing)
    def _esc(_event: any) -> None {
        if buf.complete_state is not None { buf.cancel_completion(); }
        elif st.busy { _interrupt(st); }
        elif st.scroll { st.scroll = 0; }
    }

    @kb.add("c-c")
    def _ctrl_c(_event: any) -> None {
        if st.approval is not None { _answer(st, False); _interrupt(st); return; }
        if st.busy { _interrupt(st); return; }
        if buf.text { buf.reset(); return; }
        now = time.monotonic();
        if (now - st.quit_armed) < 2.0 { st.events.put(["exit", ""]); return; }
        st.quit_armed = now;
        _flash(st, "press ^C again to quit", 2.0);
    }

    @kb.add("c-d")
    def _ctrl_d(_event: any) -> None {
        if buf.text { buf.delete(); return; }
        if st.busy { _interrupt(st); }
        st.events.put(["exit", ""]);
    }

    @kb.add("pageup")
    def _pgup(_event: any) -> None { st.scroll += max(1, st.height - 3); }

    @kb.add("pagedown")
    def _pgdn(_event: any) -> None { st.scroll = max(0, st.scroll - max(1, st.height - 3)); }

    @kb.add("c-end")
    @kb.add("end", filter=Condition(input_empty))
    def _latest(_event: any) -> None { st.scroll = 0; }

    @kb.add("c-l")
    def _redraw(event: any) -> None { event.app.renderer.clear(); }

    @kb.add("c-z")
    def _suspend(event: any) -> None { event.app.suspend_to_background(); }

    def frame_style() -> str {
        if st.approval is not None { return "class:frame.approve"; }
        return "class:frame.busy" if st.busy else "class:frame";
    }
    def corner(ch: str) -> any { return Window(width=1, height=1, char=ch, style=frame_style); }
    def rule() -> any { return Window(height=1, char="─", style=frame_style); }
    def prefix(lineno: int, wrap_count: int) -> any {
        if (lineno == 0) and (wrap_count == 0) { return [("class:prompt", "› ")]; }
        return [("", "  ")];
    }
    def placeholder() -> str {
        if st.busy { return "type ahead — it sends when this turn ends"; }
        return 'plan, build, schedule — "/" for commands';
    }
    def status_text() -> any { return _status_ft(st); }
    def approval_text() -> any { return _approval_ft(st); }
    def foot_left() -> any { return [("class:footer", " " + str(_TOOLBAR["s"]))]; }
    def foot_right() -> any {
        room = st.width - len(str(_TOOLBAR["s"])) - 5;
        return [("class:footer", _hints(st, room) + " ")];
    }

    input_win = Window(
        BufferControl(buffer=buf, input_processors=[
            ConditionalProcessor(AfterInput(placeholder, style="class:placeholder"), filter=Condition(input_empty)),
            AppendAutoSuggestion()
        ]),
        height=Dimension(min=1, max=10), dont_extend_height=True,
        wrap_lines=True, get_line_prefix=prefix
    );
    body = HSplit([
        Window(TranscriptControl(st), wrap_lines=False, always_hide_cursor=True),
        ConditionalContainer(Window(FormattedTextControl(status_text), height=1), filter=typing),
        ConditionalContainer(
            Window(FormattedTextControl(approval_text), wrap_lines=True,
                   height=Dimension(min=2, max=10), dont_extend_height=True),
            filter=asking
        ),
        VSplit([corner("╭"), rule(), corner("╮")], height=1),
        VSplit([corner("│"), Window(width=1, char=" "), input_win, Window(width=1, char=" "), corner("│")]),
        VSplit([corner("╰"), rule(), corner("╯")], height=1),
        VSplit([
            Window(FormattedTextControl(foot_left), height=1),
            Window(FormattedTextControl(foot_right), height=1, dont_extend_width=True, align=WindowAlign.RIGHT)
        ], height=1)
    ]);
    container = FloatContainer(content=body, floats=[
        Float(xcursor=True, ycursor=True, content=CompletionsMenu(max_height=8, scroll_offset=1))
    ]);
    depth: any = None;
    if os.environ.get("COLORTERM", "").lower() in ["truecolor", "24bit"] { depth = ColorDepth.DEPTH_24_BIT; }
    app = Application(
        layout=Layout(container, focused_element=input_win),
        key_bindings=kb,
        style=merge_styles([_style(), Style.from_dict(_TUI_STYLE)]),
        full_screen=True,
        mouse_support=True,
        input=inp,
        output=out,
        color_depth=depth,
        min_redraw_interval=0.03,
        enable_page_navigation_bindings=False,
        cursor=CursorShape.BEAM
    );
    # a lone Esc is ambiguous with Alt-<key> sequences: wait 50ms for the rest
    # of a sequence and 250ms for a second key, not prompt_toolkit's 0.5s + 1s
    app.ttimeoutlen = 0.05;
    app.timeoutlen = 0.25;
    return app;
}

# ---------------------------------------------------------------------------
# the agent's hooks — called on the main thread (or a sub-agent's thread)
# ---------------------------------------------------------------------------
def _approve(st: TuiState, command: str) -> bool {
    # A tool blocks here until the y/n is answered. The lock keeps one question
    # on screen at a time (parallel sub-agents can ask together), and the wait
    # polls so a UI that died or a session that is closing can never leave a
    # tool hanging on a question nobody can see — no answer is a no.
    ok = False;
    with st.approval_lock {
        ev = threading.Event();
        req: dict[str, any] = {"cmd": command, "ok": False, "ev": ev};
        st.approval = req;
        st.poke(True);
        try {
            while not ev.wait(0.2) {
                if (not st.ui_alive) or st.closing { break; }
            }
        } finally {
            st.approval = None;
            st.poke(True);
        }
        ok = bool(req["ok"]);
    }
    skill = command.startswith("skill:");
    st.add(Block(kind="verdict", ok=ok, tool=("skill" if skill else "shell"),
                 text=(command[6:] if skill else command)));
    return ok;
}

def _hooks(st: TuiState) -> dict[str, any] {
    def on_token(piece: str) -> None {
        with st.lock {
            b = st.reply;
            if b is None {
                b = Block(kind="reply", head=(st.streamed == ""));
                st.blocks.append(b);
                st.reply = b;
            }
            b.text += str(piece);
            b.ver += 1;
            st.streamed += str(piece);
            st.phase = "writing";
        }
        st.poke();
    }
    def on_trace(tool: str, detail: str, ok: bool) -> None {
        with st.lock {
            # a tool row after streamed text: later tokens open a new block below it
            st.reply = None;
            st.blocks.append(Block(kind="tool", tool=str(tool), text=str(detail), ok=bool(ok)));
            st.phase = "thinking";
        }
        st.poke(True);
    }
    def on_start(_tool: str, detail: str) -> None {
        one = str(detail).strip().replace(chr(10), " ⏎ ");
        st.phase = "running " + (one[:60] + "…" if len(one) > 60 else one);
        st.poke(True);
    }
    def on_approve(command: str) -> bool { return _approve(st, str(command)); }
    return {"token": on_token, "trace": on_trace, "start": on_start, "approve": on_approve};
}

def _install(st: TuiState) -> None {
    h = _hooks(st);
    set_token_sink(h["token"]);
    set_trace_sink(h["trace"]);
    set_start_sink(h["start"]);
    set_approver(h["approve"]);
}

def _uninstall() -> None {
    set_token_sink(None);
    set_trace_sink(None);
    set_start_sink(None);
    set_approver(None);
}

# ---------------------------------------------------------------------------
# turns + slash commands — main thread
# ---------------------------------------------------------------------------
def _turn(st: TuiState, text: str, turn_fn: any) -> None {
    st.add(Block(kind="user", text=text));
    with st.lock {
        st.busy = True;
        st.phase = "thinking";
        st.t0 = time.monotonic();
        st.reply = None;
        st.streamed = "";
        st.interrupting = False;
    }
    st.poke(True);
    r: dict[str, any] = {};
    interrupted = False;
    try {
        r = turn_fn(text);
        interrupted = bool(r.get("interrupted") or False);
    } except KeyboardInterrupt {
        # landed outside chat_turn's own guard (a hook, the return path)
        interrupted = True;
    } finally {
        with st.lock {
            st.busy = False;
            st.reply = None;
            st.interrupting = False;
        }
    }
    took = time.monotonic() - st.t0;
    full = str(r.get("reply") or "");
    streamed = st.streamed;
    if streamed {
        # chat_turn appends an error note to a reply that died mid-stream; the
        # inline REPL never showed it once tokens had streamed — show it here
        tail = full[len(streamed):].strip() if full.startswith(streamed) else "";
        if tail { st.add(Block(kind="reply", text=tail, head=False)); }
    } elif full {
        st.add(Block(kind="reply", text=full));
    }
    if interrupted { st.say("✂ interrupted" + (" — reply cut short" if streamed else "")); }
    elif took >= 5.0 { st.say("worked for " + _elapsed(took)); }
    st.last_reply = full if full else streamed;
    st.turns += 1;
    st.poke(True);
}

def _tui_keys(c: any) -> None {
    c.print("[bold]keys[/bold]");
    rows = [
        ["⏎   ^J / ⌥⏎", "send · newline"],
        ["esc", "interrupt the agent · deny an approval"],
        ["^C", "interrupt · clear the input · twice to quit"],
        ["^D", "quit"],
        ["PgUp PgDn wheel", "scroll the transcript · End jumps back to the latest"],
        ["↑ ↓  tab", "history · complete"],
        ["⇧/⌥-drag", "select text (the mouse is captured for scrolling) · /copy copies the last reply"]
    ];
    for r in rows { c.print("  [cyan]" + str(escape(r[0].ljust(18))) + "[/cyan] [dim]" + r[1] + "[/dim]"); }
    c.print();
}

def _slash(st: TuiState, cmd: str) -> str {
    # The inline REPL's command table, drawn into the transcript: the same
    # _handle_slash, handed a console that renders off-screen. Only what needs
    # the terminal itself is handled here.
    verb = str(cmd.split(" ", 1)[0]).lower();
    if verb in ["/exit", "/quit", "/q"] { return "exit"; }
    if verb == "/config" { return "config"; }
    if verb == "/clear" {
        with st.lock { st.blocks.clear(); }
        st.scroll = 0;
        st.poke(True);
        return "";
    }
    st.add(Block(kind="cmd", text=cmd));
    if verb == "/copy" {
        st.say(copy_to_clipboard(st.last_reply, st.tty_fd));
        return "";
    }
    c = _console(st.width);
    try {
        _handle_slash(c, cmd);
        if verb in ["/help", "/?", "/h"] { _tui_keys(c); }
    } except Exception as e {
        c.print("[red]  ✖[/red] " + str(escape(str(e)[:300])));
    }
    st.add(Block(kind="ansi", text=c.file.getvalue()));
    return "";
}

def _drive(st: TuiState, turn_fn: any) -> str {
    while True {
        ev: any = None;
        try { ev = st.events.get(timeout=0.5); }
        except queue.Empty {
            if not st.ui_alive { return "exit"; }
            continue;
        } except KeyboardInterrupt {
            # an Esc that reached us just after its turn had already ended
            continue;
        }
        try {
            kind = str(ev[0]);
            if kind == "exit" { return "exit"; }
            if kind == "ui-down" {
                # the UI of THIS session died; a stale one from a session that
                # was stopped on purpose (around /config) is not news
                if st.ui_alive { continue; }
                return "exit";
            }
            text = str(ev[1]);
            if text.startswith("/") {
                r = _slash(st, text);
                if r { return r; }
            } else { _turn(st, text, turn_fn); }
        } except KeyboardInterrupt {
            st.say("✂ interrupted");
        }
    }
    return "exit";
}

# ---------------------------------------------------------------------------
# the terminal: fd jail, UI thread, ticker
# ---------------------------------------------------------------------------
def _log(st: TuiState, lines: list[str]) -> None {
    keep = [str(l).rstrip() for l in lines if str(l).strip()];
    if not keep { return; }
    with st.lock {
        last = st.blocks[-1] if st.blocks else None;
        if (last is not None) and (last.kind == "log") {
            last.text += chr(10) + chr(10).join(keep);
            last.ver += 1;
        } else { st.blocks.append(Block(kind="log", text=chr(10).join(keep))); }
    }
    st.poke(True);
}

def _drain(st: TuiState, fd: int) -> None {
    # Everything written to fd 1/2 while the app owns the screen: print()s, a
    # library's warning, a child process that inherited the descriptor. A "\r"
    # progress line keeps only what it last redrew.
    pend = "";
    while True {
        chunk: any = b"";
        try { chunk = os.read(fd, 4096); } except Exception { break; }
        if not chunk { break; }
        pend += chunk.decode("utf-8", "replace");
        if chr(10) not in pend { continue; }
        parts = pend.split(chr(10));
        pend = parts[-1];
        _log(st, [p.split(chr(13))[-1] for p in parts[:-1]]);
    }
    if pend { _log(st, [pend.split(chr(13))[-1]]); }
    try { os.close(fd); } except Exception {}
}

obj FdJail {
    has st: TuiState,
        saved: list[int] = [],
        active: bool = False;

    def enter -> None {
        try { sys.stdout.flush(); sys.stderr.flush(); } except Exception {}
        self.saved = [os.dup(0), os.dup(1), os.dup(2)];
        (r, w) = os.pipe();
        nul = os.open(os.devnull, os.O_RDONLY);
        os.dup2(nul, 0);
        os.dup2(w, 1);
        os.dup2(w, 2);
        os.close(nul);
        os.close(w);
        self.active = True;
        threading.Thread(target=_drain, args=(self.st, r), daemon=True, name="sigil-tui-log").start();
    }

    def leave -> None {
        if not self.active { return; }
        try { sys.stdout.flush(); sys.stderr.flush(); } except Exception {}
        for (i, fd) in enumerate(self.saved) {
            os.dup2(fd, i);
            os.close(fd);
        }
        self.saved = [];
        self.active = False;
    }
}

def _ui_thread(st: TuiState, app: any) -> None {
    try {
        # no exception handler of prompt_toolkit's own: it would answer a bug in
        # a key binding with "Press ENTER to continue" on a screen it has just
        # left. asyncio's default logs it to stderr, which lands in the
        # transcript, and the app carries on.
        app.run(set_exception_handler=False);
    } except BaseException {
        st.ui_error = traceback.format_exc();
    } finally {
        st.ui_alive = False;
        # only an unasked-for exit is news to the main thread
        if not st.closing { st.events.put(["ui-down", ""]); }
    }
}

def _ticker(st: TuiState) -> None {
    # repaint for the spinner and the elapsed clock; idle, nothing redraws
    while st.ui_alive {
        time.sleep(0.1);
        if st.busy or (st.flash and (time.monotonic() < (st.flash_until + 0.2))) { st.poke(True); }
    }
}

def _session(st: TuiState, app: any, turn_fn: any) -> str {
    st.closing = False;
    st.ui_alive = True;
    st.ui_error = "";
    th = threading.Thread(target=_ui_thread, args=(st, app), daemon=True, name="sigil-tui");
    th.start();
    threading.Thread(target=_ticker, args=(st,), daemon=True, name="sigil-tui-tick").start();
    try { return _drive(st, turn_fn); }
    finally {
        st.closing = True;
        _answer(st, False);
        # Ask until the thread is gone: right after start the app may not have
        # its event loop yet (app.loop is None) and a single ask would be lost.
        # A repeated ask is harmless — exit() on an exiting app just raises.
        def quit_app() -> None { try { app.exit(); } except Exception {} }
        deadline = time.monotonic() + 5.0;
        while th.is_alive() and (time.monotonic() < deadline) {
            loop = app.loop;
            if loop is not None { try { loop.call_soon_threadsafe(quit_app); } except Exception {} }
            th.join(timeout=0.1);
        }
        st.ui_hung = th.is_alive();
    }
}

def _restore_terminal(st: TuiState, saved_tty: any) -> None {
    # The safety net under prompt_toolkit's own cleanup. Cooked mode back is
    # always right (a no-op after a clean exit). The escape sequences go out
    # only if the UI thread never finished — then nobody else will send them,
    # and the shell would come back on the alternate screen, without echo,
    # with every mouse movement typed into it.
    if saved_tty is not None {
        try {
            import termios;
            termios.tcsetattr(st.tty_fd, termios.TCSADRAIN, saved_tty);
        } except Exception {}
    }
    if st.ui_hung {
        esc = chr(27) + "[";
        seq = esc + "?1049l" + esc + "?1000l" + esc + "?1003l" + esc + "?1006l" + esc + "?1015l"
              + esc + "?2004l" + esc + "?25h" + esc + "0m";
        try { os.write(st.tty_fd, seq.encode("ascii")); } except Exception {}
    }
}

# ---------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------
def tui_chat(turn: any = None) -> None {
    # `turn` is chat_turn unless a caller hands in a stand-in with its contract:
    # message -> {"reply": str, "interrupted": bool}.
    turn_fn = turn if turn is not None else chat_turn;
    st = TuiState(lock=threading.RLock(), events=queue.Queue(), approval_lock=threading.Lock(),
                  main_ident=threading.get_ident());
    tin: any = None;
    tout: any = None;
    try {
        tin = os.fdopen(os.dup(0), "r", encoding="utf-8", errors="replace");
        tout = os.fdopen(os.dup(1), "w", encoding="utf-8", errors="replace");
        st.tty_fd = tout.fileno();
        inp = create_input(stdin=tin);
        out = create_output(stdout=tout);
    } except Exception {
        # no terminal this process can own — the inline REPL still works
        for f in [tin, tout] { if f is not None { try { f.close(); } except Exception {} } }
        chat_repl();
        return;
    }
    _sync_toolbar();
    try { st.width = int(os.get_terminal_size(st.tty_fd).columns); } except Exception { st.width = 100; }
    c = _console(st.width);
    _banner(c);
    st.add(Block(kind="ansi", text=c.file.getvalue()));
    buf = Buffer(
        multiline=True,
        history=FileHistory(os.path.expanduser("~/.sigil_chat_history")),
        completer=SlashCompleter(),
        complete_while_typing=True,
        auto_suggest=AutoSuggestFromHistory()
    );
    app = _build_app(st, buf, inp, out);
    st.app = app;
    saved_tty: any = None;
    try {
        import termios;
        saved_tty = termios.tcgetattr(st.tty_fd);
    } except Exception {}
    _install(st);
    jail = FdJail(st=st);
    try {
        while True {
            jail.enter();
            action = "exit";
            try { action = _session(st, app, turn_fn); }
            finally {
                _restore_terminal(st, saved_tty);
                jail.leave();
            }
            if st.ui_error or st.ui_hung { break; }
            if action == "config" {
                # the settings editor is a line-by-line prompt: give it the real
                # screen, then take the alternate one back with the transcript intact
                config_menu();
                _sync_toolbar();
                continue;
            }
            break;
        }
    } finally {
        _uninstall();
        for f in [tin, tout] { try { f.close(); } except Exception {} }
    }
    console = Console();
    if st.ui_hung { console.print("[dim]  ⚠ the full-screen chat did not shut down in time; the terminal was restored by hand[/dim]"); }
    if st.ui_error {
        console.print("[red]  ✖ the full-screen chat stopped:[/red]");
        console.print(Text(st.ui_error.strip().split(chr(10))[-1], style="dim"));
        if st.turns == 0 {
            console.print("[dim]  falling back to the inline chat (sigil chat --classic skips straight to it)[/dim]");
            chat_repl();
            return;
        }
    }
    # Same farewell as the inline REPL, for the same reason: commit what is left
    # OURSELVES before jac's teardown does, and say a conflict in one line.
    warn = commit_now("chat session");
    console.print("[dim]bye ◆[/dim]");
    if warn {
        console.print("[dim]  ⚠ " + warn + "[/dim]");
        try { sys.stdout.flush(); } except Exception {}
        os._exit(0);
    }
}
