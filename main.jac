"""Sigil CLI — the agent has no config files. Its soul, skills and memory
all live on the graph; persist that graph across invocations with a session file:

    jac run main.jac -s sigil.session -- solve "extract tables from report.pdf as csv"
    jac run main.jac -s sigil.session -- solve "..."     # reuses / evolves the graph
    jac run main.jac -s sigil.session -- soul
    jac run main.jac -s sigil.session -- configure small_model ollama_chat/qwen3:8b
    jac run main.jac -s sigil.session -- teach "the user always wants CSV with a header row"
    jac run main.jac -s sigil.session -- library
"""

import sys;
import from sigil {
    solve_task, library, describe_soul, configure, teach, recollect,
    add_mcp, remove_mcp, mcp_status, register_skill
}
import from cron {
    cron_add, cron_list, cron_show, cron_runs, cron_remove, cron_enable, cron_tick
}
import from channels { channel_add, channel_list, channel_remove, message_send, inbound }
import from hooks { hook_add, hook_list, hook_enable, hook_remove }
import from approvals { approvals_get, approvals_set, allowlist_add, check_exec, approve }
import from agent { run_task }

def cli_args(raw: list) -> list {
    # jac leaves its own flags in sys.argv (e.g. -s <session> -- <cmd>). Take
    # everything after '--' if present, else drop argv[0] and skip -s <file>.
    if "--" in raw { return raw[raw.index("--") + 1:]; }
    out: list = [];
    eat_next = False;
    for a in raw[1:] {
        if eat_next { eat_next = False; continue; }
        if (a == "-s") or (a == "--session") { eat_next = True; continue; }
        out.append(a);
    }
    return out;
}

def _arg(argv: list, i: int) -> str {
    return str(argv[i]) if len(argv) > i else "";
}

with entry:__main__ {
    argv = cli_args(sys.argv);
    cmd = _arg(argv, 0) if argv else "help";

    if cmd == "solve" {
        task = _arg(argv, 1);
        skill = _arg(argv, 2);
        if not task {
            print("usage: solve \"<task>\" [skill]");
        } else {
            r = run_task(task, skill);
            print("=== route trace ===");
            print(r["trace"]);
            print("=== signature: " + r["signature"] + " ===");
            print(r["result"]);
        }
    } elif cmd == "library" {
        lib = library();
        if not lib {
            print("(empty — no crystallized procedures yet)");
        } else {
            print("crystallized procedures (" + str(len(lib)) + "):");
            for e in lib {
                print("  " + e["signature"] + "  v" + str(e["version"])
                      + "  [" + e["origin"] + "]  runs=" + str(e["runs"])
                      + " ok=" + str(e["successes"]));
            }
        }
    } elif cmd == "soul" {
        s = describe_soul();
        print("soul: " + str(s["name"]));
        print("  persona : " + str(s["persona"]));
        print("  models  : frontier=" + str(s["frontier_model"])
              + "  small=" + str(s["small_model"]) + "  router=" + str(s["router_model"]));
        print("  channels: " + ", ".join([str(c) for c in s["channels"]]));
        eths = list(s["ethos"]);
        mems = list(s["memories"]);
        print("  skills  : " + str(s["skills"]) + "   memories: " + str(len(mems)));
        print("  ethos   :");
        for e in eths { print("    - " + str(e)); }
        if mems {
            print("  memory  :");
            for m in mems { print("    (" + str(m["kind"]) + ", used " + str(m["uses"]) + "x) " + str(m["content"])); }
        }
    } elif cmd == "configure" {
        key = _arg(argv, 1);
        val = _arg(argv, 2);
        if not key or not val { print("usage: configure <key> <value>"); }
        else { print(configure(key, val)); }
    } elif cmd == "teach" {
        fact = _arg(argv, 1);
        if not fact { print("usage: teach \"<fact>\""); }
        else { print(teach(fact, "fact")); }
    } elif cmd == "recall" {
        q = _arg(argv, 1);
        for m in recollect(q, 8) { print("  (" + m["kind"] + ") " + m["content"]); }
    } elif cmd == "add-mcp" {
        # add-mcp <name> <stdio|http|sse> <command-or-url> [args...]
        name = _arg(argv, 1); transport = _arg(argv, 2); target = _arg(argv, 3);
        rest = [str(x) for x in argv[4:]] if len(argv) > 4 else [];
        if not name or not transport or not target { print("usage: add-mcp <name> <stdio|http|sse> <command-or-url> [args...]"); }
        else { print(add_mcp(name, transport, target, rest)); }
    } elif cmd == "remove-mcp" {
        name = _arg(argv, 1);
        if not name { print("usage: remove-mcp <name>"); }
        else { print(remove_mcp(name)); }
    } elif cmd == "mcp" {
        st = mcp_status();
        if not st { print("(no MCP servers registered)"); }
        else {
            for s in st {
                tl = list(s["tools"]);
                print("  " + str(s["name"]) + "  [" + str(s["transport"]) + "]  tools: "
                      + (", ".join([str(t) for t in tl]) if tl else "(none)"));
            }
        }
    } elif cmd == "cron" {
        # cron add <name> <at|every|cron> <spec> "<task>" [tz] [channel] | list | show <name> | runs <name> | rm <name> | enable/disable <name> | tick
        sub = _arg(argv, 1);
        if sub == "add" {
            r = cron_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5),
                         _arg(argv, 6) if len(argv) > 6 else "UTC", _arg(argv, 7), False);
            print("scheduled '" + str(r["name"]) + "' [" + str(r["kind"]) + "] next=" + str(r["next_run_ms"]));
        } elif sub == "list" {
            js = cron_list();
            if not js { print("(no cron jobs)"); }
            for j in js {
                print("  " + str(j["name"]) + "  [" + str(j["kind"]) + " " + str(j["spec"]) + "]  "
                      + ("on" if j["enabled"] else "off") + "  runs=" + str(j["runs"])
                      + " err=" + str(j["errors"]) + "  " + str(j["last_status"]));
            }
        } elif sub == "show" { print(cron_show(_arg(argv, 2))); }
        elif sub == "runs" {
            for r in cron_runs(_arg(argv, 2)) { print("  " + ("ok " if r["ok"] else "err") + "  " + str(r["summary"])); }
        } elif sub == "rm" { print(cron_remove(_arg(argv, 2))); }
        elif sub == "enable" { print(cron_enable(_arg(argv, 2), True)); }
        elif sub == "disable" { print(cron_enable(_arg(argv, 2), False)); }
        elif sub == "tick" {
            t = cron_tick();
            print("tick: fired " + str(t["count"]) + " job(s)");
            for f in list(t["fired"]) { print("  " + str(f["name"]) + " -> " + ("ok" if f["ok"] else "err")); }
        } else { print("usage: cron add|list|show|runs|rm|enable|disable|tick ..."); }
    } elif cmd == "register-skill" {
        # register-skill <path> [md|agir|osp]  (kind auto-detected from extension)
        path = _arg(argv, 1); kind = _arg(argv, 2);
        if not path { print("usage: register-skill <path> [md|agir|osp]"); }
        else {
            if not kind {
                low = path.lower();
                if low.endswith(".jac") { kind = "osp"; }
                elif low.endswith(".ir") or low.endswith(".agir") or low.endswith(".yaml") or low.endswith(".yml") { kind = "agir"; }
                else { kind = "md"; }
            }
            src = path if kind == "osp" else open(path).read();
            r = register_skill(src, kind);
            print("registered skill: " + str(r["signature"]) + "  [" + str(r["origin"]) + "]  -> " + str(r["module"]));
        }
    } elif cmd == "channel" {
        sub = _arg(argv, 1);
        if sub == "add" { r = channel_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5) if len(argv) > 5 else "per-peer"); print("channel '" + str(r["name"]) + "' [" + str(r["kind"]) + "]"); }
        elif sub == "list" { for c in channel_list() { print("  " + str(c["name"]) + "  [" + str(c["kind"]) + "]  " + ("on" if c["enabled"] else "off") + "  msgs=" + str(c["messages"])); } }
        elif sub == "rm" { print(channel_remove(_arg(argv, 2))); }
        elif sub == "send" { r = message_send(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4)); print("sent to " + str(r["peer"]) + " on " + str(r["channel"])); }
        elif sub == "inbound" { r = inbound(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4)); print("reply: " + str(r["reply"])); }
        else { print("usage: channel add|list|rm|send|inbound ..."); }
    } elif cmd == "hook" {
        sub = _arg(argv, 1);
        if sub == "add" { r = hook_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5)); print("hook '" + str(r["name"]) + "'"); }
        elif sub == "list" { for h in hook_list() { print("  " + str(h["name"]) + "  @" + str(h["event"]) + "  [" + str(h["kind"]) + "]  " + ("on" if h["enabled"] else "off") + "  fired=" + str(h["fired"])); } }
        elif sub == "enable" { print(hook_enable(_arg(argv, 2), True)); }
        elif sub == "disable" { print(hook_enable(_arg(argv, 2), False)); }
        elif sub == "rm" { print(hook_remove(_arg(argv, 2))); }
        else { print("usage: hook add|list|enable|disable|rm ..."); }
    } elif cmd == "approvals" {
        sub = _arg(argv, 1);
        if sub == "get" { g = approvals_get(); print("security=" + str(g["security"]) + " ask=" + str(g["ask"])); print("allowlist: " + ", ".join([str(x) for x in list(g["allowlist"])])); print("pending: " + str(len(list(g["pending"])))); }
        elif sub == "set" { print(approvals_set(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "allow" { print(allowlist_add(_arg(argv, 2))); }
        elif sub == "check" { print(check_exec(_arg(argv, 2))["decision"]); }
        elif sub == "approve" { print(approve(_arg(argv, 2), _arg(argv, 3) if len(argv) > 3 else "allow-once")); }
        else { print("usage: approvals get|set <sec> <ask>|allow <pattern>|check <cmd>|approve <cmd> <decision>"); }
    } else {
        print("Sigil — a self-evolving object-spatial agent (soul, skills & memory on the graph)");
        print("  solve \"<task>\" [skill]     route a task; crystallize/execute/mutate as needed");
        print("  library                     list crystallized procedures (skills)");
        print("  soul                        show identity, config, skills & memory (all graph state)");
        print("  configure <key> <value>     mutate config on the graph (persona|*_model|add_ethos|add_channel)");
        print("  teach \"<fact>\"              write a durable memory onto the graph");
        print("  recall \"<query>\"            retrieve relevant memories");
        print("  add-mcp <name> <transport> <cmd-or-url> [args...]   register a BYO MCP server");
        print("  remove-mcp <name>           unregister an MCP server");
        print("  mcp                         list registered MCP servers + their tools");
        print("  register-skill <path> [md|agir|osp]   add a skill (SKILL.md lifted / AG-IR / OSP)");
        print("  (add  -s sigil.session  to persist the graph across runs)");
    }
}
