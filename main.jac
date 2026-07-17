"""Sigil CLI — the agent has no config files. Its soul, skills and memory
all live on the graph, persisted automatically in `.jac/data/sigil.db` across runs:

    jac run main.jac -- chat                 # interactive Claude-style REPL
    jac run main.jac -- config               # interactive settings editor
    jac run main.jac -- solve "extract tables from report.pdf as csv"
    jac run main.jac -- solve "..."          # reuses / evolves the graph
    jac run main.jac -- soul
    jac run main.jac -- configure small_model ollama_chat/qwen3:8b
    jac run main.jac -- teach "the user always wants CSV with a header row"
    jac run main.jac -- serve                # REST API + Observatory web UI

`chat` and `config` live in sigil_chat.jac (rich + prompt_toolkit); both drive the
same persistent graph as the one-shot commands above — and as `serve`, which
exposes that very graph through the Observatory.
"""

import os;
import sys;
import time;
import sqlite3;
import subprocess;
import from src.sigil {
    solve_task, library, describe_soul, configure, teach, recollect,
    add_mcp, remove_mcp, mcp_status, register_skill, compile_skill,
    eval_skill, relearn, forget,
    model_alias, model_set_fallback, models_info,
    tool_group_set, tool_allowed, tools_policy_info
}
import from src.cron {
    cron_add, cron_list, cron_show, cron_runs, cron_remove, cron_enable, cron_tick
}
import from src.channels { channel_add, channel_list, channel_remove, message_send, inbound, react, edit, channel_history }
import from src.sigil_channels_setup { channel_setup_guide, channel_bootstrap, channel_kinds }
import from src.sigil_docs { list_docs, read_doc }
import from src.hooks { hook_add, hook_list, hook_enable, hook_remove }
import from src.approvals { approvals_get, approvals_set, allowlist_add, check_exec, approve, approvals_elevate, approvals_deescalate, elevated_audit }
import from src.agent { run_task }
import from src.sigil_tasks { tasks_list, tasks_show }
import from src.sigil_secrets { secret_add, secret_remove, secret_list, secret_test, redact_secrets }
import from src.sigil_plugins { plugin_install, plugin_list, plugin_remove }
import from src.sigil_migrate { migrate_openclaw }
import from src.sigil_runtime { _jac_bin }
import from src.sigil_sessions { session_note, session_show, session_reset, session_list }

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

# The all-zeros superroot — the root every plain `jac run` executes against.
glob SUPERROOT: str = "00000000000000000000000000000000";

def _align_guest_root(data_dir: str) -> bool {
    # In server mode, anonymous requests to `:pub` walkers run as the internal
    # `__guest__` user, whose root defaults to a fresh anchor — a graph parallel
    # to the CLI's. Point guest at the superroot so the CLI and the Observatory
    # read and write ONE graph. Returns True once the auth store has been seen
    # (aligned or already correct); False while it doesn't exist yet.
    users = os.path.join(data_dir, "users.db");
    if not os.path.exists(users) { return False; }
    try {
        conn = sqlite3.connect(users);
        conn.execute(
            "UPDATE identity_users SET root_id = ? WHERE identities LIKE '%__guest__%' AND root_id != ?",
            (SUPERROOT, SUPERROOT)
        );
        conn.commit();
        conn.close();
        return True;
    } except Exception {
        return False;
    }
}

def serve_observatory(port: str) {
    # `sigil serve` — run the full-stack server (REST API + Observatory web UI)
    # on the same graph as the CLI. jac.toml pins the server's SQLite store to
    # `.jac/data/sigil.db` (the CLI's project db); this handles the root side.
    proj = os.path.dirname(os.path.abspath(__file__));
    data = os.path.join(proj, ".jac", "data");
    aligned = _align_guest_root(data);
    cmdline = [_jac_bin(), "start", os.path.join(proj, "observatory.jac")];
    if port { cmdline.extend(["--port", port]); }
    p = subprocess.Popen(cmdline, cwd=proj);
    try {
        # First-ever start: the server creates the auth store moments after
        # boot; align the guest root as soon as it lands so run #1 shares the
        # graph too. Bounded poll — worst case ~5 min covers a cold client build.
        tries = 0;
        while (not aligned) and (p.poll() is None) and (tries < 600) {
            time.sleep(0.5);
            aligned = _align_guest_root(data);
            tries += 1;
        }
        p.wait();
    } except KeyboardInterrupt {
        p.terminate();
        p.wait();
    }
}

with entry:__main__ {
    argv = cli_args(sys.argv);
    cmd = _arg(argv, 0) if argv else "help";

    if (cmd == "serve") or (cmd == "observatory") {
        serve_observatory(_arg(argv, 1));
    } elif cmd == "solve" {
        task = _arg(argv, 1);
        skill = _arg(argv, 2);
        if not task {
            print("usage: solve \"<task>\" [skill]");
        } else {
            r = run_task(task, skill);
            print("=== route trace ===");
            print(r["trace"]);
            print("=== signature: " + r["signature"] + " ===");
            print(redact_secrets(str(r["result"])));   # never surface a resolved secret
        }
    } elif cmd == "library" {
        lib = library();
        if not lib {
            print("(empty — no compiled procedures yet)");
        } else {
            print("compiled procedures (" + str(len(lib)) + "):");
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
        print("  channels: " + ", ".join([str(c) for c in s["channels"]]) + "   prompt-mode: " + str(s["prompt_mode"]));
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
    } elif cmd == "models" {
        # models list | set <tier> <name> | alias <name> <model> | fallback <tier> <m1,m2,...>
        sub = _arg(argv, 1);
        if sub == "set" { print(configure(_arg(argv, 2) + "_model", _arg(argv, 3))); }
        elif sub == "alias" { print(model_alias(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "fallback" { print(model_set_fallback(_arg(argv, 2), _arg(argv, 3))); }
        elif (sub == "list") or (not sub) {
            mi = models_info();
            print("tiers:");
            print("  frontier : " + str(mi["frontier"]));
            print("  small    : " + str(mi["small"]));
            print("  router   : " + str(mi["router"]));
            al = dict(mi["aliases"]);
            if al { print("aliases:"); for (k, v) in al.items() { print("  " + str(k) + " -> " + str(v)); } }
            fb = dict(mi["fallbacks"]);
            has_fb = False;
            for (k, v) in fb.items() { if v { has_fb = True; } }
            if has_fb { print("fallbacks:"); for (k, v) in fb.items() { if v { print("  " + str(k) + " : " + str(v)); } } }
        }
        else { print("usage: models list|set <tier> <name>|alias <name> <model>|fallback <tier> <m1,m2>"); }
    } elif cmd == "teach" {
        fact = _arg(argv, 1);
        if not fact { print("usage: teach \"<fact>\""); }
        else { print(teach(fact, "fact")); }
    } elif cmd == "recall" {
        q = _arg(argv, 1);
        for m in recollect(q, 8) { print("  (" + m["kind"] + ") " + m["content"]); }
    } elif cmd == "docs" {
        # docs           -> list reference topics
        # docs <topic>   -> print one (fuzzy match)
        topic = _arg(argv, 1);
        if topic { print(read_doc(topic)); }
        else { print(list_docs()); }
    } elif cmd == "eval" {
        # eval <signature> [probe-task]  — grounded verification of a compiled skill
        sig = _arg(argv, 1); probe = _arg(argv, 2);
        if not sig { print("usage: eval <signature> [probe-task]"); }
        else {
            r = eval_skill(sig, probe);
            if not r["ok"] { print(str(r["error"])); }
            else {
                print("eval " + str(r["signature"]) + " v" + str(r["version"]) + " -> "
                      + str(r["score"]) + "/100  " + ("PASS" if r["passed"] else "FAIL"));
                print("  reason: " + str(r["reason"]));
                print("  result: " + str(r["result"]));
            }
        }
    } elif cmd == "relearn" {
        # relearn <signature> [hint]  — discard + recompile a skill fresh (frontier)
        sig = _arg(argv, 1); hint = _arg(argv, 2);
        if not sig { print("usage: relearn <signature> [hint]"); }
        else {
            r = relearn(sig, hint);
            if not r["ok"] { print(str(r["error"])); }
            else { print("relearned " + str(r["signature"]) + " -> v" + str(r["version"]) + " [" + str(r["origin"]) + "]"); }
        }
    } elif cmd == "forget" {
        # forget <signature>  — remove a skill entirely (all versions + module files)
        sig = _arg(argv, 1);
        if not sig { print("usage: forget <signature>"); }
        else {
            r = forget(sig);
            print("forgot '" + str(r["signature"]) + "' (" + str(r["removed"]) + " version(s) removed)");
        }
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
    } elif cmd == "compile" {
        # compile <SKILL.md> [-e|--eject [out.jac]] — the gated AI lift: spec
        # loop -> spine -> flows -> assemble -> G1/G4/G5 gates + repair. Sets
        # the skill on the graph; -e also ejects one runnable .jac program.
        path = _arg(argv, 1);
        if (not path) or path.startswith("-") {
            print("usage: compile <SKILL.md> [-e|--eject [out.jac]]");
        } else {
            eject = False; eject_path = "";
            i = 2;
            while i < len(argv) {
                flg = _arg(argv, i);   # not `a` — the entry block is one scope and `a` is reused below as a list
                if (flg == "-e") or (flg == "--eject") {
                    eject = True;
                    nxt = _arg(argv, i + 1);
                    if nxt and (not nxt.startswith("-")) { eject_path = nxt; i += 1; }
                }
                i += 1;
            }
            r = compile_skill(open(path).read(), eject, eject_path);
            if not r["ok"] {
                print("compile FAILED for '" + str(r["signature"]) + "':");
                for iss in list(r["issues"] or []) { print("  - " + str(iss)); }
                if r["compile_errors"] { print("  compile: " + str(r["compile_errors"])[:400]); }
                for rp in list(r["repairs"] or []) { print("  (repair) " + str(rp)); }
            } else {
                print("compiled skill: " + str(r["signature"]) + "  [compiled-skill]  -> " + str(r["module"]));
                for rp in list(r["repairs"] or []) { print("  (repair) " + str(rp)); }
                if r["eject"] {
                    print("ejected runnable: " + str(r["eject"]));
                    print("  run it:  ./" + str(r["eject"]) + " \"<task>\"    (SIGIL_MODEL=... to pick the model)");
                }
            }
        }
    } elif cmd == "replay" {
        # replay <agent.jac> <observability.jsonl> "<task>" [workdir] — re-run a
        # RECORDED run's cognition through the (re)compiled module: no model, no
        # cost; regression-test compiler changes against real runs.
        modp = _arg(argv, 1); obsp = _arg(argv, 2); rtask = _arg(argv, 3);
        rwd = _arg(argv, 4) if len(argv) > 4 else ".";
        if (not modp) or (not obsp) or (not rtask) {
            print("usage: replay <agent.jac> <observability.jsonl> \"<task>\" [workdir]");
        } else {
            import from src.compiler.ai.replay { replay_run }
            rr = replay_run(modp, obsp, rtask, rwd);
            print("replay: " + str(rr["calls_used"]) + "/" + str(rr["calls_recorded"])
                  + " recorded calls, " + str(rr["nodes"]) + " nodes visited");
            if rr["error"] { print("  error: " + str(rr["error"])); }
            print("  report: " + str(rr["report"])[:400]);
        }
    } elif cmd == "channel" {
        sub = _arg(argv, 1);
        if sub == "add" { r = channel_add(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5) if len(argv) > 5 else "per-peer"); print("channel '" + str(r["name"]) + "' [" + str(r["kind"]) + "]"); }
        elif sub == "list" { for c in channel_list() { print("  " + str(c["name"]) + "  [" + str(c["kind"]) + "]  " + ("on" if c["enabled"] else "off") + "  msgs=" + str(c["messages"])); } }
        elif sub == "rm" { print(channel_remove(_arg(argv, 2))); }
        elif sub == "send" { r = message_send(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5)); print("sent to " + str(r["peer"]) + " on " + str(r["channel"]) + "  mid=" + str(r["mid"])); }
        elif sub == "inbound" { r = inbound(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4), _arg(argv, 5)); print("reply: " + str(r["reply"]) + "  (in=" + str(r["in_mid"]) + " out=" + str(r["out_mid"]) + " thread=" + str(r["thread_id"]) + ")"); }
        elif sub == "setup" {
            # channel setup <discord|telegram|whatsapp|slack> — print connection guidance
            k = _arg(argv, 2);
            if not k { print("supported: " + ", ".join(channel_kinds())); print("usage: channel setup <" + "|".join(channel_kinds()) + ">"); }
            else { print(channel_setup_guide(k)); }
        }
        elif sub == "connect" {
            # channel connect <name> <kind> — register the Channel node + token SecretRef, then print next steps
            nm = _arg(argv, 2); k = _arg(argv, 3) if _arg(argv, 3) else _arg(argv, 2);
            if not nm { print("usage: channel connect <name> <discord|telegram|whatsapp|slack>"); }
            else {
                r = channel_bootstrap(nm, k, "");
                print("connected channel '" + str(r["name"]) + "'  kind=" + str(r["kind"]) + "  token-env=" + str(r["token_env"]) + " (set=" + str(r["token_set"]) + ")");
                print("inbound endpoint: " + str(r["endpoint"]));
                print("");
                print(str(r["guide"]));
            }
        }
        elif sub == "react" { print(react(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4))); }
        elif sub == "edit" { print(edit(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4))); }
        elif sub == "history" {
            for m in channel_history(_arg(argv, 2), 20) {
                rx = list(m["reactions"]);
                line = "  " + str(m["mid"]) + "  " + str(m["dir"]) + "  " + str(m["peer"]);
                if m["thread"] { line += "  thread=" + str(m["thread"]); }
                if m["edited"] { line += "  (edited)"; }
                if rx { line += "  reacts=" + ",".join([str(x) for x in rx]); }
                print(line + "  " + str(m["text"]));
            }
        }
        else { print("usage: channel add|list|rm|send|inbound|setup <kind>|connect <name> <kind>|react <ch> <mid> <emoji>|edit <ch> <mid> <text>|history <ch>"); }
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
        if sub == "get" { g = approvals_get(); print("security=" + str(g["security"]) + " ask=" + str(g["ask"]) + "  elevated=" + ("yes (" + str(int(int(g["elevated_ms_left"]) / 60000)) + "m left)" if g["elevated"] else "no")); print("allowlist: " + ", ".join([str(x) for x in list(g["allowlist"])])); print("pending: " + str(len(list(g["pending"])))); }
        elif sub == "set" { print(approvals_set(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "allow" { print(allowlist_add(_arg(argv, 2))); }
        elif sub == "check" { print(check_exec(_arg(argv, 2))["decision"]); }
        elif sub == "approve" { print(approve(_arg(argv, 2), _arg(argv, 3) if len(argv) > 3 else "allow-once")); }
        elif sub == "elevate" { print(approvals_elevate(int(_arg(argv, 2)) if _arg(argv, 2) else 15)); }
        elif sub == "deescalate" { print(approvals_deescalate()); }
        elif sub == "audit" { a = elevated_audit(); if not a { print("(no elevated allows recorded)"); } for e in a { print("  " + str(e["cmd"])); } }
        else { print("usage: approvals get|set <sec> <ask>|allow <pattern>|check <cmd>|approve <cmd> <decision>|elevate <min>|deescalate|audit"); }
    } elif cmd == "tasks" {
        # tasks list [n] | show <n>  — unified ledger over solve Attempts + cron runs
        sub = _arg(argv, 1);
        if sub == "show" {
            n = int(_arg(argv, 2)) if _arg(argv, 2) else 0;
            r = tasks_show(n);
            if not r { print("no such task (try: tasks list)"); }
            else {
                print("#" + str(n) + "  [" + str(r["kind"]) + "]  " + str(r["label"]) + "  " + ("ok" if r["ok"] else "err"));
                print("  when   : " + str(r["at_ms"]));
                print("  model  : " + str(r["model"]));
                print("  task   : " + str(r["detail"]));
                print("  summary: " + str(r["summary"]));
            }
        } else {
            n = int(_arg(argv, 2)) if (sub == "list" and _arg(argv, 2)) else 20;
            items = tasks_list(n);
            if not items { print("(no task history yet)"); }
            i = 1;
            for r in items {
                oneline = str(r["summary"]).replace(chr(10), " ").replace(chr(13), " ");
                print("  " + str(i).rjust(3) + "  [" + str(r["kind"]) + "]  " + str(r["label"]).ljust(16)
                      + "  " + ("ok " if r["ok"] else "err") + "  " + oneline[:70]);
                i += 1;
            }
        }
    } elif cmd == "secret" {
        # secret add <name> <ENV_VAR> | list | rm <name> | test <name>   (values are never printed)
        sub = _arg(argv, 1);
        if sub == "add" { print(secret_add(_arg(argv, 2), _arg(argv, 3))); }
        elif sub == "rm" { print(secret_remove(_arg(argv, 2))); }
        elif sub == "test" { t = secret_test(_arg(argv, 2)); print("resolvable=" + str(t["resolvable"]) + "  length=" + str(t["length"]) + "  redacted='" + str(t["redacted"]) + "'"); }
        elif (sub == "list") or (not sub) {
            sl = secret_list();
            if not sl { print("(no secrets registered)"); }
            for s in sl { print("  " + str(s["name"]) + " -> $" + str(s["env"]) + "  [" + ("set" if s["set"] else "unset") + "]"); }
        }
        else { print("usage: secret add <name> <ENV_VAR>|list|rm <name>|test <name>"); }
    } elif cmd == "plugin" {
        # plugin install <openclaw.plugin.json> | list | rm <name>
        sub = _arg(argv, 1);
        if sub == "install" {
            if not _arg(argv, 2) { print("usage: plugin install <openclaw.plugin.json>"); }
            else { r = plugin_install(_arg(argv, 2)); print("installed '" + str(r["name"]) + "'  servers=" + str(len(list(r["servers"]))) + " skills=" + str(len(list(r["skills"])))); }
        }
        elif sub == "rm" { print(plugin_remove(_arg(argv, 2))); }
        elif (sub == "list") or (not sub) {
            pl = plugin_list();
            if not pl { print("(no plugins installed)"); }
            for p in pl { print("  " + str(p["name"]) + " v" + str(p["version"]) + "  servers=[" + ",".join([str(x) for x in list(p["servers"])]) + "]  skills=[" + ",".join([str(x) for x in list(p["skills"])]) + "]"); }
        }
        else { print("usage: plugin install <openclaw.plugin.json>|list|rm <name>"); }
    } elif cmd == "migrate" {
        # migrate openclaw <dir>  — fold an OpenClaw export (SOUL.md + config + skills) onto the graph
        sub = _arg(argv, 1); path = _arg(argv, 2);
        if (sub == "openclaw") and path {
            r = migrate_openclaw(path);
            print("migrated: persona=" + str(r["persona"]) + "  ethos+=" + str(r["ethos"])
                  + "  channels+=" + str(r["channels"]) + "  models=" + str(r["models"]) + "  skills+=" + str(r["skills"]));
        }
        else { print("usage: migrate openclaw <dir>"); }
    } elif cmd == "tools" {
        # tools policy | check <name> | group <name> <t1,t2,...>   (allow/deny via `configure tool_allow|tool_deny|tool_profile`)
        sub = _arg(argv, 1);
        if sub == "check" { print(_arg(argv, 2) + ": " + ("allowed" if tool_allowed(_arg(argv, 2)) else "DENIED")); }
        elif sub == "group" { print(tool_group_set(_arg(argv, 2), _arg(argv, 3))); }
        elif (sub == "policy") or (not sub) {
            p = tools_policy_info();
            print("allow    : " + (", ".join([str(x) for x in list(p["allow"])]) or "(any)"));
            print("deny     : " + (", ".join([str(x) for x in list(p["deny"])]) or "(none)"));
            print("profile  : " + (str(p["profile"]) or "(none)"));
            gr = dict(p["groups"]);
            if gr { print("groups   :"); for (k, v) in gr.items() { print("  " + str(k) + " = " + str(v)); } }
            print("effective allow: " + (", ".join([str(x) for x in list(p["effective_allow"])]) or "(any)"));
            print("effective deny : " + (", ".join([str(x) for x in list(p["effective_deny"])]) or "(none)"));
        }
        else { print("usage: tools policy|check <name>|group <name> <t1,t2,...>   (set allow/deny via configure tool_allow|tool_deny|tool_profile)"); }
    } elif cmd == "session" {
        # session note <ch> <peer> <role> <text> | show <ch> <peer> | reset <ch> <peer> | list
        sub = _arg(argv, 1);
        if sub == "note" { print(session_note(_arg(argv, 2), _arg(argv, 3), "per-peer", _arg(argv, 4), _arg(argv, 5))); }
        elif sub == "show" {
            ts = session_show(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4) or "per-peer");
            if not ts { print("(empty transcript)"); }
            for t in ts { print("  " + str(t["role"]) + ": " + str(t["text"])); }
        }
        elif sub == "reset" { print(session_reset(_arg(argv, 2), _arg(argv, 3), _arg(argv, 4) or "per-peer")); }
        elif (sub == "list") or (not sub) {
            sl = session_list();
            if not sl { print("(no sessions)"); }
            for s in sl { print("  " + str(s["key"]) + "  day=" + str(s["day"]) + "  turns=" + str(s["turns"])); }
        }
        else { print("usage: session note <ch> <peer> <role> <text>|show <ch> <peer>|reset <ch> <peer>|list"); }
    } elif cmd == "chat" {
        import from src.sigil_chat { chat_repl }
        chat_repl();
    } elif cmd == "setup" {
        import from src.sigil_chat { setup_wizard }
        setup_wizard();
    } elif cmd == "config" {
        # `config` alone -> interactive editor; `config <key> <value>` -> set one key.
        key = _arg(argv, 1); val = _arg(argv, 2);
        if key and val { print(configure(key, val)); }
        else {
            import from src.sigil_chat { config_menu }
            config_menu();
        }
    } else {
        print("Sigil — a self-evolving object-spatial agent (soul, skills & memory on the graph)");
        print("  chat                        conversational tool-using REPL — run the whole agent from chat");
        print("                              (sandboxed files+shell, web, cron, memory, sub-agents, channels)");
        print("  serve [port]                start the server: REST API + Observatory web UI, on the");
        print("                              same graph the CLI uses (alias: observatory)");
        print("  setup                       first-run wizard to configure models & persona");
        print("  channel setup <kind>        how to connect discord|telegram|whatsapp|slack");
        print("  channel connect <name> <kind>   register a channel + its token secret, print next steps");
        print("  config [<key> <value>]      interactive settings editor (or set one key)");
        print("  solve \"<task>\" [skill]     route a task; compile/execute/mutate as needed");
        print("  library                     list compiled procedures (skills)");
        print("  tasks list [n] | show <n>   background task ledger (solve runs + cron fires)");
        print("  eval <sig> [probe]          grounded-eval a skill (run + judge the artifact)");
        print("  relearn <sig> [hint]        recompile a skill fresh with the frontier");
        print("  forget <sig>                remove a skill entirely (all versions + files)");
        print("  docs [<topic>]              Sigil's own reference (how it works, config, tools)");
        print("  soul                        show identity, config, skills & memory (all graph state)");
        print("  configure <key> <value>     config on the graph (persona|*_model|add_ethos|add_channel|auto_eval|eval_threshold)");
        print("  models list|set|alias|fallback   manage model tiers, aliases & fallback pools");
        print("  configure <key> <value>     config on the graph (persona|*_model|add_ethos|add_channel|auto_eval|eval_threshold|prompt_mode)");
        print("  teach \"<fact>\"              write a durable memory onto the graph");
        print("  recall \"<query>\"            retrieve relevant memories");
        print("  add-mcp <name> <transport> <cmd-or-url> [args...]   register a BYO MCP server");
        print("  remove-mcp <name>           unregister an MCP server");
        print("  mcp                         list registered MCP servers + their tools");
        print("  register-skill <path> [md|agir|osp]   add a skill (SKILL.md lifted / AG-IR / OSP)");
        print("  compile <SKILL.md> [-e [out.jac]]     gated AI-compile onto the graph; -e ejects a standalone runnable .jac");
        print("  replay <agent.jac> <obs.jsonl> \"<task>\"   re-run recorded cognition through a module (free)");
        print("  (the graph persists in .jac/data/sigil.db across runs — CLI and server share it)");
    }
}
