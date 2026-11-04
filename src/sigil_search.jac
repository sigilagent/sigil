"""Web search connections — a search provider connected by a browser sign-in.

`web_search` needs a real search API: keyless engines serve bot challenges, not
results. A pasted key works (Brave, Serper, Firecrawl), but some providers now
offer what ChatGPT and OpenRouter do for models: a link, a sign-in, and it works.
They do it through their hosted MCP server, using the MCP authorization spec:

    1. discover   GET <mcp origin>/.well-known/oauth-protected-resource<path>
                  -> the authorization server -> its OAuth metadata
    2. register   RFC 7591 dynamic client registration: Sigil registers itself
                  as a public native client (no secret) for this loopback
                  redirect, during the user's first sign-in
    3. sign in    authorization code + PKCE S256, with `resource` (RFC 8707)
                  naming the MCP server the token is for
    4. search     JSON-RPC over MCP streamable HTTP, `Authorization: Bearer`

The token is good for that MCP server alone, not the provider's REST API, so the
search itself is an MCP `tools/call`. Each provider is one entry in `SPECS`:
Tavily today; Exa and Parallel publish the same flow and would be entries too.

`sigil_oauth` runs the loopback listener between `build_authorize` and
`finish_signin` (composed in `sigil_connect`). The credential is one 0600 record
at $SIGIL_HOME/auth/search-<id>.json. Refresh tokens may rotate, so refreshing
happens under a file lock shared by every Sigil process.

Serper has no sign-in, only an API key; `search_serper` is its REST call.

Pure stdlib plus httpx, in a ``::py::`` block like `sigil_chatgpt`, and it reads
no other Sigil module.
"""

::py::
import base64
import hashlib
import json
import os
import re
import secrets
import time
import urllib.parse

# id -> what Sigil needs to know about one sign-in search provider.
SPECS = {
    "tavily": {
        "label": "Tavily",
        "mcp": "https://mcp.tavily.com/mcp",
        "scope": "openid offline_access",
        "tool": "tavily_search",
        "args": lambda q, n: {"query": q, "max_results": n},
        "home": "https://app.tavily.com",
    },
}
CALLBACK_PATH = "/callback"
APP_NAME = "Sigil"
APP_URI = "https://sigilagent.com"
MCP_VERSION = "2025-06-18"
SERPER_URL = "https://google.serper.dev/search"


class SearchAuthError(RuntimeError):
    """A search sign-in that did not produce a working credential, in one sentence."""


class McpUnauthorized(RuntimeError):
    """The MCP server refused the bearer token (HTTP 401)."""


# ---------------------------------------------------------------------------
# The credential record
# ---------------------------------------------------------------------------
def _auth_dir() -> str:
    d = os.path.join(os.environ.get("SIGIL_HOME") or os.path.expanduser("~/.sigil"), "auth")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _spec(pid: str) -> dict:
    s = SPECS.get(str(pid))
    if not s:
        raise SearchAuthError("no sign-in search provider called %r" % pid)
    return s


def creds_path(pid: str) -> str:
    safe = "".join(ch for ch in str(pid) if ch.isalnum() or ch == "-")
    return os.path.join(_auth_dir(), "search-" + safe + ".json")


def _read(path: str) -> dict:
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _write(path: str, data: dict) -> None:
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load_creds(pid: str) -> dict:
    return _read(creds_path(pid))


class _Lock:
    """Exclusive, cross-process: two processes spending one rotating refresh
    token would sign the user out."""

    def __init__(self, pid: str):
        self._name = creds_path(pid) + ".lock"

    def __enter__(self):
        self._fh = open(self._name, "a+")
        try:
            import fcntl
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        except Exception:
            pass
        return self

    def __exit__(self, *exc):
        try:
            import fcntl
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_UN)
        except Exception:
            pass
        self._fh.close()
        return False


# ---------------------------------------------------------------------------
# Discovery and registration
# ---------------------------------------------------------------------------
def _get_json(url: str):
    import httpx
    try:
        r = httpx.get(url, headers={"Accept": "application/json"}, timeout=15.0, follow_redirects=True)
        if r.status_code != 200:
            return None
        d = r.json()
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def _well_known(base_url: str, name: str) -> list:
    # RFC 8414 / RFC 9728 put the well-known segment before any path; some
    # servers also answer at the root. Try both, path-inserted first.
    u = urllib.parse.urlsplit(base_url)
    origin = u.scheme + "://" + u.netloc
    path = u.path.rstrip("/")
    out = [origin + "/.well-known/" + name + path]
    if path:
        out.append(origin + "/.well-known/" + name)
    return out


def discover(mcp_url: str) -> dict:
    """The OAuth endpoints that guard one MCP server."""
    prm = None
    for u in _well_known(mcp_url, "oauth-protected-resource"):
        prm = _get_json(u)
        if prm:
            break
    servers = list((prm or {}).get("authorization_servers") or [])
    as_url = str(servers[0]) if servers else urllib.parse.urlsplit(mcp_url)._replace(path="", query="").geturl()
    meta = None
    for name in ("oauth-authorization-server", "openid-configuration"):
        for u in _well_known(as_url, name):
            meta = _get_json(u)
            if meta and meta.get("authorization_endpoint"):
                break
            meta = None
        if meta:
            break
    if not meta:
        raise SearchAuthError("could not find the sign-in endpoints for %s — the provider may be down" % mcp_url)
    if "S256" not in list(meta.get("code_challenge_methods_supported") or ["S256"]):
        raise SearchAuthError("%s does not offer PKCE S256, which Sigil requires" % as_url)
    return {
        "resource": str((prm or {}).get("resource") or mcp_url),
        "issuer": str(meta.get("issuer") or as_url),
        "authorization_endpoint": str(meta["authorization_endpoint"]),
        "token_endpoint": str(meta.get("token_endpoint") or ""),
        "registration_endpoint": str(meta.get("registration_endpoint") or ""),
        "revocation_endpoint": str(meta.get("revocation_endpoint") or ""),
        "iss_param": bool(meta.get("authorization_response_iss_parameter_supported")),
    }


def register_client(meta: dict, redirect_uri: str) -> str:
    """RFC 7591: register Sigil as a public native client for this redirect."""
    import httpx
    url = str(meta.get("registration_endpoint") or "")
    if not url:
        raise SearchAuthError("the provider does not let apps register themselves, so Sigil cannot sign in to it")
    body = {
        "client_name": APP_NAME,
        "client_uri": APP_URI,
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
        "application_type": "native",
    }
    try:
        r = httpx.post(url, json=body, headers={"Accept": "application/json"}, timeout=20.0)
    except Exception as e:
        raise SearchAuthError("could not reach the provider to register Sigil: %s" % str(e)[:160])
    cid = ""
    try:
        cid = str(r.json().get("client_id") or "")
    except Exception:
        cid = ""
    if r.status_code not in (200, 201) or not cid:
        raise SearchAuthError("the provider would not register Sigil (HTTP %d): %s" % (r.status_code, r.text[:200]))
    return cid


def _pkce() -> tuple:
    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge.decode("ascii").rstrip("=")


# ---------------------------------------------------------------------------
# Sign-in: the provider's half of a sigil_oauth browser flow
# ---------------------------------------------------------------------------
def authorize_url(meta: dict, client_id: str, redirect_uri: str, scope: str,
                  state: str, challenge: str) -> str:
    q = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "resource": meta["resource"],
    }
    if scope:
        q["scope"] = scope
    sep = "&" if "?" in meta["authorization_endpoint"] else "?"
    return meta["authorization_endpoint"] + sep + urllib.parse.urlencode(q)


def build_authorize(pid: str, redirect_uri: str) -> tuple:
    """(authorize URL, context for finish_signin). Registers Sigil first when the
    stored registration was for another redirect (the loopback port changes)."""
    spec = _spec(pid)
    meta = discover(spec["mcp"])
    # The registration is kept apart from the tokens' own client_id: an abandoned
    # sign-in must not leave a live token pointing at a client it was not issued to.
    reg = dict(load_creds(pid).get("registration") or {})
    client_id = str(reg.get("client_id") or "")
    if (not client_id) or reg.get("redirect_uri") != redirect_uri or reg.get("issuer") != meta["issuer"]:
        client_id = register_client(meta, redirect_uri)
        with _Lock(pid):
            cur = load_creds(pid)
            cur["registration"] = {"client_id": client_id, "redirect_uri": redirect_uri, "issuer": meta["issuer"]}
            _write(creds_path(pid), cur)
    verifier, challenge = _pkce()
    state = secrets.token_urlsafe(24)
    url = authorize_url(meta, client_id, redirect_uri, spec.get("scope") or "", state, challenge)
    return url, {"pid": pid, "verifier": verifier, "state": state, "client_id": client_id,
                 "redirect_uri": redirect_uri, "meta": meta}


def _claims(jwt: str) -> dict:
    # Display only (who signed in): the token came straight from the token
    # endpoint over TLS and nothing is authorised on these claims.
    try:
        part = str(jwt).split(".")[1]
        part += "=" * (-len(part) % 4)
        d = json.loads(base64.urlsafe_b64decode(part.encode("ascii")))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _form_post(url: str, form: dict) -> dict:
    import httpx
    try:
        r = httpx.post(url, data=form, headers={"Accept": "application/json"}, timeout=30.0)
    except Exception as e:
        return {"_status": 0, "error": "unreachable", "error_description": str(e)[:160]}
    try:
        body = r.json()
    except Exception:
        body = {"error_description": r.text[:300]}
    if not isinstance(body, dict):
        body = {"error_description": str(body)[:300]}
    body["_status"] = r.status_code
    return body


def _save_tokens(rec: dict, tok: dict) -> dict:
    now = time.time()
    rec = dict(rec)
    for k in ("access_token", "refresh_token", "id_token", "token_type"):
        if tok.get(k):
            rec[k] = tok[k]
    rec["expires_at"] = now + int(tok.get("expires_in") or 3600)
    rec["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    return rec


def finish_signin(pid: str, params: dict, ctx: dict) -> dict:
    """Trade the callback for a token, prove it on the MCP server, and save it."""
    spec = _spec(pid)
    meta = dict(ctx["meta"])
    if params.get("error"):
        raise SearchAuthError("%s: %s" % (spec["label"], params.get("error_description") or params.get("error")))
    if str(params.get("state") or "") != str(ctx["state"]):
        raise SearchAuthError("the sign-in came back with the wrong state; start it again")
    if params.get("iss") and str(params["iss"]).rstrip("/") != meta["issuer"].rstrip("/"):
        raise SearchAuthError("the sign-in came back from %r, not %s" % (params["iss"], meta["issuer"]))
    code = str(params.get("code") or "")
    if not code:
        raise SearchAuthError("%s sent no code back — the sign-in may have been cancelled" % spec["label"])
    tok = _form_post(meta["token_endpoint"], {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": ctx["redirect_uri"],
        "client_id": ctx["client_id"],
        "code_verifier": ctx["verifier"],
        "resource": meta["resource"],
    })
    if tok.get("_status") != 200 or not tok.get("access_token"):
        raise SearchAuthError("%s would not issue a token (HTTP %s): %s" % (
            spec["label"], tok.get("_status"), tok.get("error_description") or tok.get("error") or "no reason given"))
    c = _claims(str(tok.get("id_token") or "")) or _claims(str(tok["access_token"]))
    account = str(c.get("email") or c.get("name") or c.get("preferred_username") or "")
    rec = _save_tokens({
        "provider": pid, "client_id": ctx["client_id"], "redirect_uri": ctx["redirect_uri"],
        "registration": {"client_id": ctx["client_id"], "redirect_uri": ctx["redirect_uri"], "issuer": meta["issuer"]},
        "issuer": meta["issuer"], "token_endpoint": meta["token_endpoint"],
        "revocation_endpoint": meta["revocation_endpoint"], "resource": meta["resource"],
        "mcp": spec["mcp"], "account": account,
    }, tok)
    # Prove it before saying "connected": a token the MCP server refuses (an
    # account with no API key, say) would otherwise fail on the first search.
    try:
        tools = list_tools(spec["mcp"], str(rec["access_token"]))
    except Exception as e:
        raise SearchAuthError("%s signed you in, but its search server refused the token: %s"
                              % (spec["label"], str(e)[:200]))
    if spec["tool"] not in tools:
        raise SearchAuthError("%s signed you in, but its server offers no %s tool (it has: %s)"
                              % (spec["label"], spec["tool"], ", ".join(tools[:8]) or "none"))
    with _Lock(pid):
        _write(creds_path(pid), rec)
    who = (" as " + account) if account else ""
    return {"provider": pid, "account": account,
            "detail": "signed in to %s%s; web_search now uses it" % (spec["label"], who)}


def _forget_tokens(pid: str, rec: dict) -> None:
    # Keep the registration and account: the next sign-in on the same port reuses it.
    keep = {k: rec[k] for k in ("provider", "registration", "account") if rec.get(k)}
    _write(creds_path(pid), keep)


def access_token(pid: str, force_refresh: bool = False) -> str:
    """A live access token, refreshed first when it is about to expire."""
    spec = _spec(pid)
    rec = load_creds(pid)
    if not rec.get("access_token"):
        raise SearchAuthError("not signed in to %s — run `sigil connect %s`" % (spec["label"], pid))
    if not force_refresh and float(rec.get("expires_at") or 0) - time.time() > 60:
        return str(rec["access_token"])
    with _Lock(pid):
        cur = load_creds(pid)
        if not force_refresh and float(cur.get("expires_at") or 0) - time.time() > 60:
            return str(cur["access_token"])
        if force_refresh and str(cur.get("access_token") or "") != str(rec.get("access_token") or ""):
            return str(cur["access_token"])  # another process already refreshed it
        if not cur.get("refresh_token"):
            _forget_tokens(pid, cur)
            raise SearchAuthError("the %s sign-in has expired — run `sigil connect %s`" % (spec["label"], pid))
        tok = _form_post(str(cur["token_endpoint"]), {
            "grant_type": "refresh_token",
            "refresh_token": cur["refresh_token"],
            "client_id": cur["client_id"],
            "resource": cur.get("resource") or spec["mcp"],
        })
        if tok.get("_status") == 200 and tok.get("access_token"):
            out = _save_tokens(cur, tok)
            _write(creds_path(pid), out)
            return str(out["access_token"])
        if str(tok.get("error") or "") in ("invalid_grant", "invalid_client", "unauthorized_client"):
            _forget_tokens(pid, cur)
            raise SearchAuthError("the %s sign-in has expired — run `sigil connect %s`" % (spec["label"], pid))
        raise SearchAuthError("could not refresh the %s sign-in (HTTP %s): %s" % (
            spec["label"], tok.get("_status"), tok.get("error_description") or tok.get("error") or "no reason given"))


def sign_out(pid: str) -> dict:
    """Revoke the renewable session where the provider allows it, then forget it."""
    spec = _spec(pid)
    rec = load_creds(pid)
    if not rec.get("access_token"):
        return {"ok": True, "revoked": False, "detail": "not signed in to " + spec["label"]}
    revoked = False
    url = str(rec.get("revocation_endpoint") or "")
    tokv = str(rec.get("refresh_token") or rec.get("access_token") or "")
    if url and tokv:
        try:
            import httpx
            r = httpx.post(url, data={"token": tokv, "client_id": rec.get("client_id") or "",
                                      "token_type_hint": "refresh_token" if rec.get("refresh_token") else "access_token"},
                           timeout=15.0)
            revoked = r.status_code == 200
        except Exception:
            revoked = False
    with _Lock(pid):
        _forget_tokens(pid, load_creds(pid) or rec)
    return {"ok": True, "revoked": revoked,
            "detail": "signed out of " + spec["label"] if revoked
                      else "signed out here; %s did not confirm the revocation" % spec["label"]}


def auth_status(pid: str) -> dict:
    """{"connected", "account", "detail"} without a network call."""
    rec = load_creds(pid)
    if not rec.get("access_token"):
        return {"connected": False, "account": str(rec.get("account") or ""), "detail": "not signed in"}
    acct = str(rec.get("account") or "")
    return {"connected": True, "account": acct, "detail": "signed in" + ((" as " + acct) if acct else "")}


def signed_in() -> list:
    """The sign-in search providers that hold a token, in SPECS order."""
    return [pid for pid in SPECS if load_creds(pid).get("access_token")]


# ---------------------------------------------------------------------------
# MCP over streamable HTTP: just enough of the protocol for one tool call
# ---------------------------------------------------------------------------
def parse_sse(text: str, want_id) -> dict:
    """The JSON-RPC message with id `want_id` out of an SSE body, or {}."""
    found = {}
    data = []

    def _flush():
        if not data:
            return None
        try:
            m = json.loads("\n".join(data))
        except Exception:
            return None
        return m if isinstance(m, dict) else None

    for line in str(text).splitlines() + [""]:
        if line.startswith("data:"):
            data.append(line[5:].lstrip(" "))
        elif line == "":
            m = _flush()
            data = []
            if m is not None and m.get("id") == want_id:
                found = m
    return found


def _rpc(url: str, headers: dict, payload: dict, timeout: float = 45.0) -> tuple:
    """POST one JSON-RPC message. Returns (reply message or {}, response headers)."""
    import httpx
    r = httpx.post(url, json=payload, headers=headers, timeout=timeout)
    if r.status_code == 401:
        raise McpUnauthorized("HTTP 401")
    if r.status_code >= 400:
        raise RuntimeError("HTTP %d: %s" % (r.status_code, r.text[:200]))
    if "id" not in payload or r.status_code == 202 or not r.content:
        return {}, r.headers
    ct = str(r.headers.get("content-type") or "")
    if "text/event-stream" in ct:
        return parse_sse(r.text, payload["id"]), r.headers
    try:
        msg = r.json()
    except Exception:
        msg = {}
    if isinstance(msg, list):
        msg = next((m for m in msg if isinstance(m, dict) and m.get("id") == payload["id"]), {})
    return (msg if isinstance(msg, dict) else {}), r.headers


def _session(url: str, token: str) -> dict:
    """Initialize an MCP session; the headers every later request carries."""
    h = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
         "User-Agent": "sigil"}
    if token:
        h["Authorization"] = "Bearer " + token
    msg, rh = _rpc(url, h, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": MCP_VERSION, "capabilities": {},
        "clientInfo": {"name": "sigil", "version": "1"}}})
    if msg.get("error"):
        raise RuntimeError("initialize: " + str(msg["error"].get("message") if isinstance(msg["error"], dict) else msg["error"]))
    sid = rh.get("mcp-session-id")
    if sid:
        h["Mcp-Session-Id"] = sid
    h["MCP-Protocol-Version"] = str((msg.get("result") or {}).get("protocolVersion") or MCP_VERSION)
    _rpc(url, h, {"jsonrpc": "2.0", "method": "notifications/initialized"})
    return h


def _close(url: str, h: dict) -> None:
    if not h.get("Mcp-Session-Id"):
        return
    try:
        import httpx
        httpx.delete(url, headers=h, timeout=5.0)
    except Exception:
        pass


def list_tools(url: str, token: str) -> list:
    h = _session(url, token)
    try:
        msg, _ = _rpc(url, h, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    finally:
        _close(url, h)
    if msg.get("error"):
        raise RuntimeError("tools/list: " + str(msg["error"]))
    return [str(t.get("name")) for t in list((msg.get("result") or {}).get("tools") or []) if isinstance(t, dict)]


def mcp_call(url: str, token: str, tool: str, args: dict) -> dict:
    """One MCP tools/call; its result ({"content": [...], ...})."""
    h = _session(url, token)
    try:
        msg, _ = _rpc(url, h, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                               "params": {"name": tool, "arguments": args}}, 60.0)
    finally:
        _close(url, h)
    if msg.get("error"):
        e = msg["error"]
        raise RuntimeError("%s: %s" % (tool, e.get("message") if isinstance(e, dict) else e))
    res = msg.get("result")
    if not isinstance(res, dict):
        raise RuntimeError("%s returned nothing" % tool)
    if res.get("isError"):
        raise RuntimeError("%s: %s" % (tool, _content_text(res)[:200] or "the tool reported an error"))
    return res


def _content_text(res: dict) -> str:
    return "\n".join(str(c.get("text") or "") for c in list(res.get("content") or [])
                     if isinstance(c, dict) and c.get("type") == "text")


def _norm(r: dict) -> dict:
    return {"title": str(r.get("title") or ""),
            "url": str(r.get("url") or r.get("link") or ""),
            "desc": str(r.get("content") or r.get("snippet") or r.get("description") or r.get("text") or "")}


_FIELD = re.compile(r"^(Title|URL|Content|Text|Snippet|Description|Summary|Highlights):\s?(.*)$", re.I)
_OTHER = re.compile(r"^[A-Z][A-Za-z ]{1,30}:(\s|$)")  # "Raw Content:", "Published:" ... end a snippet


def parse_results(res: dict) -> list:
    """[{title, url, desc}] from a search tool's result, whatever shape it takes:
    structured content, a JSON text block, or "Title: / URL: / Content:" text.
    One {"raw": text} item when none of those fit."""
    sc = res.get("structuredContent")
    if isinstance(sc, dict) and isinstance(sc.get("results"), list):
        return [_norm(r) for r in sc["results"] if isinstance(r, dict)]
    text = _content_text(res)
    try:
        j = json.loads(text)
        rows = j.get("results") if isinstance(j, dict) else j
        if isinstance(rows, list) and rows and isinstance(rows[0], dict):
            return [_norm(r) for r in rows]
    except Exception:
        pass
    out = []
    cur = {}
    last = ""
    for line in text.splitlines():
        m = _FIELD.match(line.strip())
        if m:
            k = m.group(1).lower()
            k = {"text": "content", "snippet": "content", "description": "content", "summary": "content", "highlights": "content"}.get(k, k)
            if k == "title" and cur.get("title") is not None and (cur.get("url") or cur.get("content")):
                out.append(cur)
                cur = {}
            if k == "content" and cur.get("content"):
                last = k
                continue  # a later "Raw Content:" or second text field adds nothing to a snippet
            cur[k] = m.group(2).strip()
            last = k
        elif _OTHER.match(line.strip()):
            last = ""
        elif last == "content" and line.strip() and len(cur.get("content", "")) < 400:
            cur["content"] = (cur.get("content", "") + " " + line.strip()).strip()
    if cur.get("url") or cur.get("title"):
        out.append(cur)
    out = [_norm(r) for r in out if r.get("url")]
    if out:
        return out
    return [{"raw": text}] if text.strip() else []


def search(pid: str, query: str, n: int = 6) -> list:
    """Search through a signed-in provider's MCP server, refreshing once on a 401."""
    spec = _spec(pid)
    args = spec["args"](query, n)
    tok = access_token(pid)
    try:
        res = mcp_call(spec["mcp"], tok, spec["tool"], args)
    except McpUnauthorized:
        res = mcp_call(spec["mcp"], access_token(pid, True), spec["tool"], args)
    return parse_results(res)


# ---------------------------------------------------------------------------
# Serper: Google results over a REST API, key only
# ---------------------------------------------------------------------------
def search_serper(query: str, key: str, n: int = 6) -> list:
    import httpx
    r = httpx.post(SERPER_URL, json={"q": query, "num": n},
                   headers={"X-API-KEY": key, "Content-Type": "application/json", "User-Agent": "sigil"},
                   timeout=20.0)
    if r.status_code != 200:
        raise RuntimeError("HTTP %d: %s" % (r.status_code, r.text[:160]))
    body = r.json()
    rows = list((body or {}).get("organic") or [])
    return [{"title": str(x.get("title") or ""), "url": str(x.get("link") or ""),
             "desc": str(x.get("snippet") or "")} for x in rows if isinstance(x, dict)]
::py::
