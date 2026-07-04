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
    solve_task, library, describe_soul, configure, teach, recollect
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
    } else {
        print("Prometheus — a self-evolving object-spatial agent (soul, skills & memory on the graph)");
        print("  solve \"<task>\" [skill]     route a task; crystallize/execute/mutate as needed");
        print("  library                     list crystallized procedures (skills)");
        print("  soul                        show identity, config, skills & memory (all graph state)");
        print("  configure <key> <value>     mutate config on the graph (persona|*_model|add_ethos|add_channel)");
        print("  teach \"<fact>\"              write a durable memory onto the graph");
        print("  recall \"<query>\"            retrieve relevant memories");
        print("  (add  -s prometheus.session  to persist the graph across runs)");
    }
}
