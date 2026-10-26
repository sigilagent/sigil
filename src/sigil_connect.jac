"""Connections — every route Sigil has to a model, and whether each one is live.

A model tier is a litellm name (`chatgpt-plan/gpt-x`, `claude-cc/opus`,
`ollama_chat/qwen3:8b`, `openai/gpt-5`), and a name is only as good as the
credential behind it. This module is the one place that knows both halves: which
routes exist, how to connect each one, and whether the tiers on the graph have a
working route under them.

| Route | Kind | How it connects |
|---|---|---|
| ChatGPT | sign-in | a browser link; the user's ChatGPT plan pays (`sigil_chatgpt`) |
| Claude Code | CLI | the `claude` CLI's own login; the Claude subscription pays (`sigil_claude_cc`) |
| OpenRouter | sign-in | a browser link that mints a key for Sigil (OAuth PKCE) |
| Ollama | local | a running Ollama here; `ollama signin` adds its `:cloud` models |
| Ollama Cloud | key | ollama.com's hosted models over the API, no local Ollama (`ollama-cloud/<model>`) |
| OpenAI, Anthropic, Gemini, Z.ai | key | a pasted key, kept in $SIGIL_HOME/secrets.env (0600) |

Status checks never spend a model call. The one network probe is the local
Ollama port, which answers in milliseconds or not at all.

`sigil setup` requires a connection: it does not finish until the frontier tier
has a live route. `ready_tiers()` is the check behind that, and behind the gate
that sends an interactive `sigil chat` to setup when nothing is connected
(`SIGIL_REQUIRE_CONNECTION=0` turns the gate off).
"""

import os;
import shutil;
import subprocess;
import from .sigil_secrets { secret_value_set, secret_value_clear, secret_source, secret_tail }
import from .sigil_claude_cc { auth_status as claude_auth }
import from .sigil_chatgpt {
    auth_status as chatgpt_auth, build_authorize, finish_signin, sign_out as chatgpt_sign_out,
    CALLBACK_PATH as CHATGPT_CALLBACK, USAGE_URL as CHATGPT_USAGE_URL
}
import from .sigil_oauth { browser_flow, start_flow, flow_status, pkce_pair, random_token, OAuthError }

# [id, label, kind, what it is]
glob PROVIDERS: list[any] = [
    ["chatgpt", "ChatGPT", "signin", "Your ChatGPT plan pays. Sign in with your browser; no API key."],
    ["claude-code", "Claude Code", "cli", "Your Claude subscription pays, through the claude CLI you already use."],
    ["openrouter", "OpenRouter", "signin", "One sign-in, hundreds of models. Sigil gets a key of its own."],
    ["ollama", "Ollama", "local", "Models on this machine, free and private. Signed in, it also runs Ollama's :cloud models."],
    ["ollama-cloud", "Ollama Cloud API", "key", "Ollama's hosted models over its API, with no local Ollama."],
    ["openai", "OpenAI API", "key", "Pay-as-you-go OpenAI API key."],
    ["anthropic", "Anthropic API", "key", "Pay-as-you-go Anthropic API key."],
    ["gemini", "Google Gemini API", "key", "Pay-as-you-go Gemini API key."],
    ["zai", "Z.ai API", "key", "Pay-as-you-go Z.ai (GLM) API key."]
];

# Key providers: id -> [env var, frontier model, small model, where to get a key]
glob KEYED: dict[str, any] = {
    "openai": ["OPENAI_API_KEY", "openai/gpt-5", "openai/gpt-5-mini", "https://platform.openai.com/api-keys"],
    "anthropic": ["ANTHROPIC_API_KEY", "anthropic/claude-sonnet-5-5", "anthropic/claude-haiku-5-5", "https://console.anthropic.com/settings/keys"],
    "gemini": ["GEMINI_API_KEY", "gemini/gemini-2.5-pro", "gemini/gemini-2.5-flash", "https://aistudio.google.com/apikey"],
    "zai": ["ZAI_API_KEY", "zai/glm-4.6", "zai/glm-4.5-air", "https://z.ai/manage-apikey/apikey-list"],
    "openrouter": ["OPENROUTER_API_KEY", "openrouter/openrouter/auto", "openrouter/openrouter/auto", "https://openrouter.ai/keys"],
    "ollama-cloud": ["OLLAMA_API_KEY", "ollama-cloud/glm-5.3", "ollama-cloud/gpt-oss:20b", "https://ollama.com/settings/keys"]
};

# Who answers a tier, the order setup prefers them in. Subscriptions first for
# the frontier (compiling is rare and judgment-heavy); local and cheap first for
# the small tier, which runs every compiled skill.
glob FRONTIER_ORDER: list[str] = ["chatgpt", "claude-code", "anthropic", "openai", "openrouter", "gemini", "zai", "ollama-cloud", "ollama"];
glob SMALL_ORDER: list[str] = ["ollama", "chatgpt", "openai", "anthropic", "gemini", "openrouter", "zai", "ollama-cloud", "claude-code"];

glob CLAUDE_MODELS: list[str] = ["claude-cc/opus", "claude-cc/sonnet", "claude-cc/haiku"];
glob OPENROUTER_AUTH: str = "https://openrouter.ai/auth";
glob OPENROUTER_KEYS: str = "https://openrouter.ai/api/v1/auth/keys";

def gate_on() -> bool {
    # Default ON: a mandate you have to remember to enable is not one.
    v = (os.getenv("SIGIL_REQUIRE_CONNECTION") or "").strip().lower();
    return v not in ["0", "false", "no", "off"];
}

def provider_label(pid: str) -> str {
    for p in PROVIDERS { if str(p[0]) == pid { return str(p[1]); } }
    return pid;
}

def provider_of(model: str) -> str {
    # Which route a litellm model name runs on. "" when Sigil cannot tell, in
    # which case litellm gets the name as is and nobody claims to know better.
    m = str(model or "").strip().lower();
    if not m { return ""; }
    if m.startswith("chatgpt-plan/") or m.startswith("chatgpt/") { return "chatgpt"; }
    if m.startswith("claude-cc/") { return "claude-code"; }
    if m.startswith("ollama-cloud/") { return "ollama-cloud"; }
    if m.startswith("ollama") { return "ollama"; }
    if m.startswith("openrouter/") { return "openrouter"; }
    for p in ["openai/", "gpt", "o1", "o3", "o4", "chatgpt-"] { if m.startswith(p) { return "openai"; } }
    for p in ["anthropic/", "claude-"] { if m.startswith(p) { return "anthropic"; } }
    for p in ["gemini", "google/"] { if m.startswith(p) { return "gemini"; } }
    for p in ["zai/", "glm"] { if m.startswith(p) { return "zai"; } }
    return "";
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
def _claude_bin() -> str {
    return str(shutil.which(os.getenv("SIGIL_CLAUDE_BIN") or "claude") or "");
}

def _ollama_base() -> str {
    h = str(os.getenv("OLLAMA_HOST") or "").strip();
    if not h { return "http://127.0.0.1:11434"; }
    if not h.startswith("http") { h = "http://" + h; }
    return h.rstrip("/");
}

def ollama_models() -> list[any] {
    # [{"name", "size_b"}] pulled into the local Ollama, or [] when none answers.
    import httpx;
    try {
        r = httpx.get(_ollama_base() + "/api/tags", timeout=1.5);
        if r.status_code != 200 { return []; }
        out: list[any] = [];
        for m in list(dict(r.json()).get("models") or []) {
            d = dict(m);
            det = dict(d.get("details") or {});
            out.append({"name": str(d.get("name") or ""), "size_b": _billions(str(det.get("parameter_size") or ""))});
        }
        return out;
    } except Exception as e { return []; }
}

def is_cloud_tag(name: str) -> bool {
    # A model the local Ollama runs on ollama.com once it is signed in: nothing
    # to download, so "pulled" is not the test for it.
    n = str(name or "").lower();
    return n.endswith(":cloud") or n.endswith("-cloud");
}

def _billions(s: str) -> float {
    # "8.2B" -> 8.2, "500M" -> 0.5; 0.0 when Ollama does not say.
    t = s.strip().upper();
    try {
        if t.endswith("B") { return float(t[:-1]); }
        if t.endswith("M") { return float(t[:-1]) / 1000.0; }
    } except Exception as e { return 0.0; }
    return 0.0;
}

def _row(pid: str) -> dict[str, any] {
    for p in PROVIDERS {
        if str(p[0]) == pid {
            return {"id": pid, "label": str(p[1]), "kind": str(p[2]), "about": str(p[3]),
                    "connected": False, "account": "", "detail": "", "models": [], "env": ""};
        }
    }
    return {"id": pid, "label": pid, "kind": "", "about": "", "connected": False, "account": "",
            "detail": "", "models": [], "env": ""};
}

def provider_status(pid: str) -> dict[str, any] {
    r = _row(pid);
    if pid == "chatgpt" {
        st: dict[str, any] = chatgpt_auth();
        mode = str(st["mode"]);
        r["account"] = str(st["account"]);
        r["models"] = ["chatgpt-plan/" + str(m) for m in list(st["models"])];
        r["connected"] = mode == "plan";
        r["detail"] = ("signed in as " + str(st["account"])) if mode == "plan"
                      else ("signed in, but plan use was not allowed" if mode == "disabled" else "not signed in");
    } elif pid == "claude-code" {
        b = _claude_bin();
        a: dict[str, any] = claude_auth();
        mode = str(a["mode"]);
        r["account"] = str(a["account"]);
        r["models"] = list(CLAUDE_MODELS);
        r["connected"] = bool(b) and (mode in ["subscription", "api-key", "unknown"]);
        if not b { r["detail"] = "the claude CLI is not installed"; }
        elif mode == "none" { r["detail"] = "the claude CLI is not signed in"; }
        elif mode == "api-key" { r["detail"] = "the claude CLI bills an API key"; }
        else { r["detail"] = "signed in" + ((" as " + str(a["account"])) if a["account"] else ""); }
    } elif pid == "ollama" {
        ms = ollama_models();
        r["models"] = ["ollama_chat/" + str(m["name"]) for m in ms];
        r["connected"] = len(ms) > 0;
        nc = len([m for m in ms if is_cloud_tag(str(m["name"]))]);
        if ms {
            r["detail"] = "running · " + str(len(ms)) + " model" + ("" if len(ms) == 1 else "s")
                          + ((" (" + str(nc) + " cloud)") if nc else "");
        }
        elif _reachable_ollama() { r["detail"] = "running, but no models pulled yet"; }
        elif shutil.which("ollama") { r["detail"] = "installed, not running"; }
        else { r["detail"] = "not installed"; }
    } elif pid in KEYED {
        env = str(KEYED[pid][0]);
        r["env"] = env;
        val = str(os.environ.get(env) or "");
        if (not val) and (pid == "gemini") { val = str(os.environ.get("GOOGLE_API_KEY") or ""); }
        r["connected"] = bool(val);
        r["models"] = [str(KEYED[pid][1]), str(KEYED[pid][2])] if (str(KEYED[pid][1]) != str(KEYED[pid][2])) else [str(KEYED[pid][1])];
        src = secret_source(env);
        tail = secret_tail(env);
        r["account"] = ("key …" + tail) if tail else "";
        r["detail"] = ("key set" + ((" (" + ("saved by Sigil" if src == "console" else "from your shell") + ")") if src else ""))
                      if val else "no key";
    }
    return r;
}

def _reachable_ollama() -> bool {
    import httpx;
    try { return httpx.get(_ollama_base() + "/api/version", timeout=1.0).status_code == 200; }
    except Exception as e { return False; }
}

def connections() -> list[any] {
    return [provider_status(str(p[0])) for p in PROVIDERS];
}

def connected_ids(rows: list[any]) -> list[str] {
    return [str(r["id"]) for r in rows if r["connected"]];
}

# ---------------------------------------------------------------------------
# Which tiers have a live route
# ---------------------------------------------------------------------------
def model_ready(model: str, rows: list[any]) -> dict[str, any] {
    pid = provider_of(model);
    if not model { return {"ok": False, "provider": "", "why": "no model set"}; }
    if not pid { return {"ok": True, "provider": "", "why": "Sigil cannot check this provider; litellm gets the name as is"}; }
    for r in rows {
        if str(r["id"]) == pid {
            if not r["connected"] { return {"ok": False, "provider": pid, "why": provider_label(pid) + ": " + str(r["detail"])}; }
            if (pid == "ollama") and (str(model) not in list(r["models"])) and (not is_cloud_tag(str(model))) {
                return {"ok": False, "provider": pid, "why": "Ollama has not pulled " + str(model).split("/", 1)[-1]};
            }
            return {"ok": True, "provider": pid, "why": ""};
        }
    }
    return {"ok": True, "provider": pid, "why": ""};
}

def ready_tiers() -> dict[str, any] {
    # {"tiers": {tier: {"model", "ok", "provider", "why"}}, "ok": frontier+chat live}
    import from .sigil_core { describe_soul }
    s = describe_soul();
    rows = connections();
    out: dict[str, any] = {};
    for t in ["frontier", "chat", "small", "router"] {
        m = str(s[t + "_model"] or "");
        rd = model_ready(m, rows);
        out[t] = {"model": m, "ok": rd["ok"], "provider": rd["provider"], "why": rd["why"]};
    }
    return {"tiers": out, "ok": bool(out["frontier"]["ok"]) and bool(out["chat"]["ok"]), "rows": rows};
}

# ---------------------------------------------------------------------------
# Suggested tiers from what is connected
# ---------------------------------------------------------------------------
def _pick_small_chatgpt(models: list[any]) -> str {
    for m in models {
        low = str(m).lower();
        if ("mini" in low) or ("nano" in low) or ("fast" in low) or ("instant" in low) { return str(m); }
    }
    return str(models[0]) if models else "chatgpt-plan/default";
}

def _pick_ollama(big: bool) -> str {
    # The small tier wants a model that can follow a compiled procedure: a few
    # billion parameters at least. The frontier wants the biggest one there is.
    ms = ollama_models();
    if not ms { return ""; }
    if big {
        # A signed-in Ollama's cloud models are far stronger than anything that
        # fits on a laptop: they take the frontier when there is one.
        for m in ms { if is_cloud_tag(str(m["name"])) { return "ollama_chat/" + str(m["name"]); } }
    }
    best = "";
    best_b = -1.0;
    for m in ms {
        b = float(m["size_b"]);
        if (not big) and (b > 0.0) and (b < 7.0) { continue; }
        if (big and (b > best_b)) or ((not big) and (best == "")) { best = str(m["name"]); best_b = b; }
    }
    return ("ollama_chat/" + best) if best else "";
}

def _model_for(pid: str, row: dict[str, any], tier: str) -> str {
    big = tier == "frontier";
    if pid == "chatgpt" {
        ms = list(row["models"]);
        if big { return str(ms[0]) if ms else "chatgpt-plan/default"; }
        return _pick_small_chatgpt(ms);
    }
    if pid == "claude-code" { return "claude-cc/opus" if big else "claude-cc/haiku"; }
    if pid == "ollama" { return _pick_ollama(big); }
    if pid in KEYED { return str(KEYED[pid][1]) if big else str(KEYED[pid][2]); }
    return "";
}

def suggest_tiers(rows: list[any]) -> dict[str, str] {
    # {frontier, chat, small, router} from the connected routes; "" for a tier
    # nothing connected can answer.
    byid: dict[str, any] = {};
    for r in rows { if r["connected"] { byid[str(r["id"])] = r; } }
    frontier = "";
    for pid in FRONTIER_ORDER {
        if pid in byid { frontier = _model_for(pid, byid[pid], "frontier"); }
        if frontier { break; }
    }
    small = "";
    for pid in SMALL_ORDER {
        if pid in byid { small = _model_for(pid, byid[pid], "small"); }
        if small { break; }
    }
    if not small { small = frontier; }
    if not frontier { frontier = small; }
    return {"frontier": frontier, "chat": frontier, "small": small, "router": small};
}

def tiers_for(pid: str, rows: list[any]) -> dict[str, str] {
    # The tiers for a route the user just picked by name: it takes the frontier
    # and chat, and the small tier too unless it is a CLI subscription, whose
    # per-call preamble makes it the wrong thing to run every compiled skill on.
    row: dict[str, any] = {};
    for r in rows { if str(r["id"]) == pid { row = r; } }
    if (not row) or (not row["connected"]) { return {}; }
    frontier = _model_for(pid, row, "frontier");
    small = "" if (pid == "claude-code") else _model_for(pid, row, "small");
    if not small { small = str(suggest_tiers(rows)["small"]); }
    if not frontier { frontier = small; }
    return {"frontier": frontier, "chat": frontier, "small": small, "router": small};
}

def apply_tiers(tiers: dict[str, str]) -> list[str] {
    import from .sigil_core { configure }
    said: list[str] = [];
    for t in ["frontier", "chat", "small", "router"] {
        v = str(tiers.get(t) or "").strip();
        if v { said.append(str(configure(t + "_model", v))); }
    }
    return said;
}

# ---------------------------------------------------------------------------
# Connecting
# ---------------------------------------------------------------------------
def _cg_build(redirect: str) -> tuple[str, dict[str, any]] { return build_authorize(redirect, False); }
def _cg_build_fresh(redirect: str) -> tuple[str, dict[str, any]] { return build_authorize(redirect, True); }

def _or_build(redirect: str) -> tuple[str, dict[str, any]] {
    pair: tuple[str, str] = pkce_pair();
    state = random_token(24);
    import urllib.parse;
    q = urllib.parse.urlencode({"callback_url": redirect, "code_challenge": pair[1],
                                "code_challenge_method": "S256", "state": state, "key_label": "Sigil"});
    return (OPENROUTER_AUTH + "?" + q, {"verifier": pair[0], "state": state});
}

def _or_finish(params: dict[str, any], ctx: dict[str, any]) -> dict[str, any] {
    import httpx;
    if params.get("state") and (str(params.get("state")) != str(ctx["state"])) {
        raise OAuthError("the sign-in came back with the wrong state; start it again");
    }
    code = str(params.get("code") or "");
    if not code { raise OAuthError("OpenRouter did not send a code back — the sign-in may have been cancelled"); }
    r = httpx.post(OPENROUTER_KEYS, json={"code": code, "code_verifier": ctx["verifier"],
                                          "code_challenge_method": "S256"}, timeout=30.0);
    key = "";
    try { key = str(dict(r.json()).get("key") or ""); } except Exception as e { key = ""; }
    if (r.status_code != 200) or (not key) {
        raise OAuthError("OpenRouter would not issue a key (HTTP " + str(r.status_code) + "): " + str(r.text)[:200]);
    }
    saved: dict[str, any] = secret_value_set("OPENROUTER_API_KEY", key);
    if not saved["ok"] { raise OAuthError(str(saved.get("error") or "could not save the key")); }
    return {"provider": "openrouter", "account": "key …" + key[-4:],
            "detail": "OpenRouter key saved to " + str(saved.get("file") or "the secrets file")};
}

def connect_chatgpt(on_url: any = None, fresh: bool = False, open_browser: bool = True) -> dict[str, any] {
    return browser_flow(_cg_build_fresh if fresh else _cg_build, finish_signin, CHATGPT_CALLBACK,
                        "127.0.0.1", 600, on_url, open_browser);
}

def connect_openrouter(on_url: any = None, open_browser: bool = True) -> dict[str, any] {
    return browser_flow(_or_build, _or_finish, "/callback", "localhost", 600, on_url, open_browser);
}

def connect_start(pid: str, fresh: bool = False) -> dict[str, any] {
    # The Observatory's version: start the sign-in on a thread of the server and
    # hand the page the link. The page polls `connect_poll` for the outcome.
    if pid == "chatgpt" {
        return dict(start_flow("chatgpt", _cg_build_fresh if fresh else _cg_build, finish_signin,
                               CHATGPT_CALLBACK, "127.0.0.1"));
    }
    if pid == "openrouter" {
        return dict(start_flow("openrouter", _or_build, _or_finish, "/callback", "localhost"));
    }
    return {"id": "", "url": "", "error": provider_label(pid) + " does not connect through a browser link"};
}

def connect_poll(fid: str) -> dict[str, any] {
    return dict(flow_status(fid));
}

def connect_key(pid: str, value: str) -> dict[str, any] {
    # Save a pasted key, then prove it with one cheap authenticated call.
    if pid not in KEYED { return {"ok": False, "error": "no key provider called '" + pid + "'"}; }
    env = str(KEYED[pid][0]);
    saved: dict[str, any] = secret_value_set(env, value);
    if not saved["ok"] { return saved; }
    chk: dict[str, any] = {"ok": True, "detail": "saved (not tested)"};
    try {
        import from .sigil_console { secret_check }
        chk = secret_check(env);
    } except ImportError as e { }
    return {"ok": bool(chk["ok"]), "env": env, "detail": str(chk.get("detail") or ""),
            "file": str(saved.get("file") or "")};
}

def claude_login() -> dict[str, any] {
    # The claude CLI's own sign-in, in this terminal: it prints a link and opens
    # the browser itself. Its login is the CLI's, so Sigil only starts it.
    b = _claude_bin();
    if not b { return {"ok": False, "detail": "install Claude Code first: npm install -g @anthropic-ai/claude-code"}; }
    try { subprocess.run([b, "auth", "login"]); }
    except Exception as e { return {"ok": False, "detail": "could not start `claude auth login`: " + str(e)[:160]}; }
    st = provider_status("claude-code");
    return {"ok": bool(st["connected"]), "detail": str(st["detail"])};
}

def ollama_pull(model: str) -> dict[str, any] {
    b = shutil.which("ollama");
    if not b { return {"ok": False, "detail": "install Ollama first: https://ollama.com/download"}; }
    try { p = subprocess.run([str(b), "pull", model]); }
    except Exception as e { return {"ok": False, "detail": "could not run `ollama pull`: " + str(e)[:160]}; }
    return {"ok": p.returncode == 0, "detail": ("pulled " + model) if (p.returncode == 0) else ("`ollama pull " + model + "` failed")};
}

def ollama_signin() -> dict[str, any] {
    # Ollama's own sign-in, in this terminal: it prints a link that connects this
    # machine to an ollama.com account, after which `:cloud` models run here.
    b = shutil.which("ollama");
    if not b { return {"ok": False, "detail": "install Ollama first: https://ollama.com/download"}; }
    try { p = subprocess.run([str(b), "signin"]); }
    except Exception as e { return {"ok": False, "detail": "could not run `ollama signin`: " + str(e)[:160]}; }
    return {"ok": p.returncode == 0, "detail": "signed in to ollama.com" if (p.returncode == 0) else "`ollama signin` did not finish"};
}

def disconnect(pid: str) -> dict[str, any] {
    if pid == "chatgpt" { return dict(chatgpt_sign_out()); }
    if pid in KEYED {
        env = str(KEYED[pid][0]);
        if secret_source(env) == "shell" {
            return {"ok": False, "detail": env + " is exported in your shell; unset it there"};
        }
        r: dict[str, any] = secret_value_clear(env);
        return {"ok": True, "detail": ("removed " + env) if r.get("removed") else (env + " was not saved by Sigil")};
    }
    if pid == "claude-code" {
        return {"ok": False, "detail": "that login belongs to the claude CLI; `claude auth logout` signs it out everywhere"};
    }
    if pid == "ollama" { return {"ok": False, "detail": "Ollama has no sign-in; stop it or point the tiers elsewhere"}; }
    return {"ok": False, "detail": "no provider called '" + pid + "'"};
}

def how_to(pid: str) -> str {
    # One line: what connecting this route takes, for a screen that cannot do it.
    if pid == "chatgpt" { return "sigil connect chatgpt — opens a ChatGPT sign-in in your browser"; }
    if pid == "openrouter" { return "sigil connect openrouter — opens an OpenRouter sign-in in your browser"; }
    if pid == "claude-code" { return "install Claude Code, then `claude auth login` (or `sigil connect claude-code`)"; }
    if pid == "ollama" { return "install Ollama (ollama.com/download), then `ollama pull qwen3:8b`, or `ollama signin` for :cloud models"; }
    if pid in KEYED { return "sigil connect " + pid + " — paste a key from " + str(KEYED[pid][3]); }
    return "";
}
