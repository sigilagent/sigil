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

Rendering uses `rich`; line editing/history uses `prompt_toolkit` in a real terminal,
falling back to builtin input() when piped (so it stays scriptable).
"""

import sys;
import os;
import from .sigil_logo { BANNER_LOGO }
import from .sigil { describe_soul, configure, library, recollect, teach, config_status, compile_skill }
import from .sigil_examples { examples_list }
import from .chat_agent { chat_turn, chat_reset, set_token_sink }
import from .cron { cron_list }
import from .sigil_workspace { set_trace_sink, set_approver, workspace_info }
import from .sigil_channels_setup { channels_overview, channel_setup_guide, channel_bootstrap }
import from .sigil_docs { list_docs, read_doc }
import from rich.console { Console }
import from rich.panel { Panel }
import from rich.table { Table }
import from rich.text { Text }
import from rich.markdown { Markdown }

# ---------------------------------------------------------------------------
# input plumbing — prompt_toolkit in a TTY (history + arrows), input() otherwise
# ---------------------------------------------------------------------------
def _make_session() -> any {
    if not sys.stdin.isatty() { return None; }
    try {
        import from prompt_toolkit { PromptSession }
        import from prompt_toolkit.history { FileHistory }
        return PromptSession(history=FileHistory(os.path.expanduser("~/.sigil_chat_history")));
    } except Exception as e { return None; }
}

def _prompt(session: any, msg: str) -> str {
    if session is not None {
        try {
            import from prompt_toolkit { ANSI }
            return str(session.prompt(ANSI(msg)));   # lets the prompt carry ANSI colour
        } except Exception as e { return str(session.prompt(msg)); }
    }
    return str(input(msg));
}

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
        + "[dim]the skill compiler — [/][#a78bfa]SKILL.md[/][dim] in, a runnable agent out[/]\n\n"
        + "[dim]model    [/] " + cm + "\n"
        + "[dim]workspace[/] " + str(wi["root"]) + "\n"
        + "[dim]sandbox  [/] " + str(wi["sandbox_mode"]) + "\n"
        + "[dim]skills   [/] " + str(s["skills"])
    );
    t = Table(show_header=False, box=None, pad_edge=False, padding=(0, 2));
    t.add_column(); t.add_column(vertical="middle");
    t.add_row(logo, info);
    console.print();
    console.print(t);
    console.print("  [#a78bfa]◆ compile a skill →[/] [cyan]/compile <SKILL.md>[/cyan]   [dim]· starters:[/dim] [cyan]/examples[/cyan]");
    console.print("  [dim]…or just say what you want — files, shell, web, cron, memory, sub-agents. /help · /exit[/dim]");
    console.print();
}

def _help(console: any) {
    rows = [
        ["/compile <SKILL.md>", "compile a skill file into a runnable agent — Sigil's core"],
        ["/examples", "starter SKILL.md files to compile (+ fetched packs)"],
        ["/help", "show this help"],
        ["/soul", "identity, models, skills & memory"],
        ["/config", "edit settings interactively"],
        ["/tools", "the tool-belt the agent can use"],
        ["/workspace", "show the sandboxed workspace"],
        ["/sandbox <jail|docker|off>", "set exec sandbox mode"],
        ["/cron", "list scheduled jobs"],
        ["/channels", "channels: supported + configured"],
        ["/connect <kind>", "how to connect discord|telegram|whatsapp|slack"],
        ["/docs [topic]", "Sigil's reference — how it works, config, tools"],
        ["/skills", "list compiled skills"],
        ["/model <tier> <name>", "set frontier|small|router|chat model"],
        ["/remember <fact>", "store a durable memory"],
        ["/recall <query>", "search memories"],
        ["/reset", "clear the conversation (keeps graph)"],
        ["/clear", "clear the screen"],
        ["/exit", "quit (also Ctrl-D)"]
    ];
    console.print();
    console.print("[bold]commands[/bold]");
    for r in rows { console.print("  [cyan]" + r[0].ljust(28) + "[/cyan] [dim]" + r[1] + "[/dim]"); }
    console.print("  [dim]anything else is a message to the agent — it will use its tools to act.[/dim]");
    console.print();
}

def _tool_style(tool: str) -> str {
    warm = ["exec", "write", "edit", "schedule", "unschedule", "message", "learn"];
    return "yellow" if tool in warm else "cyan";
}

def _show_tools(console: any) {
    groups = [
        ["files", "ws_list · ws_read · ws_write · ws_edit"],
        ["shell", "ws_exec  (sandboxed + approval-gated)"],
        ["web", "web_search · web_fetch  (SSRF-guarded)"],
        ["cron", "schedule_task · list_scheduled · cancel_scheduled"],
        ["memory", "remember_fact · recall_memory"],
        ["skills", "learn_skill · list_skills"],
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
    console.print("  [dim]sandbox_mode[/dim] " + str(wi["sandbox_mode"]) + "   [dim]docker[/dim] " + ("available" if wi["docker"] else "n/a") + "   [dim]items[/dim] " + str(wi["items"]));
    console.print("  [dim]file tools are jailed here; shell runs approval-gated" + (" in docker" if wi["sandbox_mode"] == "docker" else " cwd-confined") + "[/dim]");
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
    console.print("  [dim]sandbox [/dim] " + str(s["sandbox_mode"]) + "   [dim]workspace[/dim] " + str(s["workspace"]) + "   [dim]skills[/dim] " + str(s["skills"]));
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

def _show_examples(console: any) {
    ex = examples_list();
    console.print();
    console.print("[bold]starter skills[/bold] [dim]— /compile any of these into a runnable agent[/dim]");
    for e in list(ex["bundled"]) {
        console.print("  [cyan]" + str(e["path"]) + "[/cyan]");
        if e["desc"] { console.print("    [dim]" + str(e["desc"]) + "[/dim]"); }
    }
    packs = list(ex["packs"]);
    if packs {
        console.print("  [dim]fetched packs (~/.sigil/skills):[/dim]");
        for p in packs { console.print("    " + str(p["name"]) + "  [dim]" + str(p["count"]) + " skills · " + str(p["path"]) + "[/dim]"); }
    }
    console.print("  [dim]fetch more:[/dim] [cyan]sigil examples fetch superpowers[/cyan]");
    console.print();
}

def _do_compile(console: any, arg: str) {
    parts = [p for p in arg.split() if p];
    if not parts { console.print("[dim]  usage: /compile <path/to/SKILL.md> [-e agent.jac][/dim]"); return; }
    path = str(parts[0]);
    eject = False; eject_path = "";
    i = 1;
    while i < len(parts) {
        if parts[i] in ["-e", "--eject"] {
            eject = True;
            if ((i + 1) < len(parts)) and (not str(parts[i + 1]).startswith("-")) { eject_path = str(parts[i + 1]); i += 1; }
        }
        i += 1;
    }
    if not os.path.exists(path) { console.print("[red]  no such file:[/red] " + path); return; }
    console.print();
    console.print("  [#a78bfa]◐[/#a78bfa] compiling [cyan]" + path + "[/cyan] [dim]…[/dim]");
    def prog(ev: dict) {
        if str(ev.get("state")) == "done" {
            secs = float(ev.get("secs", 0.0));
            console.print("    [#22d3ee]✓[/#22d3ee] [dim]" + str(ev.get("stage")).ljust(10) + ("%.1f" % secs) + "s[/dim]");
        }
    }
    r: dict = {};
    try { r = compile_skill(open(path).read(), eject, eject_path, prog); }
    except Exception as e { console.print("  [red]compile error:[/red] " + str(e)[:200]); return; }
    if not r["ok"] {
        console.print("  [red]compile failed[/red] [dim]for '" + str(r["signature"]) + "':[/dim]");
        for iss in list(r["issues"] or []) { console.print("    [dim]- " + str(iss) + "[/dim]"); }
    } else {
        console.print("  [green]✓ compiled[/green] [bold]" + str(r["signature"]) + "[/bold] [dim]->[/dim] " + str(r["module"]));
        if r["eject"] { console.print("    [dim]ejected runnable:[/dim] [cyan]./" + str(r["eject"]) + "[/cyan] [dim]\"<task>\"[/dim]"); }
    }
    console.print();
}

def _show_library(console: any) {
    lib = library();
    if not lib { console.print("[dim]  (no compiled skills yet)[/dim]"); return; }
    t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
    t.add_column("skill"); t.add_column("v"); t.add_column("origin");
    t.add_column("runs", justify="right"); t.add_column("ok", justify="right");
    for e in lib {
        t.add_row(str(e["signature"]), "v" + str(e["version"]), str(e["origin"]), str(e["runs"]), str(e["successes"]));
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
glob _GUTTER: str = chr(27) + "[38;5;141m│" + chr(27) + "[0m ";  # purple left-border on each reply line

def _install_hooks(console: any, session: any) {
    def sink(tool: str, detail: str, ok: bool) {
        mark = "✓" if ok else "✗";
        col = _tool_style(tool) if ok else "red";
        console.print("  [dim]" + mark + "[/dim] [" + col + "]" + tool.ljust(11) + "[/" + col + "] [dim]" + str(detail) + "[/dim]");
        if _STATUS is not None {
            try { _STATUS.update("[magenta]✦[/magenta] [dim]working — [/dim][" + col + "]" + tool + "[/" + col + "][dim]…[/dim]"); }
            except Exception as e {}
        }
    }
    def token_sink(piece: str) {
        # first token ends the "thinking" phase: stop the spinner, print the "◆ sigil"
        # header, then stream the reply as a distinct block — a purple left-border gutter
        # on every line so each turn's answer is clearly bracketed and separated.
        if not _STREAMED {
            _STREAMED = True;
            if _STATUS is not None { try { _STATUS.stop(); } except Exception as e {} }
            console.print();
            console.print("[#a78bfa]◆[/] [dim]sigil[/]");
            sys.stdout.write(_GUTTER);
        }
        sys.stdout.write(str(piece).replace(chr(10), chr(10) + _GUTTER));
        sys.stdout.flush();
    }
    def approver(command: str) -> bool {
        paused = False;
        if _STATUS is not None { try { _STATUS.stop(); paused = True; } except Exception as e {} }
        console.print("  [yellow]⚠ approve shell[/yellow] [dim]" + command + "[/dim]");
        decided = False;
        try { ans = str(_prompt(session, "    run this? [y/N] ")).strip().lower(); decided = ans in ["y", "yes"]; }
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
    r: dict = {};
    if sys.stdin.isatty() {
        st = console.status("[magenta]✦[/magenta] [dim]thinking…[/dim]", spinner="dots", spinner_style="magenta");
        st.start();
        _STATUS = st;
        r = chat_turn(message);          # streams tokens via the sink; never raises (caught inside)
        try { st.stop(); } except Exception as e {}
        _STATUS = None;
    } else {
        r = chat_turn(message);
    }
    if _STREAMED {
        # tokens already rendered live in the gutter block — close it and add a
        # blank line so the next prompt is clearly separated.
        sys.stdout.write("\n");
        sys.stdout.flush();
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
def _handle_slash(console: any, cmd: str) -> bool {
    parts = cmd.split(" ", 1);
    verb = str(parts[0]).lower();
    rest = str(parts[1]).strip() if len(parts) > 1 else "";
    if verb in ["/exit", "/quit", "/q"] { return True; }
    elif verb in ["/compile", "/build"] { _do_compile(console, rest); }
    elif verb in ["/examples", "/starters"] { _show_examples(console); }
    elif verb in ["/help", "/?", "/h"] { _help(console); }
    elif verb == "/soul" { _show_soul(console); }
    elif verb == "/config" { config_menu(); }
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
        if rest { console.print("[green]  ✓[/green] [dim]" + str(configure("sandbox_mode", rest)) + "[/dim]"); }
        else { console.print("[dim]  usage: /sandbox <jail|docker|off>[/dim]"); }
    }
    elif verb in ["/remember", "/teach"] {
        if rest { console.print("[green]  ✓[/green] [dim]" + str(teach(rest, "fact")) + "[/dim]"); }
        else { console.print("[dim]  usage: /remember <fact>[/dim]"); }
    }
    elif verb == "/recall" {
        ms = recollect(rest, 8);
        if not ms { console.print("[dim]  (nothing found)[/dim]"); }
        for m in ms { console.print("  [dim](" + str(m["kind"]) + ")[/dim] ", Text(str(m["content"]))); }
    }
    elif verb == "/model" {
        mp = rest.split(" ", 1);
        if len(mp) == 2 { console.print("[green]  ✓[/green] [dim]" + str(configure(str(mp[0]).strip() + "_model", str(mp[1]).strip())) + "[/dim]"); }
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
    session = _make_session();
    _install_hooks(console, session);
    _banner(console);
    # colour the prompt so each user turn stands out from the reply block above it
    user_prompt = chr(27) + "[38;5;141msigil" + chr(27) + "[0m " + chr(27) + "[1m›" + chr(27) + "[0m ";
    while True {
        line = "";
        try {
            line = _prompt(session, user_prompt);
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
        _run_and_render(console, cmd);
    }
    console.print("[dim]bye ◆[/dim]");
}

# ---------------------------------------------------------------------------
# first-run setup wizard — a few questions to configure the model tiers + persona
# ---------------------------------------------------------------------------
def setup_wizard() {
    console = Console();
    session = _make_session();
    console.print();
    console.print("[bold magenta]  ◆ Sigil setup[/bold magenta] [dim]· a few quick questions (press Enter to accept a default)[/dim]");
    console.print("  [dim]Sigil compiles a SKILL.md into a runnable agent. First, pick the models it runs on.[/dim]");
    console.print();
    steps = [
        ["chat_model", "Which model do you TALK to in chat? (use a strong one)", "gpt-4o"],
        ["frontier_model", "Which model COMPILES new skills? (also strong)", "gpt-4o"],
        ["small_model", "Which cheap/local model RUNS compiled skills?", "gpt-4o-mini"],
        ["persona", "In a line, how should your agent describe itself? (optional)", ""]
    ];
    for st in steps {
        key = st[0]; question = st[1]; default = st[2];
        hint = ("  [" + default + "]") if default else "  (optional)";
        console.print("  [cyan]" + question + "[/cyan][dim]" + hint + "[/dim]");
        val = "";
        try { val = str(_prompt(session, "  › ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { console.print(); return; }
        if (not val) and default { val = default; }
        if val { console.print("[green]  ✓[/green] [dim]" + str(configure(key, val)) + "[/dim]"); }
        console.print();
    }
    # Mark setup complete so the first-run gate stops firing on every model command.
    configure("setup_done", "true");
    s = describe_soul();
    console.print("[bold]  You're set.[/bold] [dim]chat=" + str(s["chat_model"]) + "  frontier=" + str(s["frontier_model"]) + "  small=" + str(s["small_model"]) + "[/dim]");
    # Key check — the models are on the graph, but the credential lives in your env.
    # Warn (don't block) so a wrong guess or a local model never traps you.
    cs = config_status();
    if cs["local"] {
        console.print("  [green]✓[/green] [dim]local model — no API key needed.[/dim]");
    } elif cs["key_env"] and (not cs["key_present"]) {
        console.print("  [yellow]![/yellow] [dim]set your model key before running:  [/dim][cyan]export " + str(cs["key_env"]) + "=…[/cyan]");
    } elif cs["key_present"] {
        console.print("  [green]✓[/green] [dim]" + str(cs["key_env"]) + " found.[/dim]");
    }
    console.print();
    console.print("  [bold]Now compile a skill[/bold] [dim]— that's what Sigil is for:[/dim]");
    console.print("    [cyan]sigil examples[/cyan]                          [dim]starter SKILL.md files to try[/dim]");
    console.print("    [cyan]sigil compile examples/skills/hello.SKILL.md -e agent.jac[/cyan]");
    console.print("    [dim]…or just[/dim] [cyan]sigil chat[/cyan] [dim]and say \"compile a skill\".[/dim]");
    console.print();
}

# ---------------------------------------------------------------------------
# interactive settings editor
# ---------------------------------------------------------------------------
def config_menu() {
    console = Console();
    session = _make_session();
    fields = [
        ["name", "agent name"],
        ["persona", "voice / character it speaks with"],
        ["chat_model", "conversational model — powers chat mode & sub-agents"],
        ["frontier_model", "expensive model — compiles new skills"],
        ["small_model", "cheap model — executes compiled skills"],
        ["router_model", "model that routes a task to a skill"],
        ["workspace", "sandboxed directory the file tools are jailed to"],
        ["sandbox_mode", "exec containment: jail | docker | off"],
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
            "workspace": str(s["workspace"]), "sandbox_mode": str(s["sandbox_mode"]),
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
        try { choice = str(_prompt(session, "edit # (blank = done) › ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { return; }
        if choice in ["", "0", "q", "done", "exit"] { return; }
        idx = _to_int(choice, 0) - 1;
        if (idx < 0) or (idx >= len(fields)) { console.print("[dim]  no such option[/dim]"); continue; }
        fk = fields[idx][0];
        newval = "";
        try { newval = str(_prompt(session, "  " + fk + " = ")).strip(); }
        except EOFError as e { console.print(); return; }
        except KeyboardInterrupt as e { continue; }
        if not newval { continue; }
        console.print("[green]  ✓[/green] [dim]" + str(configure(fk, newval)) + "[/dim]");
    }
}
