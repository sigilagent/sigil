"""Sigil interactive chat — a conversational, tool-using REPL you can run the whole
agent from. Unlike the one-shot `solve`, this drives `chat_agent`: a single ReAct
loop with the full tool-belt (workspace files + shell, web, cron, memory, skills,
MCP, channels, parallel sub-agents), holding a running conversation.

    jac run main.jac -s sigil.session -- chat
    jac run main.jac -s sigil.session -- config

The REPL streams the reply token-by-token, shows a LIVE trace of every tool the agent
calls (with a thinking spinner between them), and prompts inline to approve any shell
command the exec policy gates. All of it drives the SAME persistent graph as the one-shot
commands, so a fact remembered or a job scheduled in chat is there for `solve`, cron, and
the Observatory too.

Rendering uses `rich`; input is the sigil_input.jac editor — multiline (Enter sends,
Ctrl-J newlines), a "/" command palette with argument completion, fish-style history
suggestions and a status toolbar — falling back to builtin input() when piped (so it
stays scriptable).
"""

import sys;
import os;
import re;
import time;
import from .sigil_logo { BANNER_LOGO }
import from .sigil_core { describe_soul, configure, library, recollect, teach }
import from .sigil_skill_tools { skill_tool_index, tool_name }
import from .approvals { peek_exec }
import from .chat_agent { chat_turn, chat_reset, set_token_sink }
import from .cron { cron_list }
import from .sigil_workspace { set_trace_sink, set_approver, workspace_info }
import from .sigil_runtime { commit_now }
import from .sigil_channels_setup { channels_overview, channel_setup_guide, channel_bootstrap }
import from .sigil_docs { list_docs, read_doc }
import from .sigil_input { COMMANDS, make_session, make_plain_session, prompt_text, set_toolbar }
import from rich.console { Console }
import from rich.panel { Panel }
import from rich.table { Table }
import from rich.text { Text }
import from rich.markdown { Markdown }

def _to_int(s: str, dflt: int) -> int {
    try { return int(s); } except Exception as e { return dflt; }
}

# ---------------------------------------------------------------------------
# rendering helpers
# ---------------------------------------------------------------------------
def _version() -> str {
    # read the project version from jac.toml (one dir up from this package), so the
    # banner never drifts from the manifest.
    try {
        here = os.path.dirname(os.path.abspath(__file__));
        toml = os.path.join(os.path.dirname(here), "jac.toml");
        with open(toml, "r") as f { lines = f.read().split(chr(10)); }
        for ln in lines {
            t = ln.strip();
            if t.startswith("version") and ("=" in t) { return t.split("=")[1].strip().strip('"').strip("'"); }
        }
    } except Exception as e {}
    return "?";   # jac.toml unreadable: show v? rather than lie with a stale number
}

def _banner(console: any) {
    # The hexagonal graph mark from the website: 6 nodes, spokes converging on the
    # cyan triangle-and-core (the 'compiled graph'), the SIGIL wordmark, version, and
    # base config — side by side.
    s = describe_soul();
    wi = workspace_info();
    cm = str(s["chat_model"]) if s["chat_model"] else "unset";
    logo = "\n".join(BANNER_LOGO);
    info = (
        "[bold #a78bfa]S I G I L[/]  [dim]v" + _version() + "[/]\n"
        + "[dim]the whole agent, from one conversation[/]\n\n"
        + "[dim]model    [/] " + cm + "\n"
        + "[dim]workspace[/] " + str(wi["root"]) + "\n"
        + "[dim]sandbox  [/] " + str(wi["sandbox"]) + "\n"
        + "[dim]skills   [/] " + str(s["skills"])
    );
    t = Table(show_header=False, box=None, pad_edge=False, padding=(0, 2));
    t.add_column(); t.add_column(vertical="middle");
    t.add_row(logo, info);
    console.print();
    console.print(t);
    console.print("  [dim]just say what you want — files, shell, web, cron, memory, sub-agents. /help · /exit[/dim]");
    console.print();
}

def _help(console: any) {
    # rendered from sigil_input's COMMANDS — the same table that powers the "/"
    # palette, so help and completion can never drift apart.
    import from rich.markup { escape }
    console.print();
    console.print("[bold]commands[/bold]");
    # escape AFTER padding: "[topic]" would otherwise read as a rich tag and
    # vanish, and escaping first would pad to the wrong visible width.
    for r in COMMANDS { console.print("  [cyan]" + escape(str(r[0]).ljust(28)) + "[/cyan] [dim]" + str(r[1]) + "[/dim]"); }
    console.print("  [dim]anything else is a message to the agent — it will use its tools to act.[/dim]");
    console.print();
}

def _sync_toolbar() {
    # the editor's toolbar reads a plain string on every keystroke; the graph
    # read that produces it happens only here — at startup and on config change.
    try {
        s = describe_soul();
        wi = workspace_info();
        cm = str(s["chat_model"]) if s["chat_model"] else "model unset";
        set_toolbar("◆ " + cm + "  ·  sandbox " + str(wi["sandbox"]) + "  ·  " + str(s["skills"]) + " skills");
    } except Exception { set_toolbar(""); }
}

def _tool_style(tool: str) -> str {
    warm = ["exec", "write", "edit", "schedule", "unschedule", "message", "learn", "kill", "compile"];
    return "yellow" if tool in warm else "cyan";
}

def _show_tools(console: any) {
    groups = [
        ["files", "ws_list · ws_read · ws_write · ws_edit · ws_tree · ws_grep"],
        ["shell", "ws_exec · ws_watch · ws_kill · ws_jobs  (approval-gated, never timed out)"],
        ["web", "web_search · web_fetch  (SSRF-guarded)"],
        ["cron", "schedule_task · list_scheduled · cancel_scheduled"],
        ["memory", "remember_fact · recall_memory"],
        ["skills", "sigil_compile · learn_skill · list_skills"],
        ["sub-agents", "spawn_subagent · spawn_parallel  (flow/wait, concurrent)"],
        ["external", "mcp_call · send_message"]
    ];
    t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
    t.add_column("group"); t.add_column("tools");
    for g in groups { t.add_row("[cyan]" + g[0] + "[/cyan]", "[dim]" + g[1] + "[/dim]"); }
    console.print(); console.print(t); console.print();
}

def _show_workspace(console: any) {
    wi = workspace_info();
    console.print();
    console.print("[bold]workspace[/bold] " + str(wi["root"]));
    console.print("  [dim]sandbox[/dim] " + str(wi["sandbox"]) + "   [dim]items[/dim] " + str(wi["items"]) + "   [dim]shell jobs[/dim] " + str(wi["jobs"]) + " (" + str(wi["running"]) + " running)");
    console.print("  [dim]" + ("relative paths land here; absolute paths and shell run on the real host"
                               if wi["sandbox"] == "off"
                               else ("file tools are jailed here; shell runs" + (" in docker" if wi["sandbox"] == "docker" else " from here")))
                  + ", approval-gated. Nothing is killed on a timer.[/dim]");
    console.print();
}

def _show_channels(console: any) {
    ov = channels_overview();
    console.print();
    console.print("[bold]channels[/bold]");
    console.print("  [dim]supported[/dim]  " + ", ".join([str(k) for k in list(ov["supported"])]));
    configured = list(ov["configured"]);
    if configured {
        t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
        t.add_column("name"); t.add_column("kind"); t.add_column("on"); t.add_column("msgs", justify="right");
        for c in configured { t.add_row(str(c["name"]), str(c["kind"]), ("on" if c["enabled"] else "off"), str(c["messages"])); }
        console.print(t);
    } else {
        console.print("  [dim](none configured — /connect <kind> for setup steps)[/dim]");
    }
    console.print();
}

def _show_connect(console: any, kind: str) {
    if not kind { console.print("[dim]  usage: /connect <discord|telegram|whatsapp|slack>[/dim]"); return; }
    console.print();
    console.print(Panel(Text(channel_setup_guide(kind)), title="[dim]connect " + kind + "[/dim]",
                        title_align="left", border_style="grey37", padding=(0, 1)));
    console.print();
}

def _show_docs(console: any, topic: str) {
    console.print();
    if topic {
        try { console.print(Markdown(read_doc(topic))); }
        except Exception as e { console.print(Text(read_doc(topic))); }
    } else {
        console.print(Text(list_docs()));
        console.print("[dim]  /docs <topic> to read one[/dim]");
    }
    console.print();
}

def _show_cron(console: any) {
    js = cron_list();
    if not js { console.print("[dim]  (no scheduled jobs)[/dim]"); return; }
    t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
    t.add_column("name"); t.add_column("when"); t.add_column("on"); t.add_column("runs", justify="right"); t.add_column("task");
    for j in js {
        t.add_row(str(j["name"]), str(j["kind"]) + " " + str(j["spec"]), ("on" if j["enabled"] else "off"), str(j["runs"]), str(j["task"]));
    }
    console.print(); console.print(t); console.print();
}

def _show_soul(console: any) {
    s = describe_soul();
    console.print();
    console.print("[bold magenta]soul[/bold magenta] " + str(s["name"]));
    console.print("  [dim]persona [/dim] ", Text(str(s["persona"]) if s["persona"] else "(unset)"));
    console.print("  [dim]models  [/dim] chat=" + str(s["chat_model"]) + "  frontier=" + str(s["frontier_model"]) + "  small=" + str(s["small_model"]) + "  router=" + str(s["router_model"]));
    console.print("  [dim]sandbox [/dim] " + str(s["sandbox"]) + "   [dim]workspace[/dim] " + str(s["workspace"]) + "   [dim]skills[/dim] " + str(s["skills"]));
    eth = list(s["ethos"]);
    if eth {
        console.print("  [dim]ethos[/dim]");
        for e in eth { console.print("    • ", Text(str(e))); }
    }
    mems = list(s["memories"]);
    if mems {
        console.print("  [dim]memory[/dim]");
        for m in mems { console.print("    [dim](" + str(m["kind"]) + ")[/dim] ", Text(str(m["content"]))); }
    }
    console.print();
}

def _show_library(console: any) {
    lib = library();
    if not lib { console.print("[dim]  (no compiled skills yet)[/dim]"); return; }
    # `tool` and `gate` are the two questions an operator actually has about a
    # compiled skill now that the agent can reach for one on its own: what name
    # does it answer to, and what stands between the model and running it.
    offered = {str(r["signature"]) for r in skill_tool_index()};
    t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
    t.add_column("skill"); t.add_column("v"); t.add_column("origin");
    t.add_column("runs", justify="right"); t.add_column("ok", justify="right");
    t.add_column("tool"); t.add_column("gate");
    for e in lib {
        sig = str(e["signature"]);
        on = sig in offered;
        gate_txt = "[dim]denied[/dim]";
        if on {
            dec = peek_exec("skill:" + sig);
            gate_txt = "[green]allowed[/green]" if dec == "allow" else (
                       "[red]denied[/red]" if dec == "deny" else "[yellow]asks first[/yellow]");
        }
        t.add_row(sig, "v" + str(e["version"]), str(e["origin"]), str(e["runs"]),
                  str(e["successes"]), (tool_name(sig) if on else "[dim]—[/dim]"), gate_txt);
    }
    console.print(t);
}

# ---------------------------------------------------------------------------
# live tool trace + a "thinking" spinner + inline exec approver.
# The spinner is a rich status (its own refresh thread, so it animates while the
# model blocks on the network); completed tool calls stream ABOVE it, and it pauses
# cleanly for the approval prompt so input isn't fighting the animation.
# ---------------------------------------------------------------------------
glob _STATUS: any = None;    # the live spinner handle, set for the duration of a turn
glob _STREAMED: bool = False; # did the reply stream any tokens this turn? (skip re-render if so)
glob _GUTTER_MU: str = "[#a78bfa]│[/] ";   # purple left-border, as rich markup, on each reply line
glob _REPLYBUF: dict[str, str] = {"s": ""};   # the whole reply accumulated so far this turn
glob _LIVE: any = None;                        # the rich Live region rendering it (None = not streaming)
glob _LIVE_T: dict[str, float] = {"last": 0.0};   # last re-render time, for throttling

def _body_width(console: any) -> int {
    try { w = int(console.width); } except Exception as e { w = 80; }
    return max(20, w - 2);   # the gutter itself costs "│ "

}

def _guttered_markdown(console: any, md_text: str) -> any {
    # Render the reply-so-far as REAL markdown — rich's Markdown, the same
    # renderer the non-streaming path uses — and hang the purple gutter off every
    # produced line. Partial markdown is fine: an unterminated ```fence, a
    # half-built table or a dangling ** renders as far as it parses and snaps into
    # shape as more tokens arrive. This is why the streamed answer now gets
    # ordered/nested lists, tables and blockquotes the old line-at-a-time styler
    # could never do — we re-render the whole buffer, not one line, each tick.
    import from rich.markdown { Markdown }
    w = _body_width(console);
    md = Markdown(str(md_text), code_theme="ansi_dark", inline_code_theme="ansi_dark");
    opts = console.options.update(width=w);
    rows: list = [];
    for segs in console.render_lines(md, opts, pad=False) {
        row = Text.from_markup(_GUTTER_MU);
        for s in segs {
            t = str(s.text).replace(chr(10), "");
            if t { row.append(t, s.style); }
        }
        rows.append(row);
    }
    # Markdown pads a trailing blank line after each block; drop trailing rows
    # that are only the gutter so the block doesn't end on a dangling "│".
    while rows and (not str(rows[-1].plain).replace(chr(0x2502), " ").strip()) { rows.pop(); }
    out = Text();
    for (i, r) in enumerate(rows) {
        if i { out.append(chr(10)); }
        out.append_text(r);
    }
    if not rows { out = Text.from_markup(_GUTTER_MU); }
    return out;
}

def _live_render(console: any) {
    # Rebuild the markdown view from the whole buffer and repaint the Live region.
    if _LIVE is None { return; }
    try { _LIVE.update(_guttered_markdown(console, str(_REPLYBUF["s"])), refresh=True); }
    except Exception as e {  }
}

def _flush_reply(console: any) {
    # End of turn: one last full re-render (so the final frame is the complete,
    # fully-formatted reply left in scrollback), then retire the Live region.
    if _LIVE is not None {
        _live_render(console);
        try { _LIVE.stop(); } except Exception as e {  }
        _LIVE = None;
    }
    _REPLYBUF["s"] = "";
}

# Width of the "  ✓ toolname   " gutter every trace line starts with. Continuation
# lines are padded to it so a long detail stays in the detail column instead of
# wrapping back to the screen edge and reading like the agent's own prose.
glob _TRACE_GUTTER: int = 16;

def _trace_rows(detail: str, width: int) -> list {
    import textwrap;
    w = width if width > 24 else 60;
    out: list = [];
    for para in str(detail).split(chr(10)) {
        if not para.strip() { continue; }
        for ln in (textwrap.wrap(para, width=w) or [para]) { out.append(str(ln)); }
    }
    return out if out else [""];
}

def _install_hooks(console: any, session: any) {
    def sink(tool: str, detail: str, ok: bool) {
        import from rich.markup { escape }
        mark = "✓" if ok else "✗";
        col = _tool_style(tool) if ok else "red";
        avail = 60;
        try { avail = int(console.width) - _TRACE_GUTTER; } except Exception as e {}
        pad = " " * _TRACE_GUTTER;
        first = True;
        for row in _trace_rows(detail, avail) {
            # escaped: a detail is arbitrary text (paths, patterns, job ids like
            # "[j1]") and rich would read a bracket as markup and blow up.
            body = "[dim]" + str(escape(str(row))) + "[/dim]";
            if first {
                console.print("  [dim]" + mark + "[/dim] [" + col + "]" + tool.ljust(11) + "[/" + col + "] " + body);
                first = False;
            } else { console.print(pad + body); }
        }
        if _STATUS is not None {
            try { _STATUS.update("[magenta]✦[/magenta] [dim]working — [/dim][" + col + "]" + tool + "[/" + col + "][dim]…[/dim]"); }
            except Exception as e {}
        }
    }
    def token_sink(piece: str) {
        # Accumulate the whole reply and re-render it as live markdown. On a
        # non-terminal (piped/scripted) stdout there is no Live region to drive —
        # leave _STREAMED False so the end-of-turn path prints the reply once with
        # rich Markdown, keeping scripts clean and still fully formatted.
        term = True;
        try { term = bool(console.is_terminal); } except Exception as e { term = True; }
        if not term { return; }
        if not _STREAMED {
            # first token ends the "thinking" phase: stop the spinner, print the
            # "◆ sigil" header, then open the Live region the answer renders into.
            _STREAMED = True;
            if _STATUS is not None { try { _STATUS.stop(); } except Exception as e {} }
            console.print();
            console.print("[#a78bfa]◆[/] [dim]sigil[/]");
            import from rich.live { Live }
            # auto_refresh off: WE repaint on throttle, so a background thread
            # never paints a half-token frame or fights the spinner teardown.
            # vertical_overflow visible: a reply taller than the screen scrolls
            # naturally instead of being cropped to the last N lines.
            _LIVE = Live(console=console, auto_refresh=False, vertical_overflow="visible");
            try { _LIVE.start(); } except Exception as e {  }
            _LIVE_T["last"] = 0.0;
        }
        _REPLYBUF["s"] += str(piece);
        # Re-rendering the whole markdown buffer every token is O(n) per token;
        # throttle to ~12fps (and always on a newline, which usually closes a
        # block worth showing) so a long reply stays cheap and flicker-free.
        now = time.monotonic();
        if (chr(10) in str(piece)) or (now - float(_LIVE_T["last"]) >= 0.08) {
            _LIVE_T["last"] = now;
            _live_render(console);
        }
    }
    def approver(command: str) -> bool {
        # One prompt for two gates. A shell command arrives as itself; a compiled
        # skill the agent reached for on its own arrives as `skill:<signature>
        # <task>` (src/sigil_skill_tools.gate), and saying yes allows that SKILL
        # from here on — not that one run — which is why the label has to say
        # which of the two is being asked about.
        paused = False;
        if _STATUS is not None { try { _STATUS.stop(); paused = True; } except Exception as e {} }
        is_skill = str(command).startswith("skill:");
        if is_skill {
            console.print("  [yellow]⚠ approve skill[/yellow] [dim]" + str(command)[6:] + "[/dim]");
        } else {
            console.print("  [yellow]⚠ approve shell[/yellow] [dim]" + command + "[/dim]");
        }
        decided = False;
        try {
            ans = str(prompt_text(session, "    run this skill? [y/N] " if is_skill else "    run this? [y/N] ")).strip().lower();
            decided = ans in ["y", "yes"];
        }
        except Exception as e { decided = False; }
        if paused { try { _STATUS.start(); } except Exception as e {} }
        return decided;
    }
    set_trace_sink(sink);
    set_token_sink(token_sink);
    set_approver(approver);
}

def _run_and_render(console: any, message: str) {
    _STREAMED = False;
    # Per-turn render state: a stale buffer would prefix the next answer, and a
    # Live left open from a crashed turn would keep repainting over it.
    _REPLYBUF["s"] = "";
    _LIVE = None;
    _LIVE_T["last"] = 0.0;
    r: dict = {};
    if sys.stdin.isatty() {
        st = console.status("[magenta]✦[/magenta] [dim]thinking…[/dim]", spinner="dots", spinner_style="magenta");
        st.start();
        _STATUS = st;
        # finally, not straight-line: chat_turn catches errors AND ^C, but if
        # anything ever escapes it the spinner thread must still be torn down or
        # it keeps repainting over the prompt for the rest of the session.
        try { r = chat_turn(message); }
        finally {
            try { st.stop(); } except Exception as e {}
            _STATUS = None;
        }
    } else {
        r = chat_turn(message);
    }
    interrupted = bool(r.get("interrupted") or False);
    if _STREAMED {
        # A reply almost never ends with a newline, so the last line is still in the
        # buffer — flush it or the final sentence never reaches the screen.
        _flush_reply(console);
        if interrupted { console.print("[dim]  ✂ interrupted (^C) — reply cut short[/dim]"); }
        console.print();
    } elif interrupted {
        # ^C before the first token: there is no reply to render, just say what happened
        console.print();
        console.print("[dim]  ✂ interrupted (^C)[/dim]");
        console.print();
    } else {
        # nothing streamed (empty reply, or an error before the first token) — render it
        console.print();
        console.print("[#a78bfa]◆[/] [dim]sigil[/]");
        try { console.print(Markdown(str(r["reply"]))); }
        except Exception as e { console.print(Text(str(r["reply"]))); }
        console.print();
    }
}

# ---------------------------------------------------------------------------
# slash commands
# ---------------------------------------------------------------------------
# Slash-command writes (teach/configure) mutate the graph in THIS long-lived
# process. Commit each one as it happens instead of betting the whole session's
# writes on the once-at-exit commit racing the daemon (see commit_now).
def _commit_ui(console: any, context: str) {
    warn = commit_now(context);
    if warn { console.print("[dim]  ⚠ " + warn + "[/dim]"); }
}

def _handle_slash(console: any, cmd: str) -> bool {
    parts = cmd.split(" ", 1);
    verb = str(parts[0]).lower();
    rest = str(parts[1]).strip() if len(parts) > 1 else "";
    if verb in ["/exit", "/quit", "/q"] { return True; }
    elif verb in ["/help", "/?", "/h"] { _help(console); }
    elif verb == "/soul" { _show_soul(console); }
    elif verb == "/config" { config_menu(); _sync_toolbar(); }
    elif verb == "/tools" { _show_tools(console); }
    elif verb == "/workspace" { _show_workspace(console); }
    elif verb == "/cron" { _show_cron(console); }
    elif verb == "/channels" { _show_channels(console); }
    elif verb == "/connect" { _show_connect(console, rest); }
    elif verb == "/docs" { _show_docs(console, rest); }
    elif verb in ["/skills", "/library"] { _show_library(console); }
    elif verb == "/clear" { console.clear(); }
    elif verb == "/reset" { console.print("[green]  ✓[/green] [dim]" + str(chat_reset()) + "[/dim]"); }
    elif verb == "/sandbox" {
        if rest { console.print("[green]  ✓[/green] [dim]" + str(configure("sandbox", rest)) + "[/dim]"); _sync_toolbar(); _commit_ui(console, "/sandbox"); }
        else { console.print("[dim]  usage: /sandbox <off|jail|docker>   (currently " + str(workspace_info()["sandbox"]) + ")[/dim]"); }
    }
    elif verb in ["/remember", "/teach"] {
        if rest {
            try {
                console.print("[green]  ✓[/green] [dim]" + str(teach(rest, "fact")) + "[/dim]");
                _commit_ui(console, "/remember");
            } except Exception as _rerr {
                console.print("[red]  ✖[/red] [dim]" + str(_rerr)[:200] + "[/dim]");
            }
        }
        else { console.print("[dim]  usage: /remember <fact>[/dim]"); }
    }
    elif verb == "/recall" {
        ms = recollect(rest, 8);
        if not ms { console.print("[dim]  (nothing found)[/dim]"); }
        for m in ms { console.print("  [dim](" + str(m["kind"]) + ")[/dim] ", Text(str(m["content"]))); }
    }
    elif verb == "/model" {
        mp = rest.split(" ", 1);
        if len(mp) == 2 { console.print("[green]  ✓[/green] [dim]" + str(configure(str(mp[0]).strip() + "_model", str(mp[1]).strip())) + "[/dim]"); _sync_toolbar(); _commit_ui(console, "/model"); }
        else { console.print("[dim]  usage: /model <frontier|small|router|chat> <name>[/dim]"); }
    }
    else { console.print("[dim]  unknown command " + verb + " — /help[/dim]"); }
    return False;
}

# ---------------------------------------------------------------------------
# the chat REPL
# ---------------------------------------------------------------------------
def chat_repl() {
    console = Console();
    session = make_session();
    # approvals get a bare single-line session: no palette, no toolbar, and a
    # "y" typed there never lands in the chat history file.
    _install_hooks(console, make_plain_session());
    _sync_toolbar();
    _banner(console);
    # colour the prompt so each user turn stands out from the reply block above it
    user_prompt = chr(27) + "[38;5;141msigil" + chr(27) + "[0m " + chr(27) + "[1m›" + chr(27) + "[0m ";
    while True {
        line = "";
        try {
            line = prompt_text(session, user_prompt);
        } except EOFError as e {
            console.print();
            break;
        } except KeyboardInterrupt as e {
            console.print("[dim]  (^C · type /exit to quit)[/dim]");
            continue;
        }
        cmd = str(line).strip();
        if not cmd { continue; }
        if cmd.startswith("/") {
            if _handle_slash(console, cmd) { break; }
            continue;
        }
        try {
            _run_and_render(console, cmd);
        } except KeyboardInterrupt {
            # last-resort net: a ^C that lands outside chat_turn's own guard
            # (during rendering, or in an approval prompt) still only ends the
            # TURN — the REPL survives.
            console.print();
            console.print("[dim]  ✂ interrupted (^C)[/dim]");
        }
    }
    # Commit any remaining graph writes OURSELVES, before jac's CLI teardown
    # does its once-at-exit commit. If an anchor moved under us (a daemon tick
    # landed since the last eager commit), that teardown commit dies in a raw
    # WriteConflict traceback ON TOP of the farewell — with the session's
    # writes rolled back either way. Say it in one honest line instead, then
    # hard-exit so the doomed changeset is never re-collected by the teardown.
    warn = commit_now("chat session");
    console.print("[dim]bye ◆[/dim]");
    if warn {
        console.print("[dim]  ⚠ " + warn + "[/dim]");
        # os._exit skips interpreter teardown INCLUDING stdout flushing — if
        # stdout is a pipe the farewell would vanish with the process.
        try { sys.stdout.flush(); } except Exception as e {}
        os._exit(0);
    }
}

# ---------------------------------------------------------------------------
# first-run setup wizard — a few questions to configure the model tiers + persona
# ---------------------------------------------------------------------------
def setup_wizard() {
    console = Console();
    session = make_plain_session();
    console.print();
    console.print("[bold magenta]  ◆ Sigil setup[/bold magenta] [dim]· a few quick questions (press Enter to accept a default)[/dim]");
    console.print();
    steps = [
        ["chat_model", "Which model do you TALK to in chat? (use a strong one)", "gpt-4o"],
        ["frontier_model", "Which model builds new skills? (also strong)", "gpt-4o"],
        ["small_model", "Which cheap/local model RUNS compiled skills?", "gpt-4o-mini"],
        ["persona", "In a line, how should your agent describe itself? (optional)", ""]
    ];
    for st in steps {
        key = st[0]; question = st[1]; default = st[2];
        hint = ("  [" + default + "]") if default else "  (optional)";
        console.print("  [cyan]" + question + "[/cyan][dim]" + hint + "[/dim]");
        val = "";
        try { val = str(prompt_text(session, "  › ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { console.print(); return; }
        if (not val) and default { val = default; }
        if val { console.print("[green]  ✓[/green] [dim]" + str(configure(key, val)) + "[/dim]"); _commit_ui(console, "setup"); }
        console.print();
    }
    s = describe_soul();
    console.print("[bold]  You're set.[/bold] [dim]chat=" + str(s["chat_model"]) + "  frontier=" + str(s["frontier_model"]) + "  small=" + str(s["small_model"]) + "[/dim]");
    console.print("  [dim]Try:  [/dim][cyan]sigil chat[/cyan][dim]   or   [/dim][cyan]sigil solve \"…\"[/cyan]");
    console.print();
}

# ---------------------------------------------------------------------------
# interactive settings editor
# ---------------------------------------------------------------------------
def config_menu() {
    console = Console();
    session = make_plain_session();
    fields = [
        ["name", "agent name"],
        ["persona", "voice / character it speaks with"],
        ["chat_model", "conversational model — powers chat mode & sub-agents"],
        ["frontier_model", "expensive model — compiles new skills"],
        ["small_model", "cheap model — executes compiled skills"],
        ["router_model", "model that routes a task to a skill"],
        ["workspace", "default directory the tools work in"],
        ["sandbox", "tool containment: off | jail | docker"],
        ["auto_eval", "self-check each run, on/off"],
        ["eval_threshold", "auto-relearn below this score (0-100)"]
    ];
    while True {
        s = describe_soul();
        cur = {
            "name": str(s["name"]), "persona": str(s["persona"]),
            "chat_model": str(s["chat_model"]),
            "frontier_model": str(s["frontier_model"]), "small_model": str(s["small_model"]),
            "router_model": str(s["router_model"]),
            "workspace": str(s["workspace"]), "sandbox": str(s["sandbox"]),
            "auto_eval": ("on" if s["auto_eval"] else "off"),
            "eval_threshold": str(s["eval_threshold"])
        };
        t = Table(title="⚙  sigil settings", title_style="bold", show_header=True,
                  header_style="dim", box=None, pad_edge=False);
        t.add_column("#", justify="right"); t.add_column("setting"); t.add_column("value"); t.add_column("");
        i = 1;
        for f in fields {
            v = cur[f[0]] if cur[f[0]] else "(unset)";
            t.add_row("[cyan]" + str(i) + "[/cyan]", f[0], v, "[dim]" + f[1] + "[/dim]");
            i += 1;
        }
        console.print();
        console.print(t);
        choice = "";
        try { choice = str(prompt_text(session, "edit # (blank = done) › ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { return; }
        if choice in ["", "0", "q", "done", "exit"] { return; }
        idx = _to_int(choice, 0) - 1;
        if (idx < 0) or (idx >= len(fields)) { console.print("[dim]  no such option[/dim]"); continue; }
        fk = fields[idx][0];
        newval = "";
        try { newval = str(prompt_text(session, "  " + fk + " = ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { continue; }
        if not newval { continue; }
        console.print("[green]  ✓[/green] [dim]" + str(configure(fk, newval)) + "[/dim]");
        _commit_ui(console, "config");
    }
}
