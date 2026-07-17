"""MCP integration — a thin adapter over byLLM's *native* MCP client.

byLLM ships `McpClient`/`McpTool` (jaclang.byllm.lib): a client connects to an MCP server
(stdio / sse / streamable-http via the `mcp` package) and `get_tools()` returns
`McpTool`s that are drop-in tools for `by llm(tools=[...])`. We reuse that instead
of speaking JSON-RPC ourselves — the compiled agent gets the same MCP stack
byLLM uses everywhere.

This module does two jobs for Sigil:
  - `dispatch(name, args)` — deterministic embodiment: a compiled agent's
    `_live_tool(name, ...)` routes a bare tool name to whichever registered server
    exposes it (servers come from the `SIGIL_MCP` env Sigil sets per run).
  - `digest(servers)` / `tools_for(servers)` — discovery: list the tools a set of
    servers expose, so the frontier can bind real tool names when it compiles,
    and so the ReAct/scoped-author slots can be handed the live `McpTool`s.

Everything is non-raising: an unreachable server yields no tools / a typed error,
never an exception — a compiled run degrades to an honest sentinel.
"""

import json;
import os;

glob _CLIENTS: dict = {};   # server-name -> McpClient   (per-process, reused)
glob _TOOLS: dict = {};     # server-name -> [McpTool]

def _map_transport(t: str) -> str {
    return {"http": "streamable-http", "": "auto"}.get(t, t or "auto");
}

def _client_for(srv: any) -> any {
    name = srv.get("name") or srv.get("command") or srv.get("url") or "mcp";
    if name in _CLIENTS {
        return _CLIENTS[name];
    }
    import from jaclang.byllm.lib { McpClient }
    hdrs: dict[str, str] = dict(srv.get("headers", {}) or {});
    envd: dict[str, str] = dict(srv.get("env", {}) or {});
    c = McpClient(
        command=str(srv.get("command", "")),
        args=list(srv.get("args", []) or []),
        env=envd,
        url=str(srv.get("url", "")),
        headers=hdrs,
        transport=_map_transport(str(srv.get("transport", "auto"))),
        timeout=int(srv.get("timeout", 30)),
    );
    _CLIENTS[name] = c;
    return c;
}

def _safe_tools(srv: any) -> list {
    name = srv.get("name", "mcp");
    if name not in _TOOLS {
        try {
            _TOOLS[name] = _client_for(srv).get_tools();
        } except Exception as e {
            _TOOLS[name] = [];
        }
    }
    return list(_TOOLS.get(name) or []);
}

def _tool_permitted(name: str) -> bool {
    # Tool-policy gate (deny wins, then allow-list). The effective allow/deny lists are
    # expanded from the Soul policy in the main process and passed via env, so BOTH the
    # compiler binding (below) and run-time dispatch (isolated subprocess) honor it.
    deny = [x.strip() for x in os.getenv("SIGIL_TOOL_DENY", "").split(",") if x.strip()];
    allow = [x.strip() for x in os.getenv("SIGIL_TOOL_ALLOW", "").split(",") if x.strip()];
    if (name in deny) or ("*" in deny) { return False; }
    if allow { return (name in allow) or ("*" in allow); }
    return True;
}

def tools_for(servers: list) -> list {
    # Live McpTool objects across the given servers — pass straight to by llm(tools=).
    # Policy-denied tools are dropped here so the compiler never binds them.
    out = [];
    for srv in servers or [] {
        if not srv.get("enabled", True) {
            continue;
        }
        for t in _safe_tools(srv) { if _tool_permitted(str(t.name)) { out.append(t); } }
    }
    return out;
}

def digest(servers: list) -> str {
    # Human/LLM-readable catalogue of registered tools, for the compiler prompt.
    lines = [];
    for srv in servers or [] {
        if not srv.get("enabled", True) {
            continue;
        }
        sname = srv.get("name", "mcp");
        for t in _safe_tools(srv) {
            props = list(((getattr(t, "input_schema", {}) or {}).get("properties") or {}).keys());
            desc = (getattr(t, "description", "") or "").strip().replace("\n", " ")[:120];
            lines.append(f"- {t.name}({', '.join(props)})  [{sname}]  {desc}");
        }
    }
    return "\n".join(lines);
}

def _servers_from_env() -> list {
    raw = os.getenv("SIGIL_MCP", "");
    if not raw {
        return [];
    }
    try {
        return [s for s in json.loads(raw) if s.get("enabled", True)];
    } except Exception as e {
        return [];
    }
}

def dispatch(tool_name: str, args: list) -> dict | None {
    # Route a bare tool name to the registered server that exposes it (embodiment
    # rung-0). Returns {ok, text, error} on a match, or None when no registered
    # server has the tool (caller falls back to its own behavior). Positional args
    # map onto the tool's inputSchema property order; a single dict arg is verbatim.
    servers = _servers_from_env();
    if not servers {
        return None;
    }
    if not _tool_permitted(tool_name) {
        return {"ok": False, "text": "", "error": "tool '" + tool_name + "' denied by policy"};
    }
    for srv in servers {
        for t in _safe_tools(srv) {
            if t.name == tool_name {
                if len(args) == 1 and isinstance(args[0], dict) {
                    arguments = args[0];
                } else {
                    props = list(((getattr(t, "input_schema", {}) or {}).get("properties") or {}).keys());
                    arguments = {props[i]: v for (i, v) in enumerate(args) if i < len(props)};
                }
                try {
                    return {"ok": True, "text": str(t(**arguments)), "error": ""};
                } except Exception as e {
                    return {"ok": False, "text": "", "error": str(e)[:300]};
                }
            }
        }
    }
    return None;
}
