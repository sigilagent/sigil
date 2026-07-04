"""Prometheus CLI — the agent has no config files. Its soul, skills and memory
all live on the graph; persist that graph across invocations with a session file:

    jac run main.jac -s prometheus.session -- solve "extract tables from report.pdf as csv"
    jac run main.jac -s prometheus.session -- solve "..."     # reuses / evolves the graph
    jac run main.jac -s prometheus.session -- soul
    jac run main.jac -s prometheus.session -- configure small_model ollama_chat/qwen3:8b
    jac run main.jac -s prometheus.session -- teach "the user always wants CSV with a header row"
    jac run main.jac -s prometheus.session -- library
"""

import sys;
import from prometheus {
    solve_task, library, describe_soul, configure, teach, recollect,
    add_mcp, remove_mcp, mcp_status, register_skill
}

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
            r = solve_task(task, skill);
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
    } else {
        print("Prometheus — a self-evolving object-spatial agent (soul, skills & memory on the graph)");
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
        print("  (add  -s prometheus.session  to persist the graph across runs)");
    }
}
