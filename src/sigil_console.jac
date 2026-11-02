"""The console's backend: what the web console does that the Observatory could
not, behind one endpoint.

Every page of the console (web/) calls `api_console(op, args)`. Most ops need the
agent's graph, so they run where every other endpoint runs, in a fresh `jac run`
of the CLI (`report_for` -> `api console` in src/main.jac -> `console_dispatch`
here). A few never touch the graph (a compile job's files and the secrets file)
and those answer from the server process itself (`LOCAL_OPS`): a page polling a
compile every two seconds should not start a process every two seconds.

Compiling from the browser is a JOB, not a request. `compile_start` writes the
uploaded skill folder to $SIGIL_HOME/compile/<id>/skill and starts a detached
`api console compile_run` process. That process runs the same `compile_skill` the
`compile` verb runs and records what happens in the job folder: one JSON line per
stage event, the question it is waiting on, the result. `compile_status` reads
the folder. When the skill leaves an obligation's force open and the person chose
"Ask me", the job writes the question and waits for an answer file, the way
`--clarify` waits at a terminal.
"""

import os;
import json;
import time;
import uuid;
import shutil;
import subprocess;
import from .sigil_runtime { sigil_home, _jac_bin, entry_script, project_root }
import from .sigil_api { report_for, _foreign_request, child_env }
import from .sigil_secrets {
    secret_value_set, secret_value_clear, secret_source, secret_tail, env_name_ok,
    secrets_env_path
}

walker:pub api_console {
    has op: str;
    has args: dict[str, any] = {};
    can run with Root entry { report console_endpoint(self.op, self.args); }
}

# Ops answered by the server process: file work only, never the graph. The
# connect_* sign-ins belong here for a second reason too: the browser comes back
# to a loopback listener, and that listener has to outlive the request that
# started it, which a per-request child process does not.
glob LOCAL_OPS: list[str] = [
    "compile_start", "compile_status", "compile_answer", "compile_jobs",
    "secret_save", "secret_delete",
    "connect_start", "connect_poll", "connect_key", "connect_remove"
];

def console_endpoint(op: str, args: dict[str, any]) -> any {
    a: dict[str, any] = dict(args or {});
    if op in LOCAL_OPS {
        # report_for makes this check for the ops it forwards; these never reach it.
        refusal = _foreign_request();
        if refusal {
            import from jaclang.server.exchange { respond }
            respond(status=403);
            return {"ok": False, "error": refusal};
        }
        try { return _local(op, a); }
        except Exception as e { return {"ok": False, "error": str(e)[:400]}; }
    }
    return report_for("console", {"op": op, "args": a});
}

def _local(op: str, a: dict[str, any]) -> any {
    if op == "compile_start" {
        return compile_start(list(a.get("files") or []), str(a.get("mode") or "decide"),
                             str(a.get("path") or ""));
    }
    if op == "compile_status" { return compile_status(str(a.get("job") or "")); }
    if op == "compile_answer" {
        return compile_answer(str(a.get("job") or ""), int(a.get("i") or 0), str(a.get("answer") or ""));
    }
    if op == "compile_jobs" { return compile_jobs(); }
    if op == "secret_save" {
        return secret_save(str(a.get("name") or ""), str(a.get("env") or ""), str(a.get("value") or ""));
    }
    if op == "secret_delete" {
        return secret_delete(str(a.get("name") or ""), str(a.get("env") or ""));
    }
    if op == "connect_start" {
        import from .sigil_connect { connect_start }
        return connect_start(str(a.get("provider") or ""), bool(a.get("fresh")));
    }
    if op == "connect_poll" {
        import from .sigil_connect { connect_poll }
        return connect_poll(str(a.get("id") or ""));
    }
    if op == "connect_key" {
        import from .sigil_connect { connect_key }
        return connect_key(str(a.get("provider") or ""), str(a.get("value") or ""));
    }
    if op == "connect_remove" {
        import from .sigil_connect { disconnect }
        return disconnect(str(a.get("provider") or ""));
    }
    return {"ok": False, "error": "unknown op '" + op + "'"};
}

def console_dispatch(op: str, a: dict[str, any]) -> any {
    # Runs inside the `api console` child, against the agent's real graph.
    if op == "overview" { return overview(); }
    if op == "skills" { return skills_view(); }
    if op == "docs" {
        import from .sigil_docs { doc_topics }
        return doc_topics();
    }
    if op == "doc" {
        import from .sigil_docs { read_doc }
        return {"ok": True, "topic": str(a.get("topic") or ""), "text": read_doc(str(a.get("topic") or ""))};
    }
    if op == "keys" { return keys_overview(); }
    if op == "secret_ref_add" {
        import from .sigil_secrets { secret_add }
        return {"ok": True, "message": secret_add(str(a.get("name") or ""), str(a.get("env") or ""))};
    }
    if op == "secret_remove" {
        import from .sigil_secrets { secret_remove }
        return {"ok": True, "message": secret_remove(str(a.get("name") or ""))};
    }
    if op == "secret_test" { return secret_check(str(a.get("env") or "")); }
    if op == "skill_detail" { return skill_detail(str(a.get("signature") or "")); }
    if op == "skill_gates" { return skill_gates(str(a.get("signature") or "")); }
    if op == "skill_expose" { return skill_expose(str(a.get("signature") or ""), bool(a.get("on"))); }
    if op == "memory_list" { return memory_list(); }
    if op == "memory_forget" { return memory_forget(str(a.get("content") or "")); }
    if op == "approvals" { return approvals_view(); }
    if op == "approve" {
        import from .approvals { approve_exact }
        return approve_exact(str(a.get("cmd") or ""), str(a.get("decision") or ""), str(a.get("pattern") or ""));
    }
    if op == "approvals_policy" {
        import from .approvals { approvals_set }
        return {"ok": True, "message": approvals_set(str(a.get("security") or "allowlist"), str(a.get("ask") or "on-miss"))};
    }
    if op == "allow_add" {
        import from .approvals { allowlist_add }
        return {"ok": True, "message": allowlist_add(str(a.get("pattern") or "").strip())};
    }
    if op == "allow_remove" {
        import from .approvals { allowlist_remove }
        return {"ok": True, "message": allowlist_remove(str(a.get("pattern") or ""))};
    }
    if op == "elevate" {
        import from .approvals { approvals_elevate }
        return {"ok": True, "message": approvals_elevate(int(a.get("minutes") or 15))};
    }
    if op == "deescalate" {
        import from .approvals { approvals_deescalate }
        return {"ok": True, "message": approvals_deescalate()};
    }
    if op == "cron_add" {
        import from .cron { cron_add, cron_list }
        # Enable, run, remove and history all find a job by name, so a second
        # job with the same name could never be told apart from the first.
        nm = str(a.get("name") or "").strip();
        if nm and (nm in [str(dict(j).get("name") or "") for j in cron_list()]) {
            return {"ok": False, "error": "a schedule named '" + nm + "' already exists"};
        }
        return cron_add(str(a.get("name") or ""), str(a.get("kind") or ""), str(a.get("spec") or ""),
                        str(a.get("task") or ""), str(a.get("tz") or ""), str(a.get("channel") or ""),
                        bool(a.get("delete_after_run")));
    }
    if op == "cron_run" {
        import from .cron { cron_run_now }
        return cron_run_now(str(a.get("name") or ""));
    }
    if op == "hook_add" {
        import from .hooks { hook_add }
        return hook_add(str(a.get("name") or ""), str(a.get("event") or ""),
                        str(a.get("kind") or "note"), str(a.get("action") or ""));
    }
    if op == "hook_enable" {
        import from .hooks { hook_enable }
        return {"ok": True, "message": hook_enable(str(a.get("name") or ""), bool(a.get("on")))};
    }
    if op == "hook_remove" {
        import from .hooks { hook_remove }
        return {"ok": True, "message": hook_remove(str(a.get("name") or ""))};
    }
    if op == "channels" { return channels_view(); }
    if op == "channel_history" {
        import from .channels { channel_history }
        return channel_history(str(a.get("name") or ""), int(a.get("n") or 30));
    }
    if op == "channel_connect" {
        import from .sigil_channels_setup { channel_bootstrap }
        kind = str(a.get("kind") or "").lower().strip();
        return channel_bootstrap(str(a.get("name") or kind), kind, str(a.get("token_env") or ""));
    }
    if op == "channel_send" {
        import from .channels { message_send }
        return message_send(str(a.get("channel") or ""), str(a.get("peer") or ""), str(a.get("text") or ""));
    }
    if op == "channel_remove" {
        import from .channels { channel_remove }
        return {"ok": True, "message": channel_remove(str(a.get("name") or ""))};
    }
    if op == "mcp_remove" {
        import from .sigil_core { remove_mcp }
        return {"ok": True, "message": remove_mcp(str(a.get("name") or ""))};
    }
    if op == "tools" { return tools_view(); }
    if op == "models" { return models_view(); }
    if op == "connections" { return connections_view(); }
    if op == "connect_apply" {
        import from .sigil_connect { apply_tiers }
        t: dict[str, str] = {};
        for (k, v) in dict(a.get("tiers") or {}).items() { t[str(k)] = str(v); }
        return {"ok": True, "said": apply_tiers(t)};
    }
    if op == "system" { return system_view(); }
    if op == "usage" { return usage(int(a.get("n") or 3000)); }
    if op == "chat_turn" {
        import from .chat_agent { web_chat_turn }
        import from .approvals { approvals_pending }
        t0 = time.time();
        out = web_chat_turn(str(a.get("message") or ""), list(a.get("history") or []));
        # The approvals this turn queued, so the reply can carry their cards.
        out["pending"] = [p for p in approvals_pending() if float(p["ts"]) >= t0 - 1.0];
        return out;
    }
    if op == "compile_run" { return compile_run(str(a.get("job") or "")); }
    return {"ok": False, "error": "unknown op '" + op + "'"};
}

# ---------------------------------------------------------------------------
# Home: one request for everything the first screen shows. Each console request
# is a process start, so the overview is one, not seven.
# ---------------------------------------------------------------------------
def _skills() -> list[any] {
    import from .sigil_core { Registry, TaskGraph, latest_by_sig }
    regs = [root -->[?:Registry]];
    if not regs { return []; }
    out: list[any] = [];
    for tg in latest_by_sig([regs[0] -->[?:TaskGraph]]) {
        out.append({
            "signature": tg.signature, "version": tg.version, "origin": tg.origin,
            "runs": tg.runs, "successes": tg.successes, "intent": tg.intent,
            "last_score": tg.last_score, "last_eval": tg.last_eval,
            "from_skill": bool(str(tg.skill_src).strip())
        });
    }
    return out;
}

def skills_view() -> list[any] {
    # The library with what its page shows beside each skill: whether MCP
    # clients and the chat agent can call it.
    import from .sigil_core { tool_allowed }
    import from .sigil_skill_tools { tool_name }
    out: list[any] = [];
    for s in _skills() {
        t = tool_name(str(s["signature"]));
        row = dict(s);
        row["tool"] = t;
        row["exposed"] = tool_allowed(t);
        out.append(row);
    }
    return out;
}

def _midnight() -> float {
    lt = time.localtime();
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1));
}

def _connected() -> dict[str, any] {
    # Behind the shell's "no model connected" banner: the frontier and chat
    # tiers are what compiling and chat need.
    try {
        import from .sigil_connect { ready_tiers }
        rt = ready_tiers();
        why = str(rt["tiers"]["frontier"]["why"] or rt["tiers"]["chat"]["why"]);
        return {"ok": bool(rt["ok"]), "why": why};
    } except Exception as e { return {"ok": True, "why": ""}; }
}

def overview() -> dict[str, any] {
    import from .sigil_core { describe_soul }
    import from .approvals { approvals_pending }
    import from .cron { cron_list }
    import from .sigil_tasks { tasks_list }
    import from .channels { channel_list }
    import from .sigil_daemon { scheduler_running }
    soul = describe_soul();
    today = usage_since(_midnight());
    return {
        "soul": {
            "name": soul["name"], "frontier_model": soul["frontier_model"],
            "small_model": soul["small_model"], "router_model": soul["router_model"],
            "chat_model": soul["chat_model"], "memories": len(list(soul["memories"])),
            "eval_threshold": soul["eval_threshold"], "auto_eval": soul["auto_eval"]
        },
        "skills": _skills(),
        "pending": approvals_pending(),
        "cron": cron_list(),
        "tasks": tasks_list(12),
        "channels": channel_list(),
        # "will a schedule fire?": the daemon or `sigil cron daemon`, either one
        "daemon": scheduler_running(),
        "today": today,
        "connected": _connected()
    };
}

# ---------------------------------------------------------------------------
# Keys & secrets. The value of a key is never returned: only whether it is set,
# where it came from (shell or the console's file), and its last four characters
# when it is long enough that four reveal nothing.
# ---------------------------------------------------------------------------
# [label, env var, model-name prefixes that need it]
glob MODEL_KEYS: list[any] = [
    ["OpenAI", "OPENAI_API_KEY", ["gpt", "o1", "o3", "o4", "openai/", "chatgpt"]],
    ["Anthropic", "ANTHROPIC_API_KEY", ["claude-", "anthropic/"]],
    ["Google Gemini", "GOOGLE_API_KEY", ["gemini", "google/"]],
    ["Z.ai", "ZAI_API_KEY", ["zai/", "glm"]],
    ["OpenRouter", "OPENROUTER_API_KEY", ["openrouter/"]],
    ["Ollama Cloud", "OLLAMA_API_KEY", ["ollama-cloud/"]]
];

# [label, env var, what it is for] in the order `web_search` tries them.
glob SEARCH_KEYS: list[any] = [
    ["Brave Search", "BRAVE_API_KEY", "Search results from Brave's API (free tier available)"],
    ["Firecrawl", "FIRECRAWL_API_KEY", "Search plus full-page scraping"]
];

# A provider that answers to a second name: litellm reads GEMINI_API_KEY when
# GOOGLE_API_KEY is unset, and web_search reads BRAVE_SEARCH_API_KEY likewise.
glob KEY_ALIASES: dict[str, str] = {"GOOGLE_API_KEY": "GEMINI_API_KEY", "BRAVE_API_KEY": "BRAVE_SEARCH_API_KEY"};

def _key_row(label: str, env: str) -> dict[str, any] {
    # The row shows the alias only when it is the one that is actually set.
    alt = KEY_ALIASES.get(env, "");
    if alt and (not os.environ.get(env)) and os.environ.get(alt) { env = alt; }
    return {"label": label, "env": env, "set": bool(os.environ.get(env)),
            "source": secret_source(env), "tail": secret_tail(env)};
}

def _tier_models() -> dict[str, str] {
    import from .sigil_core { describe_soul }
    s = describe_soul();
    return {"frontier": str(s["frontier_model"]), "small": str(s["small_model"]),
            "router": str(s["router_model"]), "chat": str(s["chat_model"])};
}

def _needs(model: str, prefixes: list[any]) -> bool {
    m = str(model or "").lower();
    if m.startswith("ollama-cloud/") { return "ollama-cloud/" in [str(p) for p in prefixes]; }
    if m.startswith("claude-cc/") or m.startswith("ollama") { return False; }
    for p in prefixes { if m.startswith(str(p)) { return True; } }
    return False;
}

def keys_overview() -> dict[str, any] {
    import from .sigil_secrets { secret_list }
    import from .sigil_channels_setup { CHANNEL_GUIDES }
    import from .channels { channel_list }
    import from .sigil_workspace { _claude_search_ready }
    tiers = _tier_models();
    models: list[any] = [];
    for mk in MODEL_KEYS {
        row = _key_row(str(mk[0]), str(mk[1]));
        row["used_by"] = [t for t in ["frontier", "small", "router", "chat"] if _needs(tiers[t], list(mk[2]))];
        models.append(row);
    }
    local_tiers = [t for t in ["frontier", "small", "router", "chat"]
                   if str(tiers[t]).lower().startswith("ollama") and not str(tiers[t]).lower().startswith("ollama-cloud/")];
    cc_tiers = [t for t in ["frontier", "small", "router", "chat"] if str(tiers[t]).lower().startswith("claude-cc/")];

    search: list[any] = [];
    active = "";
    for sk in SEARCH_KEYS {
        row = _key_row(str(sk[0]), str(sk[1]));
        row["about"] = str(sk[2]);
        if row["set"] and (not active) { active = str(sk[0]); }
        search.append(row);
    }
    claude_ready = False;
    try { claude_ready = bool(_claude_search_ready()); } except Exception as e { claude_ready = False; }
    if claude_ready and (not active) { active = "Claude Code"; }

    configured = channel_list();
    chans: list[any] = [];
    seen: list[str] = [str(m[1]) for m in MODEL_KEYS] + [str(s[1]) for s in SEARCH_KEYS] + list(KEY_ALIASES.values());
    for kind in sorted(list(CHANNEL_GUIDES.keys())) {
        g = dict(CHANNEL_GUIDES[kind]);
        env = str(g.get("token_env") or "");
        if not env { continue; }
        row = _key_row(str(kind).capitalize(), env);
        row["kind"] = kind;
        row["used_by"] = [str(c["name"]) for c in configured if str(c["kind"]) == kind];
        chans.append(row);
        seen.append(env);
    }
    other: list[any] = [];
    for ref in secret_list() {
        env = str(ref["env"]);
        if env in seen { continue; }
        row = _key_row(str(ref["name"]), env);
        row["name"] = str(ref["name"]);
        other.append(row);
    }
    return {"models": models, "local_tiers": local_tiers, "claude_code_tiers": cc_tiers,
            "search": search, "search_active": active, "claude_search": claude_ready,
            "channels": chans, "other": other, "file": secrets_env_path()};
}

def secret_save(name: str, env: str, value: str) -> dict[str, any] {
    # Server side, by design: the value goes into the console's file here and is
    # never put on a child process's command line. A `name` also registers a
    # SecretRef, which is how a channel or MCP config refers to the key.
    e = env.strip();
    if not env_name_ok(e) { return {"ok": False, "error": "'" + e + "' is not a valid variable name"}; }
    stored = False;
    if value.strip() {
        r = secret_value_set(e, value);
        if not r["ok"] { return r; }
        stored = True;
    }
    if name.strip() {
        ref = report_for("console", {"op": "secret_ref_add", "args": {"name": name.strip(), "env": e}});
        if isinstance(ref, dict) and (ref.get("ok") == False) { return ref; }
    }
    return {"ok": True, "env": e, "stored": stored, "set": bool(os.environ.get(e)),
            "source": secret_source(e), "tail": secret_tail(e)};
}

def secret_delete(name: str, env: str) -> dict[str, any] {
    removed = False;
    if env.strip() {
        r = secret_value_clear(env.strip());
        removed = bool(r.get("removed"));
    }
    if name.strip() {
        report_for("console", {"op": "secret_remove", "args": {"name": name.strip()}});
    }
    return {"ok": True, "env": env, "removed": removed, "set": bool(os.environ.get(env.strip()))};
}

def _http_ok(method: str, url: str, headers: dict[str, any], body: any = None) -> dict[str, any] {
    import httpx;
    try {
        if method == "POST" {
            r = httpx.post(url, headers=headers, json=body, timeout=10.0);
        } else {
            r = httpx.get(url, headers=headers, timeout=10.0);
        }
        return {"ok": (r.status_code >= 200) and (r.status_code < 300), "code": r.status_code, "json": _safe_json(r)};
    } except Exception as e {
        return {"ok": False, "code": 0, "json": None, "error": str(e)[:160]};
    }
}

def _safe_json(r: any) -> any {
    try { return r.json(); } except Exception as e { return None; }
}

def secret_check(env: str) -> dict[str, any] {
    # Prove a key works without showing it: one cheap authenticated call to the
    # provider it belongs to. Anything Sigil does not know how to test reports
    # whether it is set, and nothing more.
    val = str(os.environ.get(env) or "");
    if not val { return {"ok": False, "env": env, "detail": "not set"}; }
    if env in ["BRAVE_API_KEY", "BRAVE_SEARCH_API_KEY"] {
        import from .sigil_workspace { _search_brave }
        try {
            items = _search_brave("sigil skill compiler", val);
            return {"ok": True, "env": env, "detail": "works: " + str(len(items)) + " results"};
        } except Exception as e { return {"ok": False, "env": env, "detail": "Brave refused it: " + str(e)[:120]}; }
    }
    if env == "FIRECRAWL_API_KEY" {
        import from .sigil_workspace { _search_firecrawl }
        try {
            items = _search_firecrawl("sigil skill compiler", val);
            return {"ok": True, "env": env, "detail": "works: " + str(len(items)) + " results"};
        } except Exception as e { return {"ok": False, "env": env, "detail": "Firecrawl refused it: " + str(e)[:120]}; }
    }
    r: dict[str, any] = {};
    if env == "OPENAI_API_KEY" {
        r = _http_ok("GET", "https://api.openai.com/v1/models", {"Authorization": "Bearer " + val});
    } elif env == "ANTHROPIC_API_KEY" {
        r = _http_ok("GET", "https://api.anthropic.com/v1/models", {"x-api-key": val, "anthropic-version": "2023-06-01"});
    } elif env in ["GOOGLE_API_KEY", "GEMINI_API_KEY"] {
        r = _http_ok("GET", "https://generativelanguage.googleapis.com/v1beta/models?key=" + val, {});
    } elif env == "OPENROUTER_API_KEY" {
        r = _http_ok("GET", "https://openrouter.ai/api/v1/auth/key", {"Authorization": "Bearer " + val});
    } elif env == "TELEGRAM_BOT_TOKEN" {
        r = _http_ok("GET", "https://api.telegram.org/bot" + val + "/getMe", {});
        if r["ok"] and isinstance(r["json"], dict) {
            u = dict(r["json"].get("result") or {});
            return {"ok": True, "env": env, "detail": "works: @" + str(u.get("username") or "bot")};
        }
    } elif env == "SLACK_BOT_TOKEN" {
        r = _http_ok("POST", "https://slack.com/api/auth.test", {"Authorization": "Bearer " + val}, {});
        j = r.get("json");
        if isinstance(j, dict) and (not j.get("ok")) {
            return {"ok": False, "env": env, "detail": "Slack refused it: " + str(j.get("error") or "unknown")};
        }
    } else {
        return {"ok": True, "env": env, "detail": "set (" + str(len(val)) + " characters); Sigil has no test for this key"};
    }
    if r.get("ok") { return {"ok": True, "env": env, "detail": "works"}; }
    code = int(r.get("code") or 0);
    why = ("rejected (HTTP " + str(code) + ")") if code else ("could not reach the provider: " + str(r.get("error") or ""));
    return {"ok": False, "env": env, "detail": why};
}

# ---------------------------------------------------------------------------
# One skill, every version of it, and the gates run against its stored AG-IR.
# ---------------------------------------------------------------------------
def _by_version(tg: any) -> int { return int(tg.version); }
def _by_at(r: dict[str, any]) -> int { return int(r["at_ms"]); }

def _versions(signature: str) -> list[any] {
    import from .sigil_core { Registry, TaskGraph }
    regs = [root -->[?:Registry]];
    if not regs { return []; }
    return sorted([tg for tg in [regs[0] -->[?:TaskGraph]] if tg.signature == signature], key=_by_version);
}

def skill_detail(signature: str) -> dict[str, any] {
    import from .sigil_core { Attempt, tool_allowed }
    import from .sigil_skill_tools { tool_name }
    vers = _versions(signature);
    if not vers { return {"ok": False, "error": "no such skill: " + signature}; }
    latest = vers[-1];
    src = str(latest.skill_src);
    if not src.strip() {
        for tg in reversed(vers) { if str(tg.skill_src).strip() { src = str(tg.skill_src); break; } }
    }
    attempts: list[any] = [];
    for tg in vers {
        for at in [tg -->[?:Attempt]] {
            attempts.append({"version": tg.version, "task": str(at.task)[:300], "ok": at.ok,
                             "model": at.model, "summary": str(at.summary)[:400], "at_ms": at.at_ms});
        }
    }
    attempts = sorted(attempts, key=_by_at, reverse=True)[:40];
    tool = tool_name(signature);
    return {
        "ok": True, "signature": signature, "version": latest.version, "origin": latest.origin,
        "intent": latest.intent, "module": latest.module, "runs": latest.runs,
        "successes": latest.successes, "last_score": latest.last_score, "last_eval": latest.last_eval,
        "skill_src": src, "agir": str(latest.agir), "tool": tool, "exposed": tool_allowed(tool),
        "versions": [{"version": tg.version, "origin": tg.origin, "runs": tg.runs,
                      "successes": tg.successes, "last_score": tg.last_score} for tg in reversed(vers)],
        "attempts": attempts
    };
}

def _gate_row(gid: str, name: str, severity: str, issues: list[any], enabled: bool = True) -> dict[str, any] {
    return {"id": gid, "name": name, "severity": severity, "enabled": enabled,
            "ok": enabled and (len(issues) == 0), "issues": [str(i)[:400] for i in issues][:12]};
}

def skill_gates(signature: str) -> dict[str, any] {
    # The mechanical gates, re-run on demand against the AG-IR this version was
    # stored with: the same functions `sigil gate` and the compile's gate battery
    # call. The gates that need the extracted spec (faithfulness, G2, G3_HIL) only run
    # inside a compile, so they are not here.
    import from .compiler.ai.gates {
        compile_gate, gate_type_unification, det_overloaded, gate_env_binding, gate_constraints,
        gate_concurrency, gate_slot_prompt_bloat
    }
    import from .compiler.ai.report { gate_enabled }
    vers = _versions(signature);
    if not vers { return {"ok": False, "error": "no such skill: " + signature}; }
    ir = str(vers[-1].agir);
    if not ir.strip() { return {"ok": False, "error": signature + " has no stored AG-IR"}; }
    rows: list[any] = [];
    module_src = "";
    try {
        gv = compile_gate(ir, signature);
        module_src = str(gv.module_src or "");
        rows.append(_gate_row("COMPILE", "Lowers and type-checks", "fatal", ([] if gv.ok else [str(gv.errors)[-600:]])));
    } except Exception as e { rows.append(_gate_row("COMPILE", "Lowers and type-checks", "fatal", ["gate crashed: " + str(e)[:200]])); }
    try {
        rows.append(_gate_row("G6_ENV", "Packages and commands it needs exist here", "warn",
                              list(gate_env_binding(ir)), gate_enabled("G6_ENV")));
    } except Exception as e { rows.append(_gate_row("G6_ENV", "Packages and commands it needs exist here", "warn", ["gate crashed: " + str(e)[:200]])); }
    try {
        conc = dict(gate_concurrency(ir));
        rows.append(_gate_row("G6_PAR", "No false parallelism", "error", list(conc.get("issues") or []), gate_enabled("G6_PAR")));
    } except Exception as e { rows.append(_gate_row("G6_PAR", "No false parallelism", "error", ["gate crashed: " + str(e)[:200]])); }
    try {
        rows.append(_gate_row("G4", "Data types line up and every node is reachable", "error",
                              list(gate_type_unification(ir)), gate_enabled("G4")));
    } except Exception as e { rows.append(_gate_row("G4", "Data types line up and every node is reachable", "error", ["gate crashed: " + str(e)[:200]])); }
    try {
        gcs = gate_constraints(ir);
        rows.append(_gate_row("G2_FLOW", "No prohibited data flow is reachable", "error",
                              [str(g[1]) for g in gcs if str(g[0]) == "G2_FLOW"], gate_enabled("G2_FLOW")));
        rows.append(_gate_row("G2_ORDER", "Required orderings hold on every path", "error",
                              [str(g[1]) for g in gcs if str(g[0]) == "G2_ORDER"], gate_enabled("G2_ORDER")));
    } except Exception as e { rows.append(_gate_row("G2_FLOW", "No prohibited data flow is reachable", "error", ["gate crashed: " + str(e)[:200]])); }
    try {
        import from .compiler.ai.author_direct { _views_from_ir }
        (wf, vb) = _views_from_ir(ir);
        rows.append(_gate_row("G2_OVERLOAD", "No model slot carries more than six mandates", "error",
                              list(det_overloaded(wf)), gate_enabled("G2_OVERLOAD")));
    } except Exception as e { rows.append(_gate_row("G2_OVERLOAD", "No model slot carries more than six mandates", "error", ["gate crashed: " + str(e)[:200]])); }
    if module_src {
        try {
            rows.append(_gate_row("G5_BLOAT", "Slot prompts carry a mandate, not a document", "warn",
                                  list(gate_slot_prompt_bloat(module_src)), gate_enabled("G5_BLOAT")));
        } except Exception as e { rows.append(_gate_row("G5_BLOAT", "Slot prompts carry a mandate, not a document", "warn", ["gate crashed: " + str(e)[:200]])); }
    }
    return {"ok": True, "signature": signature, "version": vers[-1].version, "gates": rows,
            "lines": len(module_src.splitlines())};
}

def skill_expose(signature: str, on: bool) -> dict[str, any] {
    # Whether MCP clients and the chat agent see this skill as a tool: the tool
    # policy's deny list, edited for one name.
    import from .sigil_core { awaken, tool_allowed }
    import from .sigil_skill_tools { tool_name }
    soul = awaken();
    t = tool_name(signature) if signature else "";
    if not t { return {"ok": False, "error": "no skill named"}; }
    deny = [str(x) for x in soul.tool_deny if str(x) != t];
    if not on { deny.append(t); }
    soul.tool_deny = deny;
    allow = [str(x) for x in soul.tool_allow];
    if on and allow and (t not in allow) and ("*" not in allow) { soul.tool_allow = allow + [t]; }
    return {"ok": True, "tool": t, "exposed": tool_allowed(t)};
}

# ---------------------------------------------------------------------------
# Memory, with what describe_soul leaves out (salience) and a way to forget.
# ---------------------------------------------------------------------------
def _by_salience(m: dict[str, any]) -> float { return float(m["salience"]); }

def memory_list() -> list[any] {
    import from .sigil_core { awaken, Memory }
    soul = awaken();
    rows = [{"content": m.content, "kind": m.kind, "salience": m.salience, "uses": m.uses}
            for m in [soul -->[?:Memory]]];
    return sorted(rows, key=_by_salience, reverse=True);
}

def memory_forget(content: str) -> dict[str, any] {
    import from .sigil_core { awaken, Memory }
    soul = awaken();
    for m in [soul -->[?:Memory]] {
        if m.content == content { del m; return {"ok": True, "removed": 1}; }
    }
    return {"ok": False, "error": "no such memory"};
}

# ---------------------------------------------------------------------------
# Approvals, channels, tools, models, the system.
# ---------------------------------------------------------------------------
def approvals_view() -> dict[str, any] {
    import from .approvals { approvals_get, approvals_pending, approvals_history, elevated_audit }
    return {"policy": approvals_get(), "pending": approvals_pending(),
            "history": approvals_history(40), "elevated": elevated_audit()[-20:]};
}

def channels_view() -> dict[str, any] {
    import from .channels { channel_list }
    import from .sigil_channels_setup { CHANNEL_GUIDES }
    guides: list[any] = [];
    for kind in sorted(list(CHANNEL_GUIDES.keys())) {
        g = dict(CHANNEL_GUIDES[kind]);
        env = str(g.get("token_env") or "");
        guides.append({"kind": kind, "token_env": env, "token_set": bool(os.environ.get(env)) if env else False,
                       "delivery": str(g.get("delivery") or ""),
                       "get_token": [str(s) for s in list(g.get("get_token") or [])],
                       "wire": [str(s) for s in list(g.get("wire") or [])]});
    }
    return {"configured": channel_list(), "guides": guides, "endpoint": "/walker/api_inbound"};
}

# The chat agent's built-in tools, grouped as src/chat_agent.jac lists them. The
# tool policy does not gate these (it gates skills and what MCP clients see), so
# the console shows them as what the agent can reach for, not as switches.
glob TOOL_GROUPS: list[any] = [
    ["Files", ["ws_read", "ws_write", "ws_edit", "ws_list", "ws_tree", "ws_grep"]],
    ["Shell", ["ws_exec", "ws_watch", "ws_kill", "ws_jobs"]],
    ["Web", ["web_fetch", "web_search"]],
    ["Schedules", ["schedule_task", "list_scheduled", "cancel_scheduled", "run_scheduled_now"]],
    ["Memory", ["remember_fact", "recall_memory"]],
    ["Skills", ["sigil_compile", "learn_skill", "list_skills", "use_skill"]],
    ["Channels and MCP", ["mcp_call", "send_message", "connect_channel", "setup_channel"]],
    ["Self-config", ["cfg_set_model", "cfg_set_persona", "cfg_set_prompt_mode"]],
    ["Docs and sub-agents", ["doc_index", "read_docs", "spawn_subagent", "spawn_parallel"]]
];

def tools_view() -> dict[str, any] {
    import from .sigil_core { tools_policy_info, tool_allowed, mcp_status }
    import from .sigil_skill_tools { tool_name }
    served: list[any] = [];
    for t in ["sigil_solve", "sigil_library"] {
        served.append({"tool": t, "signature": "", "exposed": tool_allowed(t)});
    }
    for s in _skills() {
        t = tool_name(str(s["signature"]));
        served.append({"tool": t, "signature": s["signature"], "version": s["version"], "exposed": tool_allowed(t)});
    }
    return {"groups": [{"name": g[0], "tools": g[1]} for g in TOOL_GROUPS],
            "policy": tools_policy_info(), "served": served, "servers": mcp_status(),
            "command": "claude mcp add sigil -- sigil mcp-serve"};
}

def _ollama_models() -> list[str] {
    # Models already pulled into a local Ollama, so the picker can offer them.
    import httpx;
    try {
        r = httpx.get("http://127.0.0.1:11434/api/tags", timeout=1.5);
        if r.status_code != 200 { return []; }
        return ["ollama_chat/" + str(m.get("name")) for m in list(dict(r.json()).get("models") or [])][:30];
    } except Exception as e { return []; }
}

def _connected_models() -> list[str] {
    # What the connected sign-ins and keys offer, for the tier pickers. Ollama's
    # come from _ollama_models already.
    try {
        import from .sigil_connect { connections }
        out: list[str] = [];
        for r in connections() {
            if r["connected"] and (str(r["id"]) != "ollama") { out = out + [str(m) for m in list(r["models"])]; }
        }
        return out[:30];
    } except Exception as e { return []; }
}

def _configured_tiers() -> dict[str, str] {
    # What each tier is set to on the graph. In claude mode `tiers` reports what
    # they run as instead (claude-cc/...), which is not what a save changes.
    import from .sigil_core { awaken }
    soul = awaken();
    return {"frontier": str(soul.frontier_model), "small": str(soul.small_model),
            "router": str(soul.router_model or soul.small_model), "chat": str(soul.chat_model or soul.frontier_model)};
}

def connections_view() -> dict[str, any] {
    # Every route, whether it is live, whether each tier has one, and what the
    # tiers could be from what is connected.
    import from .sigil_connect { ready_tiers, suggest_tiers, tiers_for, how_to, CHATGPT_USAGE_URL }
    rt = ready_tiers();
    rows: list[any] = [];
    per: dict[str, any] = {};
    for r in list(rt["rows"]) {
        row = dict(r);
        row["how"] = how_to(str(r["id"]));
        rows.append(row);
        if r["connected"] { per[str(r["id"])] = tiers_for(str(r["id"]), list(rt["rows"])); }
    }
    return {"rows": rows, "tiers": rt["tiers"], "ok": rt["ok"], "suggest": suggest_tiers(list(rt["rows"])),
            "suggest_for": per, "usage_url": CHATGPT_USAGE_URL};
}

def models_view() -> dict[str, any] {
    import from .sigil_core { models_info }
    tiers = _tier_models();
    mi = models_info();
    return {"tiers": tiers, "configured": _configured_tiers(),
            "aliases": dict(mi.get("aliases") or {}), "fallbacks": dict(mi.get("fallbacks") or {}),
            "claude_mode": str(os.environ.get("SIGIL_CLAUDE") or "") == "1",
            "local": _ollama_models() + _connected_models()};
}

def _project_version() -> dict[str, str] {
    import tomllib;
    try {
        with open(os.path.join(project_root(), "jac.toml"), "rb") as f { cfg = tomllib.load(f); }
        p = dict(cfg.get("project") or {});
        return {"version": str(p.get("version") or ""), "jac": str(p.get("jac-version") or "").lstrip("=")};
    } except Exception as e { return {"version": "", "jac": ""}; }
}

def system_view() -> dict[str, any] {
    import from .sigil_daemon { daemon_status }
    import from .sigil_serve { serve_status }
    import from .sigil_workspace { workspace_info }
    import from .sigil_core { describe_soul }
    s = describe_soul();
    v = _project_version();
    return {"daemon": daemon_status(), "serve": serve_status(), "workspace": workspace_info(),
            "version": v["version"], "jac": v["jac"], "home": sigil_home(), "project": project_root(),
            "secrets_file": secrets_env_path(),
            "soul": {"name": s["name"], "persona": s["persona"], "ethos": s["ethos"],
                     "prompt_mode": s["prompt_mode"], "auto_eval": s["auto_eval"],
                     "eval_threshold": s["eval_threshold"], "sandbox": s["sandbox"],
                     "workspace": s["workspace"], "verbose": s["verbose"]}};
}

# ---------------------------------------------------------------------------
# Usage: the token log every model call appends to, read whole (the Observatory's
# view dropped the timestamps, durations and errors this needs).
# ---------------------------------------------------------------------------
def _num(v: any) -> float {
    try { return float(v or 0); } except Exception as e { return 0.0; }
}

def _day(ts: float) -> str {
    return time.strftime("%Y-%m-%d", time.localtime(ts));
}

def _records(n: int) -> list[any] {
    import from .sigil_observe { read_tail }
    import from .sigil_core { WORKDIR }
    return list(read_tail(os.path.join(WORKDIR, "observability", "live.jsonl"), n));
}

def usage_since(t0: float) -> dict[str, any] {
    cost = 0.0; calls = 0; tokens = 0;
    for raw in _records(3000) {
        r = dict(raw);
        if _num(r.get("ts")) < t0 { continue; }
        calls += 1;
        cost += _num(r.get("cost_usd"));
        tokens += int(_num(r.get("prompt_tokens")) + _num(r.get("completion_tokens")));
    }
    return {"cost": cost, "calls": calls, "tokens": tokens};
}

def _bump(d: dict[str, any], k: str, cost: float, toks: int) -> dict[str, any] {
    cur = dict(d.get(k) or {"key": k, "cost": 0.0, "calls": 0, "tokens": 0});
    cur["cost"] = float(cur["cost"]) + cost;
    cur["calls"] = int(cur["calls"]) + 1;
    cur["tokens"] = int(cur["tokens"]) + toks;
    d[k] = cur;
    return d;
}

def _by_cost(r: dict[str, any]) -> float { return float(r["cost"]); }
def _by_key(r: dict[str, any]) -> str { return str(r["key"]); }

def usage(n: int = 3000) -> dict[str, any] {
    recs = [dict(x) for x in _records(n)];
    days: dict[str, any] = {};
    models: dict[str, any] = {};
    sigs: dict[str, any] = {};
    lat: list[float] = [];
    tot = {"cost": 0.0, "calls": 0, "tin": 0, "tout": 0, "reasoning": 0, "cached": 0, "errors": 0};
    calls: list[any] = [];
    for r in recs {
        ts = _num(r.get("ts"));
        cost = _num(r.get("cost_usd"));
        pin = int(_num(r.get("prompt_tokens")));
        pout = int(_num(r.get("completion_tokens")));
        toks = pin + pout;
        days = _bump(days, _day(ts) if ts else "unknown", cost, toks);
        models = _bump(models, str(r.get("model") or "?"), cost, toks);
        sigs = _bump(sigs, str(r.get("signature") or "(no signature)"), cost, toks);
        tot["cost"] = float(tot["cost"]) + cost;
        tot["calls"] = int(tot["calls"]) + 1;
        tot["tin"] = int(tot["tin"]) + pin;
        tot["tout"] = int(tot["tout"]) + pout;
        tot["reasoning"] = int(tot["reasoning"]) + int(_num(r.get("reasoning_tokens")));
        tot["cached"] = int(tot["cached"]) + int(_num(r.get("cache_read_tokens")));
        if r.get("error") { tot["errors"] = int(tot["errors"]) + 1; }
        d = _num(r.get("duration_ms"));
        if d > 0 { lat.append(d); }
        calls.append({
            "ts": ts, "model": str(r.get("model") or "?"), "signature": str(r.get("signature") or ""),
            "prompt_tokens": pin, "completion_tokens": pout,
            "reasoning_tokens": int(_num(r.get("reasoning_tokens"))),
            "cache_read_tokens": int(_num(r.get("cache_read_tokens"))),
            "cost_usd": cost, "duration_ms": d, "error": str(r.get("error") or ""),
            "content": str(r.get("content") or "")[:800],
            "reasoning": str(r.get("reasoning_content") or "")[:800],
            "tools": ", ".join([str(t) for t in list(r.get("tool_calls") or [])])[:400]
        });
    }
    lat = sorted(lat);
    p50 = lat[int(len(lat) / 2)] if lat else 0.0;
    p95 = lat[min(len(lat) - 1, int(len(lat) * 0.95))] if lat else 0.0;
    tot["p50_ms"] = p50;
    tot["p95_ms"] = p95;
    return {
        "totals": tot,
        "days": sorted(list(days.values()), key=_by_key)[-14:],
        "models": sorted(list(models.values()), key=_by_cost, reverse=True)[:10],
        "signatures": sorted(list(sigs.values()), key=_by_cost, reverse=True)[:12],
        "calls": list(reversed(calls))[:200]
    };
}

# ---------------------------------------------------------------------------
# Compile jobs.
# ---------------------------------------------------------------------------
glob MODES: list[str] = ["ask", "decide", "optional"];
glob MAX_FILES: int = 300;
glob MAX_BYTES: int = 4000000;
glob ASK_TIMEOUT_S: int = 1800;

def _jobs_root() -> str {
    d = os.path.join(sigil_home(), "compile");
    os.makedirs(d, exist_ok=True);
    return d;
}

def _job_ok(job: str) -> bool {
    # A job id is ours: digits, letters and dashes. Anything else could walk out
    # of the jobs folder.
    if (not job) or (len(job) > 64) { return False; }
    for ch in job { if not (ch.isalnum() or (ch == "-")) { return False; } }
    return True;
}

def _job_dir(job: str) -> str { return os.path.join(_jobs_root(), job); }

def _read_json(path: str) -> any {
    try {
        with open(path) as f { return json.loads(f.read() or "null"); }
    } except Exception as e { return None; }
}

def _write_json(path: str, data: any) {
    tmp = path + ".tmp";
    with open(tmp, "w") as f { f.write(json.dumps(data, `default=str)); }
    os.replace(tmp, path);
}

def _clean_rel(p: str) -> str {
    # A relative path inside the skill folder, or "" when it would leave it.
    s = str(p or "").replace("\\", "/").strip().lstrip("/");
    parts = [x for x in s.split("/") if x and (x != ".")];
    if (not parts) or (".." in parts) { return ""; }
    return "/".join(parts);
}

def _skill_name(text: str, fallback: str) -> str {
    # The frontmatter `name:` when the skill has one, else the folder's name.
    lines = str(text or "").splitlines();
    if lines and (lines[0].strip() == "---") {
        for ln in lines[1:40] {
            if ln.strip() == "---" { break; }
            if ln.strip().lower().startswith("name:") {
                v = ln.split(":", 1)[1].strip().strip("\"'");
                if v { return v; }
            }
        }
    }
    return fallback;
}

def _copy_tree(src_dir: str, dest: str) -> int {
    # Text files only, within the size budget: a skill folder, not someone's home.
    n = 0; total = 0;
    for (base, dirs, names) in os.walk(src_dir) {
        dirs[:] = [d for d in dirs if not d.startswith(".") and (d not in ["node_modules", "__pycache__"])];
        for nm in names {
            if nm.startswith(".") { continue; }
            full = os.path.join(base, nm);
            rel = _clean_rel(os.path.relpath(full, src_dir));
            if not rel { continue; }
            try { size = os.path.getsize(full); } except Exception as e { continue; }
            if (n >= MAX_FILES) or ((total + size) > MAX_BYTES) { return n; }
            try {
                with open(full, "rb") as fh { raw = fh.read(); }
                raw.decode("utf-8");
            } except Exception as e2 { continue; }
            out = os.path.join(dest, rel);
            os.makedirs(os.path.dirname(out), exist_ok=True);
            with open(out, "wb") as fo { fo.write(raw); }
            n += 1; total += size;
        }
    }
    return n;
}

def compile_start(files: list[any], mode: str, path: str = "") -> dict[str, any] {
    m = mode if mode in MODES else "decide";
    job = str(int(time.time() * 1000)) + "-" + uuid.uuid4().hex[:6];
    d = _job_dir(job);
    skill = os.path.join(d, "skill");
    os.makedirs(skill, exist_ok=True);
    count = 0;
    if path.strip() {
        p = os.path.abspath(os.path.expanduser(path.strip()));
        if os.path.isfile(p) { p = os.path.dirname(p); }
        if not os.path.isdir(p) {
            shutil.rmtree(d, ignore_errors=True);
            return {"ok": False, "error": "no folder at " + path};
        }
        count = _copy_tree(p, skill);
    } else {
        rels: list[str] = [_clean_rel(str(dict(f).get("path") or "")) for f in files];
        # A folder picked in the browser arrives as "<folder>/SKILL.md": drop the
        # shared top folder so the skill's own layout is what lands on disk.
        tops = list(set([r.split("/")[0] for r in rels if "/" in r]));
        strip_top = (len(tops) == 1) and all([("/" in r) for r in rels if r]);
        total = 0;
        for (i, f) in enumerate(files) {
            rel = rels[i];
            if strip_top and rel { rel = rel.split("/", 1)[1]; }
            if not rel { continue; }
            text = str(dict(f).get("text") or "");
            total += len(text);
            if (count >= MAX_FILES) or (total > MAX_BYTES) { break; }
            out = os.path.join(skill, rel);
            os.makedirs(os.path.dirname(out), exist_ok=True);
            with open(out, "w") as fo { fo.write(text); }
            count += 1;
        }
    }
    entries: list[str] = [];
    for (base, dirs, names) in os.walk(skill) {
        for nm in names {
            if nm.lower() == "skill.md" { entries.append(os.path.relpath(os.path.join(base, nm), skill)); }
        }
    }
    if not entries {
        shutil.rmtree(d, ignore_errors=True);
        return {"ok": False, "error": "no SKILL.md in what was uploaded"};
    }
    skill_md = sorted(entries, key=len)[0];
    with open(os.path.join(skill, skill_md)) as fe { first = fe.read(); }
    folder = os.path.basename(os.path.dirname(os.path.join(skill, skill_md))) or "skill";
    if folder == "skill" and path.strip() { folder = os.path.basename(os.path.abspath(os.path.expanduser(path.strip()))); }
    name = _skill_name(first, folder);
    meta = {"job": job, "name": name, "mode": m, "entry": skill_md, "files": count,
            "created_ms": int(time.time() * 1000)};
    _write_json(os.path.join(d, "job.json"), meta);
    argv = [_jac_bin(), "run", "--no-serve", entry_script(), "--", "api", "console",
            json.dumps({"op": "compile_run", "args": {"job": job}})];
    log = open(os.path.join(d, "log.txt"), "w");
    try {
        proc = subprocess.Popen(argv, cwd=project_root(), env=child_env(), stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True);
    } except Exception as e {
        log.close();
        return {"ok": False, "error": "could not start the compile: " + str(e)[:200]};
    }
    log.close();
    with open(os.path.join(d, "pid"), "w") as fp { fp.write(str(proc.pid)); }
    return {"ok": True, **meta};
}

def _alive(pid: int) -> bool {
    if pid <= 0 { return False; }
    try { os.kill(pid, 0); } except Exception as e { return False; }
    # A finished child the server never waited on lingers as a zombie, and
    # kill(pid, 0) still succeeds on one. Reap it if it is ours.
    try {
        (rpid, status) = os.waitpid(pid, os.WNOHANG);
        if rpid == pid { return False; }
    } except Exception as e2 { }
    return True;
}

def _events(d: str) -> list[any] {
    out: list[any] = [];
    p = os.path.join(d, "events.jsonl");
    if not os.path.exists(p) { return out; }
    try {
        with open(p) as f {
            for ln in f.read().splitlines() {
                if ln.strip() {
                    try { out.append(json.loads(ln)); } except Exception as e { }
                }
            }
        }
    } except Exception as e2 { return out; }
    return out[-400:];
}

def compile_status(job: str) -> dict[str, any] {
    if not _job_ok(job) { return {"ok": False, "error": "no such compile"}; }
    d = _job_dir(job);
    meta = _read_json(os.path.join(d, "job.json"));
    if not meta { return {"ok": False, "error": "no such compile"}; }
    result = _read_json(os.path.join(d, "result.json"));
    ask = _read_json(os.path.join(d, "ask.json"));
    pid = 0;
    try {
        with open(os.path.join(d, "pid")) as fp { pid = int(fp.read().strip() or "0"); }
    } except Exception as e { pid = 0; }
    alive = _alive(pid);
    state = "done" if result else ("waiting" if (ask and alive) else ("running" if alive else "stopped"));
    log_tail = "";
    if state == "stopped" {
        try {
            with open(os.path.join(d, "log.txt")) as fl { log_tail = fl.read()[-1500:]; }
        } except Exception as e3 { log_tail = ""; }
    }
    return {"ok": True, "job": job, "meta": meta, "state": state, "events": _events(d),
            "ask": ask if alive else None, "result": result, "log": log_tail,
            "now_ms": int(time.time() * 1000)};
}

def _qnum(rec: any) -> int {
    # A question's number from ask.json / answer.json. The first question is 0,
    # so `.get("i") or -1` would lose it.
    try { return int(dict(rec or {}).get("i", -1)); } except Exception as e { return -1; }
}

def compile_answer(job: str, i: int, answer: str) -> dict[str, any] {
    if not _job_ok(job) { return {"ok": False, "error": "no such compile"}; }
    a = str(answer or "").strip().lower();
    if a not in ["do", "maybe", "dont"] { return {"ok": False, "error": "answer do, maybe or dont"}; }
    d = _job_dir(job);
    ask = _read_json(os.path.join(d, "ask.json"));
    if (not ask) or (_qnum(ask) != i) { return {"ok": False, "error": "that question is no longer open"}; }
    _write_json(os.path.join(d, "answer.json"), {"i": i, "answer": a});
    return {"ok": True, "i": i, "answer": a};
}

def _by_job(r: dict[str, any]) -> str { return str(r["job"]); }

def compile_jobs() -> list[any] {
    out: list[any] = [];
    root_dir = _jobs_root();
    names = [n for n in os.listdir(root_dir) if _job_ok(n)];
    for n in sorted(names, reverse=True)[:12] {
        st = compile_status(n);
        if not st.get("ok") { continue; }
        res = dict(st.get("result") or {});
        out.append({"job": n, "name": dict(st["meta"]).get("name"), "mode": dict(st["meta"]).get("mode"),
                    "created_ms": dict(st["meta"]).get("created_ms"), "state": st["state"],
                    "status": res.get("status") or "", "signature": res.get("signature") or "",
                    "version": res.get("version") or 0});
    }
    return out;
}

# The running job's folder and question counter. A compile_run process runs one
# job, so module state is the honest home for them.
glob _JOB: str = "";
glob _ASK_N: int = 0;

def _job_event(ev: dict[str, any]) {
    if not _JOB { return; }
    rec = dict(ev);
    rec["t"] = time.time();
    # The terminal's own words for each stage, so the console and `sigil compile`
    # describe a compile the same way.
    st = str(rec.get("stage") or "");
    if st and (st not in ["job", "clarify", "spec_detail"]) {
        try {
            import from .sigil_core { compile_stage_label, compile_stage_line, compile_stage_secs }
            rec["label"] = compile_stage_label(st);
            if str(rec.get("state") or "") == "done" {
                rec["line"] = compile_stage_line(rec);
                rec["took"] = compile_stage_secs(rec);
            }
        } except Exception as e0 { }
    }
    try {
        with open(os.path.join(_JOB, "events.jsonl"), "a") as f { f.write(json.dumps(rec, `default=str) + "\n"); }
    } except Exception as e { }
}

def _job_spec_event(ev: dict[str, any]) {
    rec = dict(ev);
    rec["stage"] = "spec_detail";
    _job_event(rec);
}

def _job_ask(question: str) -> str {
    # The compile's --clarify callback, answered from the browser: write the
    # question, wait for the console to write the answer.
    n = _ASK_N;
    _ASK_N = _ASK_N + 1;
    ap = os.path.join(_JOB, "ask.json");
    anp = os.path.join(_JOB, "answer.json");
    _write_json(ap, {"i": n, "question": str(question), "ts": time.time()});
    _job_event({"stage": "clarify", "state": "asked", "i": n, "question": str(question)});
    deadline = time.time() + ASK_TIMEOUT_S;
    while time.time() < deadline {
        got = _read_json(anp);
        if got and (_qnum(got) == n) {
            ans = str(dict(got).get("answer") or "");
            try { os.remove(anp); } except Exception as e { }
            try { os.remove(ap); } except Exception as e2 { }
            _job_event({"stage": "clarify", "state": "answered", "i": n, "answer": ans});
            return ans;
        }
        time.sleep(1.0);
    }
    try { os.remove(ap); } except Exception as e3 { }
    _job_event({"stage": "clarify", "state": "timeout", "i": n});
    return "";
}

def _json_safe(data: any) -> any {
    try { return json.loads(json.dumps(data, `default=str)); } except Exception as e { return {"ok": False, "error": "unencodable result"}; }
}

def compile_run(job: str) -> dict[str, any] {
    # Runs in the detached child compile_start started.
    if not _job_ok(job) { return {"ok": False, "error": "no such compile"}; }
    d = _job_dir(job);
    meta = _read_json(os.path.join(d, "job.json"));
    if not meta { return {"ok": False, "error": "no such compile"}; }
    _JOB = d;
    _ASK_N = 0;
    mode = str(dict(meta).get("mode") or "decide");
    skill_md = os.path.join(d, "skill", str(dict(meta).get("entry") or "SKILL.md"));
    with open(skill_md) as f { src = f.read(); }
    _job_event({"stage": "job", "state": "start", "mode": mode});
    import from .sigil { compile_skill }
    import from .compiler.ai.spec_loop { set_spec_progress }
    set_spec_progress(_job_spec_event);
    ask: any = _job_ask if mode == "ask" else None;
    out: dict[str, any] = {};
    try {
        r = compile_skill(src, False, "", _job_event, False, os.path.dirname(skill_md), False, ask, "",
                          None, mode != "optional");
        out = dict(_json_safe(r));
        if len(str(out.get("agir") or "")) > 200000 { out["agir"] = str(out["agir"])[:200000]; }
    } except Exception as e {
        import from .sigil_errors { friendly_llm_error, log_error }
        log_error("console compile failed: " + job, e);
        out = {"ok": False, "status": "failed", "error": friendly_llm_error(e, "", "compile")};
    }
    set_spec_progress(None);
    out["finished_ms"] = int(time.time() * 1000);
    _write_json(os.path.join(d, "result.json"), out);
    _job_event({"stage": "job", "state": "done", "status": out.get("status")});
    return {"ok": bool(out.get("ok")), "status": out.get("status")};
}
