"""Prometheus CLI.

    jac run main.jac -- solve "extract the tables from report.pdf as csv"
    jac run main.jac -- library

Persist the agent graph across invocations with a session file:

    jac run main.jac -s prometheus.session -- solve "..."
    jac run main.jac -s prometheus.session -- solve "..."   # second task reuses/evolves the graph
"""

import sys;
import from prometheus { solve_task, library }

with entry:__main__ {
    argv = sys.argv;
    cmd = argv[1] if len(argv) > 1 else "help";

    if cmd == "solve" {
        task = argv[2] if len(argv) > 2 else "";
        skill = argv[3] if len(argv) > 3 else "";
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
    } else {
        print("Prometheus — self-evolving object-spatial agent");
        print("  jac run main.jac -s prometheus.session -- solve \"<task>\" [skill]");
        print("  jac run main.jac -s prometheus.session -- library");
    }
}
