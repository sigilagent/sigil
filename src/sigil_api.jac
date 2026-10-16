"""The API seam — one place every HTTP endpoint resolves against the real graph.

The Observatory has never shown the agent. Measured three ways:

  · the CLI reports 9 skills and its memories; `POST /walker/api_soul` on the
    running server reports `skills: 0, memories: []`
  · `POST /walker/api_teach` returns "remembered" — and the fact appears in no
    anchor in the store, so anything done in the web UI was discarded
  · `sigil serve` never even ran the guest-root alignment `src/main.jac` provides,
    because the launcher exec'd `jac start` directly

Root alignment alone does not fix it: a server booted with `__guest__` already
pointing at the superroot still reads an empty Soul. The server's graph is simply
not the CLI's graph.

So the endpoints stop trying to own a graph and become a *view* of the one that
exists. `api_call` runs the request in a fresh `jac run` process — the execution
mode that demonstrably reads and writes the real store — and returns its JSON.
The same fresh-subprocess seam the scheduler and the channel bridges already use,
for the same reason.

The cost is one process start per request. The benefit is that the web UI, the
CLI, the TUI, the daemon and every fired job are finally the same agent.
"""

import os;
import json;
import subprocess;
import from .sigil_runtime { _jac_bin, entry_script, project_root }

glob JSON_MARKER: str = "<<<SIGIL_JSON>>>";
glob CHILD_ENV: str = "SIGIL_API_CHILD";

# name -> how many positional args it takes, in declaration order. Kept here so
# the CLI side and the walker side cannot drift apart.
glob API_NAMES: list[str] = [
    "soul", "graph", "library", "mcp", "observability", "recall", "teach",
    "configure", "solve", "register_skill", "add_mcp", "eval", "relearn",
    "forget", "chat", "models", "tools_invoke", "inbound", "cron_tick",
    "cron_list", "cron_runs", "cron_enable", "cron_remove", "skill_agir",
    "tasks", "hooks", "channels", "approvals"
];

def in_child() -> bool {
    # True inside the subprocess an api_call spawned. The guard that stops a
    # proxy from proxying to itself forever.
    return str(os.environ.get(CHILD_ENV) or "") == "1";
}

def child_env() -> dict[str, any] {
    # The server exports its own jac runtime settings into the environment, and a
    # child that inherited them resolved the SERVER's store instead of the
    # project's — the proxy ran, and still answered from an empty graph. Hand the
    # child a clean environment: everything except the runtime's own wiring.
    out: dict[str, any] = {};
    for (k, v) in os.environ.items() {
        key = str(k);
        if key.startswith("JAC") or key.startswith("JACLANG") { continue; }
        out[key] = str(v);
    }
    out[CHILD_ENV] = "1";
    return out;
}

def api_call(name: str, args: dict[str, any], timeout_s: int = 900) -> dict[str, any] {
    # Run one API request against the real graph. Returns
    # {"ok": bool, "data": <whatever the call returned>, "error": str}.
    if in_child() {
        return {"ok": False, "data": None,
                "error": "api_call must not recurse — dispatch directly instead"};
    }
    payload = "{}";
    try {
        payload = json.dumps(args or {});
    } except Exception as e {
        return {"ok": False, "data": None, "error": "arguments are not JSON: " + str(e)[:200]};
    }
    env = child_env();
    argv = [_jac_bin(), "run", "--no-serve", entry_script(), "--", "api", name, payload];
    try {
        p = subprocess.run(argv, cwd=project_root(), env=env, capture_output=True,
                           text=True, timeout=timeout_s);
    } except subprocess.TimeoutExpired as ex {
        return {"ok": False, "data": None, "error": "timed out after " + str(timeout_s) + "s"};
    } except Exception as exc {
        return {"ok": False, "data": None, "error": str(exc)[:300]};
    }
    out = str(p.stdout or "");
    if JSON_MARKER not in out {
        return {"ok": False, "data": None,
                "error": (str(p.stderr or out)[-500:] or "no response from the agent")};
    }
    tail = out.split(JSON_MARKER, 1)[1].strip();
    try {
        parsed = json.loads(tail or "null");
    } except Exception as e2 {
        return {"ok": False, "data": None, "error": "unreadable response: " + tail[:300]};
    }
    body = dict(parsed) if isinstance(parsed, dict) else {"ok": True, "data": parsed, "error": ""};
    return {"ok": bool(body.get("ok", True)), "data": body.get("data"),
            "error": str(body.get("error") or "")};
}

# ---------------------------------------------------------------------------
# Only this machine's own pages may drive the agent.
#
# The endpoints run tools, register commands and rewrite the graph, and they are
# `walker:pub` (no login) so the Observatory and the `sigil` gateway can call
# them. What stops another website from calling them through your browser is
# this check, made before a request does anything:
#   - Sec-Fetch-Site `cross-site` / `same-site`: the request came from another
#     site's page. Browsers set the header and pages cannot change it.
#   - an Origin that is not this server's own (including "null", which sandboxed
#     frames and file:// pages send): the same, for browsers without it.
#   - a Host that is not loopback while the server listens on loopback: DNS
#     rebinding, where another site's name resolves to 127.0.0.1 and its page
#     becomes "same-origin" with this server.
# CORS cannot do this job: it hides a response from the page that asked, but a
# POST that needs no preflight (no Content-Type, or a form) still runs.
# Clients that are not browsers (the `sigil` gateway, curl) send none of these
# headers and pass on a loopback Host. The page at local.sigilagent.com embeds
# the Observatory rather than calling it, so the requests it causes are the
# Observatory's own, same-origin, and pass too.
# ---------------------------------------------------------------------------
glob LOOPBACK_HOSTS: list[str] = ["localhost", "127.0.0.1", "::1"];

def _is_loopback(host: str) -> bool {
    h = host.strip().lower().strip("[]");
    return (h in LOOPBACK_HOSTS) or h.startswith("127.") or h.endswith(".localhost");
}

def _foreign_request() -> str {
    # "" when the request may proceed, else why it was refused.
    import from urllib.parse { urlsplit }
    # jac >=0.37.25. Without it the origin cannot be checked, and an unchecked
    # request is exactly what this exists to stop: refuse.
    try {
        import from jaclang.server.exchange { current_request }
    } except Exception as e {
        return "refused: this jac cannot report where the request came from (" + str(e) + ")";
    }
    req = current_request();
    if req is None {
        return "";   # not an HTTP request: the CLI, a test, the daemon
    }
    site = str(req.header("sec-fetch-site") or "").lower();
    if site in ["cross-site", "same-site"] {
        return "refused: a request from another website's page";
    }
    here = str(req.origin or "");
    host = str(urlsplit(here).hostname or "") if here else "";
    if _is_loopback(os.getenv("SIGIL_SERVE_HOST") or "127.0.0.1") and (not _is_loopback(host)) {
        return "refused: this server answers to localhost, not '" + host + "'";
    }
    origin = str(req.header("origin") or "");
    if origin and (origin.rstrip("/").lower() != here.rstrip("/").lower()) {
        return "refused: a request from " + origin;
    }
    return "";
}

def report_for(name: str, args: dict[str, any]) -> any {
    # What a `walker:pub` reports. On success the caller sees exactly what the
    # local function would have returned; on failure it sees why, rather than a
    # plausible-looking empty answer — which is how "the Observatory works" went
    # unnoticed for so long.
    refusal = _foreign_request();
    if refusal {
        import from jaclang.server.exchange { respond }
        respond(status=403);
        return {"ok": False, "error": refusal};
    }
    r = api_call(name, args);
    if r["ok"] { return r["data"]; }
    return {"ok": False, "error": str(r["error"]),
            "hint": "the endpoint runs the request against the agent's own graph; "
                    + "this one did not complete"};
}
