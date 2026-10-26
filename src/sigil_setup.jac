"""Setup and connections at the terminal: `sigil setup`, `sigil connect`,
`sigil connections`, and the first-run gate in front of the model-using commands.

The registry and the sign-in flows are in `sigil_connect`; this module is only
the conversation around them. Setup has one required step, connecting a model:
Sigil does nothing without one, so setup does not finish until the frontier tier
has a live route under it. Picking the tiers and a persona come after, and both
have defaults.
"""

import sys;
import os;
import getpass;
import from .sigil_connect {
    PROVIDERS, KEYED, connections, provider_status, provider_label, suggest_tiers, tiers_for,
    apply_tiers, ready_tiers, model_ready, connect_chatgpt, connect_openrouter, connect_key,
    claude_login, ollama_pull, ollama_signin, is_cloud_tag, disconnect, how_to, gate_on, CHATGPT_USAGE_URL
}
import from .sigil_core { describe_soul, configure }
import from .sigil_runtime { commit_now }
import from .sigil_input { make_plain_session, prompt_text }
import from rich.console { Console }

glob TIER_NAMES: list[any] = [
    ["frontier", "compiles skills (strong)"],
    ["chat", "talks to you (strong)"],
    ["small", "runs compiled skills (cheap)"],
    ["router", "routes a task to a skill (cheap)"]
];

def _commit(console: any, context: str) {
    warn = commit_now(context);
    if warn { console.print("[dim]  ⚠ " + warn + "[/dim]"); }
}

def _ask(session: any, msg: str) -> str {
    # The answer, or raises KeyboardInterrupt for both ^C and ^D: either one ends
    # the conversation, never with a traceback.
    try { return str(prompt_text(session, msg)).strip(); }
    except EOFError as e { raise KeyboardInterrupt(); }
}

def _yes(session: any, msg: str, dflt: bool = True) -> bool {
    a = _ask(session, msg + (" [Y/n] " if dflt else " [y/N] ")).lower();
    if not a { return dflt; }
    return a in ["y", "yes"];
}

def _mark(r: dict[str, any]) -> str {
    return "[green]✓[/green]" if r["connected"] else "[dim]·[/dim]";
}

def print_connections(console: any) {
    rows = connections();
    console.print("[bold]connections[/bold]");
    for r in rows {
        console.print("  " + _mark(r) + " " + str(r["label"]).ljust(18) + str(r["detail"])
                      + ("" if r["connected"] else ("  [dim]→ sigil connect " + str(r["id"]) + "[/dim]")));
    }
    rt = ready_tiers();
    console.print();
    console.print("[bold]tiers[/bold]");
    for tn in TIER_NAMES {
        x = rt["tiers"][str(tn[0])];
        mk = "[green]✓[/green]" if x["ok"] else "[red]✗[/red]";
        console.print("  " + mk + " " + str(tn[0]).ljust(9) + str(x["model"] or "(unset)")
                      + ("" if x["ok"] else ("  [dim]" + str(x["why"]) + "[/dim]")));
    }
}

# ---------------------------------------------------------------------------
# One connection, interactively
# ---------------------------------------------------------------------------
def _show_link(console: any, url: str) {
    console.print("  [dim]If no browser opened, open this link on this machine:[/dim]");
    console.print("  [dim]" + url + "[/dim]");
    console.print("  [dim]Waiting for the sign-in (^C cancels)…[/dim]");
}

def connect_cli(console: any, session: any, pid: str, fresh: bool = False, browser: bool = True,
                arg: str = "") -> bool {
    label = provider_label(pid);
    if pid == "chatgpt" {
        console.print("  Opening a ChatGPT sign-in in your browser…");
        try {
            r: dict[str, any] = connect_chatgpt(lambda (url: str) { _show_link(console, url); }, fresh, browser);
            console.print("[green]  ✓[/green] " + str(r["detail"]) + ".");
            console.print("  [bold]You're using your ChatGPT plan.[/bold] [dim]Eligible requests from Sigil count against it;"
                          + " manage usage at " + CHATGPT_USAGE_URL + "[/dim]");
            ms = list(r.get("models") or []);
            if ms { console.print("  [dim]models: " + ", ".join([str(m) for m in ms[:6]]) + ("…" if len(ms) > 6 else "") + "[/dim]"); }
            return True;
        } except KeyboardInterrupt as e { console.print("  [dim]cancelled[/dim]"); return False; }
        except Exception as e { console.print("[red]  ✗[/red] " + str(e)); return False; }
    }
    if pid == "openrouter" {
        console.print("  Opening an OpenRouter sign-in in your browser…");
        try {
            r2: dict[str, any] = connect_openrouter(lambda (url: str) { _show_link(console, url); }, browser);
            console.print("[green]  ✓[/green] " + str(r2["detail"]) + ".");
            return True;
        } except KeyboardInterrupt as e { console.print("  [dim]cancelled[/dim]"); return False; }
        except Exception as e { console.print("[red]  ✗[/red] " + str(e)); return False; }
    }
    if pid == "claude-code" {
        st = provider_status(pid);
        if st["connected"] { console.print("[green]  ✓[/green] Claude Code: " + str(st["detail"])); return True; }
        console.print("  Starting the claude CLI's own sign-in (`claude auth login`)…");
        r3: dict[str, any] = claude_login();
        console.print(("[green]  ✓[/green] " if r3["ok"] else "[red]  ✗[/red] ") + "Claude Code: " + str(r3["detail"]));
        return bool(r3["ok"]);
    }
    if pid == "ollama" {
        st2 = provider_status(pid);
        want = arg.strip();
        if st2["connected"] and ((not want) or (("ollama_chat/" + want) in list(st2["models"]))) {
            console.print("[green]  ✓[/green] Ollama: " + str(st2["detail"]));
            return True;
        }
        if str(st2["detail"]) == "not installed" {
            console.print("[red]  ✗[/red] Ollama is not installed: get it from https://ollama.com/download, then run this again.");
            return False;
        }
        if str(st2["detail"]) == "installed, not running" {
            console.print("[red]  ✗[/red] Ollama is installed but not running: start the Ollama app (or `ollama serve`), then run this again.");
            return False;
        }
        if want.lower() in ["signin", "cloud"] {
            r6: dict[str, any] = ollama_signin();
            console.print(("[green]  ✓[/green] " if r6["ok"] else "[red]  ✗[/red] ") + str(r6["detail"])
                          + ("  [dim]then e.g. `sigil connect ollama glm-5.3:cloud`[/dim]" if r6["ok"] else ""));
            return bool(r6["ok"]) or bool(st2["connected"]);
        }
        if is_cloud_tag(want) {
            console.print("  [dim]" + want + " runs on ollama.com through this Ollama; sign it in first if you have not (`ollama signin`).[/dim]");
        }
        m = want if want else "qwen3:8b";
        if not _yes(session, "  Pull " + m + " into Ollama now" + ("" if is_cloud_tag(m) else " (a few GB)") + "?") { return bool(st2["connected"]); }
        r4: dict[str, any] = ollama_pull(m);
        console.print(("[green]  ✓[/green] " if r4["ok"] else "[red]  ✗[/red] ") + str(r4["detail"]));
        return bool(r4["ok"]);
    }
    if pid in KEYED {
        env = str(KEYED[pid][0]);
        key = arg.strip();
        if not key {
            console.print("  [dim]Get a key at " + str(KEYED[pid][3]) + ". It is kept in $SIGIL_HOME/secrets.env (0600), never on the graph.[/dim]");
            try { key = str(getpass.getpass("  Paste your " + label + " key (hidden): ")).strip(); }
            except EOFError as e { return False; }
        }
        if not key { console.print("  [dim]no key given[/dim]"); return False; }
        r5: dict[str, any] = connect_key(pid, key);
        if r5["ok"] { console.print("[green]  ✓[/green] " + env + " saved and working."); return True; }
        console.print("[red]  ✗[/red] " + env + " was saved, but the test failed: " + str(r5.get("detail") or r5.get("error") or ""));
        return False;
    }
    console.print("  [red]no connection called '" + pid + "'[/red] — one of: " + ", ".join([str(p[0]) for p in PROVIDERS]));
    return False;
}

def offer_tiers(console: any, session: any, pid: str) {
    # After `sigil connect <x>` on its own: offer to point the tiers at it.
    sug = tiers_for(pid, connections());
    cur = describe_soul();
    changes: list[any] = [];
    for tn in TIER_NAMES {
        t = str(tn[0]);
        v = str(sug.get(t) or "");
        if v and (v != str(cur[t + "_model"] or "")) { changes.append([t, v]); }
    }
    if not changes { return; }
    console.print("  Use " + provider_label(pid) + " for the tiers?");
    for c in changes { console.print("    " + str(c[0]).ljust(9) + str(cur[str(c[0]) + "_model"] or "(unset)") + " → [cyan]" + str(c[1]) + "[/cyan]"); }
    try {
        if not _yes(session, "  Apply?") { return; }
    } except KeyboardInterrupt as e { return; }
    for s in apply_tiers(sug) { console.print("[green]  ✓[/green] [dim]" + s + "[/dim]"); }
    _commit(console, "connect");
}

# ---------------------------------------------------------------------------
# sigil setup
# ---------------------------------------------------------------------------
def _pick_connections(console: any, session: any) -> bool {
    # Step 1, required: loop until at least one route is connected.
    while True {
        rows = connections();
        anyc = len([r for r in rows if r["connected"]]) > 0;
        i = 1;
        for r in rows {
            console.print("   " + str(i).rjust(2) + "  " + _mark(r) + " " + str(r["label"]).ljust(18)
                          + "[dim]" + (str(r["detail"]) if r["connected"] else str(r["about"])) + "[/dim]");
            i += 1;
        }
        console.print();
        a = _ask(session, ("  Connect another (1-" + str(len(rows)) + "), or Enter to continue › ") if anyc
                 else ("  Pick one to connect (1-" + str(len(rows)) + ") › "));
        if not a {
            if anyc { return True; }
            console.print("  [yellow]Sigil needs at least one model connection to do anything.[/yellow] [dim]Pick a number, or ^C to stop.[/dim]");
            console.print();
            continue;
        }
        n = 0;
        try { n = int(a); } except Exception as e { n = 0; }
        pid = "";
        if (n >= 1) and (n <= len(rows)) { pid = str(rows[n - 1]["id"]); }
        else {
            for r in rows { if (str(r["id"]) == a.lower()) or (str(r["label"]).lower() == a.lower()) { pid = str(r["id"]); } }
        }
        if not pid { console.print("  [dim]no such option[/dim]"); continue; }
        console.print();
        connect_cli(console, session, pid);
        console.print();
    }
    return False;
}

def _pick_tiers(console: any, session: any) {
    rows = connections();
    rt = ready_tiers();
    cur: dict[str, any] = rt["tiers"];
    all_ok = True;
    for tn in TIER_NAMES { if not cur[str(tn[0])]["ok"] { all_ok = False; } }
    sug = suggest_tiers(rows);
    same = True;
    for tn in TIER_NAMES { if str(sug.get(str(tn[0])) or "") != str(cur[str(tn[0])]["model"]) { same = False; } }
    if all_ok and same {
        console.print("  [green]✓[/green] every tier already runs on a connected model.");
        return;
    }
    if all_ok {
        console.print("  Your tiers all run on connected models:");
        for tn in TIER_NAMES { console.print("    " + str(tn[0]).ljust(9) + str(cur[str(tn[0])]["model"]) + "  [dim]" + str(tn[1]) + "[/dim]"); }
        if _yes(session, "  Keep them?") { return; }
    }
    console.print("  Suggested from what is connected:");
    for tn in TIER_NAMES { console.print("    " + str(tn[0]).ljust(9) + "[cyan]" + str(sug.get(str(tn[0])) or "(none)") + "[/cyan]  [dim]" + str(tn[1]) + "[/dim]"); }
    chosen: dict[str, str] = dict(sug);
    if not _yes(session, "  Use these?") {
        offered: list[str] = [];
        for r in rows { if r["connected"] { offered = offered + [str(m) for m in list(r["models"])]; } }
        if offered { console.print("  [dim]connected models: " + ", ".join(offered[:12]) + ("…" if len(offered) > 12 else "") + "[/dim]"); }
        for tn in TIER_NAMES {
            t = str(tn[0]);
            d = str(sug.get(t) or "");
            v = _ask(session, "    " + t + " [" + d + "] › ");
            chosen[t] = v if v else d;
        }
    }
    for tn in TIER_NAMES {
        t = str(tn[0]);
        rd = model_ready(str(chosen.get(t) or ""), rows);
        if not rd["ok"] { console.print("  [yellow]⚠[/yellow] " + t + ": " + str(rd["why"])); }
    }
    for s in apply_tiers(chosen) { console.print("[green]  ✓[/green] [dim]" + s + "[/dim]"); }
    _commit(console, "setup");
}

def setup_wizard() -> bool {
    # True once the frontier and chat tiers have a live route.
    console = Console();
    session = make_plain_session();
    console.print();
    console.print("[bold magenta]  ◆ Sigil setup[/bold magenta] [dim]· connect a model, pick the tiers, done[/dim]");
    console.print();
    try {
        console.print("[bold]  1 · Connect a model[/bold] [dim](required)[/dim]");
        if not _pick_connections(console, session) { return False; }
        console.print("[bold]  2 · Model tiers[/bold]");
        _pick_tiers(console, session);
        console.print();
        console.print("[bold]  3 · Persona[/bold] [dim](optional; Enter skips)[/dim]");
        p = _ask(session, "  In a line, how should your agent describe itself? › ");
        if p { console.print("[green]  ✓[/green] [dim]" + str(configure("persona", p)) + "[/dim]"); _commit(console, "setup"); }
    } except KeyboardInterrupt as e {
        console.print();
        console.print("  [dim]setup stopped — run `sigil setup` to finish it[/dim]");
        return bool(ready_tiers()["ok"]);
    }
    rt = ready_tiers();
    s = describe_soul();
    console.print();
    if rt["ok"] {
        console.print("[bold]  You're set.[/bold] [dim]chat=" + str(s["chat_model"]) + "  frontier=" + str(s["frontier_model"]) + "  small=" + str(s["small_model"]) + "[/dim]");
        console.print("  [dim]Try:  [/dim][cyan]sigil chat[/cyan][dim]   or   [/dim][cyan]sigil compile ./SKILL.md[/cyan]");
    } else {
        console.print("[yellow]  Not quite:[/yellow] " + str(rt["tiers"]["frontier"]["why"] or rt["tiers"]["chat"]["why"]));
        console.print("  [dim]`sigil connections` shows what is missing; `sigil setup` again to fix it.[/dim]");
    }
    console.print();
    return bool(rt["ok"]);
}

# ---------------------------------------------------------------------------
# The gate in front of the commands that call a model
# ---------------------------------------------------------------------------
def connection_gate(interactive: bool) -> bool {
    # True to go ahead. Interactive with nothing connected: run setup, which
    # does not finish without a connection. Piped or scripted: one warning line,
    # and the command runs into whatever its first model call says.
    if not gate_on() { return True; }
    rt: dict[str, any] = {};
    try { rt = ready_tiers(); } except Exception as e { return True; }
    if rt["ok"] { return True; }
    why = str(rt["tiers"]["frontier"]["why"] or rt["tiers"]["chat"]["why"]);
    if not interactive {
        print("⚠ no model connection for this run (" + why + ") — `sigil setup` connects one", file=sys.stderr);
        return True;
    }
    console = Console();
    console.print();
    console.print("[yellow]  Sigil needs a model connection first[/yellow] [dim](" + why + ")[/dim]");
    return setup_wizard();
}
