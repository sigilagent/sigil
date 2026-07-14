"""Sigil interactive CLI — a Claude-style chat REPL and an interactive settings
editor. Both drive the SAME persistent graph as the one-shot commands, so a task
solved in chat crystallizes a skill you can reuse from `solve`, and edits made in
`config` persist on the Soul node. Run them inside a session:

    jac run main.jac -s sigil.session -- chat
    jac run main.jac -s sigil.session -- config

Rendering uses `rich`; line editing/history uses `prompt_toolkit` when stdin is a
real terminal, falling back to builtin input() when piped (so it stays scriptable).
"""

import sys;
import os;
import from .sigil { describe_soul, configure, library, recollect, teach }
import from .agent { run_task }
import from rich.console { Console }
import from rich.panel { Panel }
import from rich.table { Table }
import from rich.text { Text }

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
    if session is not None { return str(session.prompt(msg)); }
    return str(input(msg));
}

def _to_int(s: str, dflt: int) -> int {
    try { return int(s); } except Exception as e { return dflt; }
}

# ---------------------------------------------------------------------------
# rendering helpers
# ---------------------------------------------------------------------------
def _banner(console: any, s: dict) {
    fm = str(s["frontier_model"]) if s["frontier_model"] else "unset";
    sm = str(s["small_model"]) if s["small_model"] else "unset";
    console.print();
    console.print("[bold magenta]  ◆ sigil[/bold magenta] [dim]· self-evolving agent[/dim]");
    console.print("  [dim]frontier[/dim] " + fm + "  [dim]small[/dim] " + sm + "  [dim]skills[/dim] " + str(s["skills"]));
    console.print("  [dim]type a task · /help for commands · /exit to quit[/dim]");
    console.print();
}

def _help(console: any) {
    rows = [
        ["/help", "show this help"],
        ["/soul", "identity, models, skills & memory"],
        ["/config", "edit settings interactively"],
        ["/model <tier> <name>", "set frontier|small|router model"],
        ["/library", "list crystallized skills"],
        ["/teach <fact>", "store a durable memory"],
        ["/recall <query>", "search memories"],
        ["/clear", "clear the screen"],
        ["/exit", "quit (also Ctrl-D)"]
    ];
    console.print();
    console.print("[bold]commands[/bold]");
    for r in rows { console.print("  [cyan]" + r[0].ljust(22) + "[/cyan] [dim]" + r[1] + "[/dim]"); }
    console.print("  [dim]anything else is a task the agent will solve.[/dim]");
    console.print();
}

def _show_soul(console: any) {
    s = describe_soul();
    console.print();
    console.print("[bold magenta]soul[/bold magenta] " + str(s["name"]));
    console.print("  [dim]persona [/dim] ", Text(str(s["persona"]) if s["persona"] else "(unset)"));
    console.print("  [dim]frontier[/dim] " + str(s["frontier_model"]) + "  [dim]small[/dim] " + str(s["small_model"]) + "  [dim]router[/dim] " + str(s["router_model"]));
    console.print("  [dim]auto-eval[/dim] " + ("on" if s["auto_eval"] else "off") + "  [dim]threshold[/dim] " + str(s["eval_threshold"]) + "  [dim]skills[/dim] " + str(s["skills"]));
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
    if not lib { console.print("[dim]  (no crystallized skills yet)[/dim]"); return; }
    t = Table(show_header=True, header_style="dim", box=None, pad_edge=False);
    t.add_column("skill"); t.add_column("v"); t.add_column("origin");
    t.add_column("runs", justify="right"); t.add_column("ok", justify="right");
    for e in lib {
        t.add_row(str(e["signature"]), "v" + str(e["version"]), str(e["origin"]), str(e["runs"]), str(e["successes"]));
    }
    console.print(t);
}

def _status_line(trace: str) -> str {
    # one compact line describing what routing did, derived from the run trace
    verb = "";
    if "MISS -> crystallized" in trace { verb = "crystallized a new skill"; }
    elif "PARTIAL -> mutated" in trace { verb = "adapted an existing skill"; }
    elif "HIT " in trace { verb = "reused a crystallized skill"; }
    if "small-model FAIL" in trace { verb += " · recovered a failed run"; }
    if "relearn" in trace { verb += " · relearned"; }
    if ("DONE ok" not in trace) and verb { verb += " · [red]did not complete[/red]"; }
    return verb;
}

def _run_and_render(console: any, task: str) {
    r: dict = {};
    with console.status("[dim]thinking…[/dim]", spinner="dots") as _st {
        r = run_task(task, "");
    }
    st = _status_line(str(r["trace"]));
    if st { console.print("[dim]  " + st + "[/dim]"); }
    console.print(Panel(Text(str(r["result"])), title="[dim]" + str(r["signature"]) + "[/dim]",
                        title_align="left", border_style="grey37", padding=(0, 1)));
    console.print();
}

# ---------------------------------------------------------------------------
# slash commands
# ---------------------------------------------------------------------------
def _handle_slash(console: any, cmd: str) -> bool {
    parts = cmd.split(" ", 1);
    verb = str(parts[0]).lower();
    rest = str(parts[1]).strip() if len(parts) > 1 else "";
    if verb in ["/exit", "/quit", "/q"] { return True; }
    elif verb in ["/help", "/?", "/h"] { _help(console); }
    elif verb == "/soul" { _show_soul(console); }
    elif verb == "/config" { config_menu(); }
    elif verb == "/library" { _show_library(console); }
    elif verb == "/clear" { console.clear(); }
    elif verb == "/teach" {
        if rest { console.print("[green]  ✓[/green] [dim]" + str(teach(rest, "fact")) + "[/dim]"); }
        else { console.print("[dim]  usage: /teach <fact>[/dim]"); }
    }
    elif verb == "/recall" {
        ms = recollect(rest, 8);
        if not ms { console.print("[dim]  (nothing found)[/dim]"); }
        for m in ms { console.print("  [dim](" + str(m["kind"]) + ")[/dim] ", Text(str(m["content"]))); }
    }
    elif verb == "/model" {
        mp = rest.split(" ", 1);
        if len(mp) == 2 { console.print("[green]  ✓[/green] [dim]" + str(configure(str(mp[0]).strip() + "_model", str(mp[1]).strip())) + "[/dim]"); }
        else { console.print("[dim]  usage: /model <frontier|small|router> <name>[/dim]"); }
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
    _banner(console, describe_soul());
    while True {
        line = "";
        try {
            line = _prompt(session, "sigil › ");
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
# interactive settings editor
# ---------------------------------------------------------------------------
def config_menu() {
    console = Console();
    session = _make_session();
    fields = [
        ["name", "agent name"],
        ["persona", "voice / character it speaks with"],
        ["frontier_model", "expensive model — crystallizes new skills"],
        ["small_model", "cheap model — executes crystallized skills"],
        ["router_model", "model that routes a task to a skill"],
        ["auto_eval", "self-check each run, on/off"],
        ["eval_threshold", "auto-relearn below this score (0-100)"]
    ];
    while True {
        s = describe_soul();
        cur = {
            "name": str(s["name"]), "persona": str(s["persona"]),
            "frontier_model": str(s["frontier_model"]), "small_model": str(s["small_model"]),
            "router_model": str(s["router_model"]),
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
