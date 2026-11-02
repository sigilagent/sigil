"""What every API name does — one table, called by the server and by `sigil api`.

The Observatory's endpoints (src/sigil.jac, src/sigil_console.jac) used to answer
by starting a fresh `sigil api <name>` process per request, because the server
once read a different graph from the CLI. That process loaded all of Sigil to do
a few milliseconds of work: about 12 seconds a request, four of them to open the
Studio. Since the server points its `__guest__` root at the CLI's superroot and
jac.toml points it at the CLI's store (src/main.jac `serve_observatory`), the
server answers from the same graph itself, in its own request context, which
jac commits when the request ends.

So this table is the one place a name becomes a call. `api_dispatch` runs in the
server's request thread (`report_for` in src/sigil_api.jac) and in the `sigil api`
command, and both hand back the same plain-JSON payload.
"""

import json;
import from .sigil {
    library, describe_soul, configure, teach, recollect, add_mcp, mcp_status,
    register_skill, eval_skill, relearn, forget
}
import from .agent { run_task }
import from .cron { cron_list, cron_runs, cron_remove, cron_enable, cron_tick }
import from .channels { channel_list, inbound }
import from .hooks { hook_list }
import from .approvals { approvals_get }
import from .sigil_tasks { tasks_list }

def _stringify(o: any) -> str { return str(o); }

def api_json(payload: dict[str, any]) -> str {
    # One JSON line. Anything the encoder cannot represent becomes its string
    # form rather than an exception: a slightly lossy answer beats a 500 because
    # a value was a node.
    try { return str(json.dumps(payload, `default=_stringify)); }
    except Exception { return "{\"ok\": false, \"data\": null, \"error\": \"unencodable result\"}"; }
}

def api_dispatch(name: str, a: dict[str, any]) -> dict[str, any] {
    # {"ok", "data", "error"} for one API call. Never raises: a failure is the
    # payload's error, so an endpoint says why instead of returning a 500.
    payload: dict[str, any] = {"ok": True, "data": None, "error": ""};
    try {
        if name == "soul" { payload["data"] = describe_soul(); }
        elif name == "graph" {
            # The typed view-model leaves as plain dicts, or json would flatten
            # VGraph to its repr and the client would read `nodes: undefined`.
            import from .sigil { graph_snapshot }
            vg = graph_snapshot();
            payload["data"] = {
                "nodes": [{"id": n.id, "label": n.label, "group": n.group, "detail": n.detail}
                          for n in vg.nodes],
                "edges": [{"src": e.src, "dst": e.dst, "kind": e.kind} for e in vg.edges],
                "skills": vg.skills, "memories": vg.memories, "mcp": vg.mcp
            };
        }
        elif name == "library" { payload["data"] = library(); }
        elif name == "mcp" { payload["data"] = mcp_status(); }
        elif name == "observability" {
            # Same rule as "graph": VObs leaves as plain dicts.
            import from .sigil { observability_tail }
            vo = observability_tail(int(a.get("n", 120)));
            payload["data"] = {
                "calls": [{"model": c.model, "signature": c.signature,
                           "prompt_tokens": c.prompt_tokens,
                           "completion_tokens": c.completion_tokens,
                           "reasoning_tokens": c.reasoning_tokens,
                           "cache_read_tokens": c.cache_read_tokens,
                           "cost_usd": c.cost_usd, "content": c.content,
                           "reasoning": c.reasoning, "tools": c.tools}
                          for c in vo.calls],
                "tin": vo.tin, "tout": vo.tout, "treason": vo.treason,
                "cost": vo.cost, "n": vo.n
            };
        }
        elif name == "recall" { payload["data"] = recollect(str(a.get("query", "")), int(a.get("k", 8))); }
        elif name == "teach" { payload["data"] = teach(str(a.get("fact", "")), str(a.get("kind", "fact"))); }
        elif name == "configure" { payload["data"] = configure(str(a.get("key", "")), str(a.get("value", ""))); }
        elif name == "solve" { payload["data"] = run_task(str(a.get("task", "")), str(a.get("skill", ""))); }
        elif name == "register_skill" { payload["data"] = register_skill(str(a.get("source", "")), str(a.get("kind", "md"))); }
        elif name == "add_mcp" {
            payload["data"] = add_mcp(str(a.get("name", "")), str(a.get("transport", "stdio")),
                                      str(a.get("target", "")), list(a.get("args") or []));
        }
        elif name == "eval" { payload["data"] = eval_skill(str(a.get("signature", "")), str(a.get("probe", ""))); }
        elif name == "relearn" { payload["data"] = relearn(str(a.get("signature", "")), str(a.get("hint", ""))); }
        elif name == "forget" { payload["data"] = forget(str(a.get("signature", ""))); }
        elif name == "chat" {
            r = run_task(str(a.get("text", "")), "");
            payload["data"] = {
                "id": "sigil-chatcmpl", "object": "chat.completion",
                "model": str(a.get("model", "sigil")),
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": str(r["result"])}}]
            };
        }
        elif name == "models" {
            data: list[any] = [];
            for tier in ["frontier", "small", "router"] {
                data.append({"id": "sigil-" + tier, "object": "model", "owned_by": "sigil"});
            }
            for e in list(library()) {
                sk = dict(e);
                data.append({"id": "sigil-skill/" + str(sk["signature"]), "object": "model", "owned_by": "sigil"});
            }
            payload["data"] = {"object": "list", "data": data};
        }
        elif name == "tools_invoke" {
            import from .sigil_mcp { dispatch }
            res = dispatch(str(a.get("name", "")), [dict(a.get("arguments") or {})]);
            if res is None {
                payload["ok"] = False;
                payload["error"] = "no registered tool '" + str(a.get("name", "")) + "'";
            } else { payload["data"] = res; }
        }
        elif name == "inbound" {
            payload["data"] = inbound(str(a.get("channel", "webhook")), str(a.get("peer", "anon")),
                                      str(a.get("text", "")), str(a.get("thread_id", "")));
        }
        elif name == "cron_tick" { payload["data"] = cron_tick(); }
        elif name == "cron_list" { payload["data"] = cron_list(); }
        elif name == "cron_runs" { payload["data"] = cron_runs(str(a.get("name", ""))); }
        elif name == "cron_enable" { payload["data"] = cron_enable(str(a.get("name", "")), bool(a.get("on", True))); }
        elif name == "cron_remove" { payload["data"] = cron_remove(str(a.get("name", ""))); }
        elif name == "skill_agir" {
            import from .sigil_agir_view { skill_agir }
            payload["data"] = skill_agir(str(a.get("signature", "")));
        }
        elif name == "tasks" { payload["data"] = tasks_list(int(a.get("n", 20))); }
        elif name == "hooks" { payload["data"] = hook_list(); }
        elif name == "channels" { payload["data"] = channel_list(); }
        elif name == "approvals" { payload["data"] = approvals_get(); }
        elif name == "console" {
            # Everything the web console adds, behind one name: see
            # src/sigil_console.jac for the ops and what each returns.
            import from .sigil_console { console_dispatch }
            payload["data"] = console_dispatch(str(a.get("op", "")), dict(a.get("args") or {}));
        }
        else {
            payload["ok"] = False;
            payload["error"] = "unknown api '" + str(name) + "'";
        }
    } except Exception as err {
        payload["ok"] = False;
        payload["error"] = str(err)[:600];
    }
    return payload;
}
