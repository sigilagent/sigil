"""ChatGPT as a byLLM model — `by llm()` answered on the user's own ChatGPT plan.

OpenAI's Sign in with ChatGPT has a path built for open-source, locally hosted
apps: the app registers itself during the user's first sign-in (no client secret,
no partner key), and the token it gets back calls the public Responses API at
api.openai.com with usage counted against the user's ChatGPT plan. That is the
whole connection — a link, a sign-in, and it works. Reference:
https://developers.openai.com/siwc/token-sharing-open-source

Two halves live here:

- **The credential.** `build_authorize` / `finish_signin` are the provider's side
  of the browser sign-in (`sigil_oauth` runs the loopback listener between them,
  composed in `sigil_connect`). The result is one 0600 record at
  $SIGIL_HOME/auth/chatgpt.json. Access tokens last an hour and refresh tokens
  rotate, so `access_token()` refreshes under a file lock: the CLI, the daemon
  and every compiled-skill subprocess share the record, and two of them racing a
  rotating refresh token would sign the user out.
- **The model.** A litellm handler under the ``chatgpt`` prefix, the same seam
  ``claude-cc`` uses: any tier named ``chatgpt-plan/<model>`` is one streamed
  Responses request. Bound with ``native_tools: False``, so byLLM carries tools
  and output schemas as prose exactly as it does for claude-cc, and the request
  stays inside what plan usage accepts (``store: false``, ``stream: true``, no
  sampling or output-budget fields — see "Preview limitations" in the docs).

Unlike ``claude-cc`` there is no CLI in the loop: no ~16k-token preamble per
call and no process start, which makes this a reasonable execution tier too.

This module reads only the environment and its own files, never another Sigil
module, because a compiled skill's driver imports it top-level
(`import sigil_chatgpt;`) where the package-relative imports do not resolve.
"""

::py::
import base64
import json
import os
import time
import urllib.parse
import uuid

PROVIDER = "chatgpt-plan"
# litellm ships its own `chatgpt/` provider: it borrows the Codex CLI's OAuth client
# for chatgpt.com/backend-api, the route OpenAI tells apps not to use, and litellm
# dispatches it before any custom provider. So Sigil's route has its own prefix,
# and a `chatgpt/...` name is translated here before it can ever reach litellm.
LEGACY_PREFIX = "chatgpt/"
APP_NAME = "Sigil"

ISSUER = "https://auth.openai.com"
AUTHORIZE_URL = ISSUER + "/api/accounts/authorize"
TOKEN_URL = ISSUER + "/api/accounts/oauth/token"
OIDC_CONFIG_URL = ISSUER + "/.well-known/openid-configuration"
RESOURCE = "https://api.openai.com/v1"
RESPONSES_URL = RESOURCE + "/responses"
MODELS_URL = RESOURCE + "/models"
REGISTER_CLIENT = "dynamic_agent_client"
PLAN_SCOPE = "chatgpt.tokens.use.direct"
SCOPES = "openid profile email offline_access resource.invoke " + PLAN_SCOPE
CALLBACK_PATH = "/auth/callback"
USAGE_URL = "https://chatgpt.com/settings/usage"

_INSTALLED = False
_SINK = None


class ChatGPTError(RuntimeError):
    """A ChatGPT plan call or sign-in failed, phrased for the person at the keyboard."""


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------
def _auth_dir() -> str:
    d = os.path.join(os.environ.get("SIGIL_HOME") or os.path.expanduser("~/.sigil"), "auth")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def creds_path() -> str:
    return os.path.join(_auth_dir(), "chatgpt.json")


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


def load_creds() -> dict:
    return _read(creds_path())


def host_id() -> str:
    """This machine's stable, opaque `ext_agent_host_id` — chosen once, before the
    first sign-in, and reused for every later one. Not a credential."""
    path = os.path.join(_auth_dir(), "host_id")
    try:
        with open(path) as f:
            v = f.read().strip()
        if v.startswith("urn:uuid:"):
            return v
    except Exception:
        pass
    v = "urn:uuid:" + str(uuid.uuid4())
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(v + "\n")
    return v


class _Lock:
    """An exclusive lock on the credential file, across processes. Refresh tokens
    rotate: two processes refreshing at once would each spend the same one, and
    the second would be told it was reused."""

    def __enter__(self):
        self._fh = open(os.path.join(_auth_dir(), "chatgpt.lock"), "a+")
        try:
            import fcntl
            fcntl.flock(self._fh.fileno(), fcntl.LOCK_EX)
        except Exception:
            pass  # no fcntl (Windows): fall back to best effort
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
# Sign-in: the provider's half of a sigil_oauth browser flow.
# ---------------------------------------------------------------------------
def _pkce():
    import hashlib
    import secrets
    verifier = secrets.token_urlsafe(64)[:96]
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge.decode("ascii").rstrip("=")


def build_authorize(redirect_uri: str, fresh: bool = False) -> tuple:
    """(authorize URL, context to hand back to finish_signin).

    A first sign-in registers Sigil for this account (`dynamic_agent_client` +
    `agent_name_hint`); later ones reuse the issued client id, so the user is
    not asked to consent again. `fresh` registers anew, for another account.
    """
    import secrets
    saved = {} if fresh else load_creds()
    client_id = str(saved.get("client_id") or "")
    registering = not client_id
    verifier, challenge = _pkce()
    ctx = {
        "state": secrets.token_urlsafe(24),
        "nonce": secrets.token_urlsafe(24),
        "verifier": verifier,
        "redirect_uri": redirect_uri,
        "client_id": REGISTER_CLIENT if registering else client_id,
        "registering": registering,
        "subject": "" if registering else str(saved.get("subject") or ""),
    }
    q = {
        "client_id": ctx["client_id"],
        "ext_agent_host_id": host_id(),
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": SCOPES,
        "resource": RESOURCE,
        "state": ctx["state"],
        "nonce": ctx["nonce"],
        "code_challenge_method": "S256",
        "code_challenge": challenge,
    }
    if registering:
        q["agent_name_hint"] = APP_NAME
    else:
        if saved.get("id_token"):
            q["id_token_hint"] = str(saved["id_token"])
        if saved.get("email"):
            q["login_hint"] = str(saved["email"])
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(q, quote_via=urllib.parse.quote), ctx


def _claims(jwt: str) -> dict:
    # The ID token arrives straight from the token endpoint over TLS, which OIDC
    # Core (3.1.3.7, item 6) accepts in place of checking its signature; the
    # claims below are still checked one by one.
    try:
        part = str(jwt).split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part.encode("ascii")))
    except Exception:
        return {}


def _check_id_token(id_token: str, client_id: str, nonce: str) -> dict:
    c = _claims(id_token)
    if not c:
        raise ChatGPTError("the sign-in returned no readable ID token")
    if str(c.get("iss") or "") != ISSUER:
        raise ChatGPTError("the ID token was issued by %r, not %s" % (c.get("iss"), ISSUER))
    aud = c.get("aud")
    auds = aud if isinstance(aud, list) else [aud]
    if client_id not in [str(a) for a in auds]:
        raise ChatGPTError("the ID token was issued to a different client")
    if float(c.get("exp") or 0) < time.time() - 300:
        raise ChatGPTError("the ID token had already expired")
    if str(c.get("nonce") or "") != nonce:
        raise ChatGPTError("the ID token's nonce does not match this sign-in")
    return c


def _form_post(url: str, form: dict) -> dict:
    import httpx
    r = httpx.post(url, data=form, headers={"Accept": "application/json"}, timeout=30.0)
    try:
        body = r.json()
    except Exception:
        body = {"detail": r.text[:300]}
    if not isinstance(body, dict):
        body = {"detail": str(body)[:300]}
    body["_status"] = r.status_code
    return body


def _save_tokens(rec: dict, tok: dict) -> dict:
    now = time.time()
    rec = dict(rec)
    for k in ("access_token", "refresh_token", "id_token", "token_type"):
        if tok.get(k):
            rec[k] = tok[k]
    expires_in = int(tok.get("expires_in") or 3600)
    rec["expires_in"] = expires_in
    rec["expires_at"] = now + expires_in
    if tok.get("earliest_refresh_at"):
        rec["earliest_refresh_at"] = tok["earliest_refresh_at"]
    if tok.get("scope"):
        rec["scopes"] = sorted(str(tok["scope"]).split())
    rec["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))
    return rec


def finish_signin(params: dict, ctx: dict) -> dict:
    """Trade the callback for a credential, check it, and save it.

    Returns {"provider", "account", "detail", "models"}; raises ChatGPTError with
    the reason otherwise.
    """
    if str(params.get("state") or "") != ctx["state"]:
        raise ChatGPTError("the sign-in came back with the wrong state; start it again")
    if params.get("error"):
        if params["error"] == "access_denied":
            raise ChatGPTError("the sign-in was declined in the browser")
        raise ChatGPTError("ChatGPT refused the sign-in: %s" % (params.get("error_description") or params["error"]))
    code = str(params.get("code") or "")
    if not code:
        raise ChatGPTError("the browser came back without a sign-in code")
    issued = str(params.get("client_id") or "")
    if ctx["registering"]:
        if not issued:
            raise ChatGPTError("ChatGPT did not finish registering Sigil (no client id came back); start it again")
        client_id = issued
    else:
        client_id = ctx["client_id"]
        if issued and issued != client_id:
            raise ChatGPTError("the sign-in came back for a different registration; nothing was changed")
    tok = _form_post(TOKEN_URL, {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": code,
        "code_verifier": ctx["verifier"],
        "redirect_uri": ctx["redirect_uri"],
        "resource": RESOURCE,
    })
    if tok.get("_status") != 200 or not tok.get("access_token"):
        why = tok.get("error_description") or tok.get("error") or tok.get("detail") or ("HTTP %s" % tok.get("_status"))
        raise ChatGPTError("ChatGPT would not exchange the sign-in code: %s" % why)
    claims = _check_id_token(str(tok.get("id_token") or ""), client_id, ctx["nonce"])
    subject = str(claims.get("sub") or "")
    if ctx.get("subject") and subject != ctx["subject"]:
        raise ChatGPTError("that sign-in was a different ChatGPT account than the one Sigil is registered with; "
                           "to switch accounts run `sigil connect chatgpt --new`")
    rec = _save_tokens({
        "email": str(claims.get("email") or ""),
        "issuer": ISSUER,
        "subject": subject,
        "client_id": client_id,
        "ext_agent_host_id": host_id(),
    }, tok)
    rec["plan_enabled"] = PLAN_SCOPE in rec.get("scopes", [])
    with _Lock():
        _write(creds_path(), rec)
    if not rec["plan_enabled"]:
        raise ChatGPTError("you are signed in as %s, but using your ChatGPT plan was not allowed. "
                           "Run `sigil connect chatgpt` again and allow it, or connect another provider"
                           % (rec["email"] or "your account"))
    models = []
    try:
        models = refresh_models()
    except Exception:
        models = []
    return {"provider": PROVIDER, "account": rec["email"], "models": [m["slug"] for m in models],
            "detail": "signed in as %s" % (rec["email"] or "your ChatGPT account")}


def _terminal(msg: str):
    """An error no retry will fix: raised as litellm's AuthenticationError, which
    byLLM does not retry, so the user reads one sentence instead of three dumps."""
    try:
        from litellm.exceptions import AuthenticationError
        return AuthenticationError(message="chatgpt: " + msg, llm_provider=PROVIDER, model=PROVIDER)
    except Exception:
        return ChatGPTError("chatgpt: " + msg)


def _signed_out(rec: dict) -> None:
    # Keep the account/client mapping and the host id: a later sign-in reuses them.
    keep = {k: rec[k] for k in ("email", "issuer", "subject", "client_id", "ext_agent_host_id") if rec.get(k)}
    keep["models"] = rec.get("models") or []
    _write(creds_path(), keep)


def _refresh_locked(rec: dict) -> dict:
    tok = _form_post(TOKEN_URL, {
        "grant_type": "refresh_token",
        "client_id": rec["client_id"],
        "refresh_token": rec["refresh_token"],
        "resource": RESOURCE,
    })
    if tok.get("_status") == 200 and tok.get("access_token"):
        out = _save_tokens(rec, tok)
        out["plan_enabled"] = PLAN_SCOPE in out.get("scopes", [])
        _write(creds_path(), out)
        return out
    code = str(tok.get("error") or tok.get("code") or "")
    unusable = ("invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused")
    if code in unusable:
        _signed_out(rec)
        raise _terminal("the ChatGPT sign-in has expired — run `sigil connect chatgpt` to sign in again")
    if code == "invalid_client":
        raise _terminal("ChatGPT no longer recognises Sigil's registration — run `sigil connect chatgpt --new`")
    raise ChatGPTError("chatgpt: could not refresh the sign-in (%s): %s"
                       % (tok.get("_status"), tok.get("error_description") or tok.get("detail") or code or "no reason given"))


def access_token(force_refresh: bool = False) -> str:
    """A live access token, refreshed first if it is about to expire."""
    rec = load_creds()
    if not rec.get("refresh_token") and not rec.get("access_token"):
        raise _terminal("not signed in to ChatGPT — run `sigil connect chatgpt`")
    if rec.get("plan_enabled") is False:
        raise _terminal("using your ChatGPT plan is not allowed for Sigil — run `sigil connect chatgpt` and allow it")
    if not force_refresh and float(rec.get("expires_at") or 0) - time.time() > 120:
        return str(rec["access_token"])
    with _Lock():
        # Another process may have refreshed while this one waited for the lock.
        cur = load_creds()
        if not force_refresh and float(cur.get("expires_at") or 0) - time.time() > 120:
            return str(cur["access_token"])
        if force_refresh and str(cur.get("access_token") or "") != str(rec.get("access_token") or ""):
            return str(cur["access_token"])
        if not cur.get("refresh_token"):
            raise _terminal("the ChatGPT sign-in has expired — run `sigil connect chatgpt` to sign in again")
        return str(_refresh_locked(cur)["access_token"])


def sign_out() -> dict:
    """Revoke the renewable session, then forget the tokens (keeping the mapping)."""
    rec = load_creds()
    if not rec.get("refresh_token"):
        if rec:
            _signed_out(rec)
        return {"ok": True, "revoked": False, "detail": "not signed in"}
    revoked = False
    try:
        import httpx
        cfg = httpx.get(OIDC_CONFIG_URL, timeout=10.0).json()
        url = str(cfg.get("revocation_endpoint") or "")
        if url:
            r = httpx.post(url, data={"token": rec["refresh_token"], "token_type_hint": "refresh_token",
                                      "client_id": rec["client_id"]}, timeout=15.0)
            revoked = r.status_code == 200
    except Exception:
        revoked = False
    with _Lock():
        _signed_out(load_creds() or rec)
    detail = "signed out" if revoked else ("signed out here, but ChatGPT did not confirm the revocation — "
                                           "you can disconnect Sigil in ChatGPT settings")
    return {"ok": True, "revoked": revoked, "detail": detail}


def refresh_models() -> list:
    """The signed-in account's model catalog, in the server's order."""
    import httpx
    r = httpx.get(MODELS_URL, headers={"Authorization": "Bearer " + access_token()}, timeout=20.0)
    if r.status_code != 200:
        raise ChatGPTError("chatgpt: the model list was refused (HTTP %d)" % r.status_code)
    body = r.json()
    rows = body.get("models") if isinstance(body, dict) else None
    if rows is None and isinstance(body, dict):
        rows = body.get("data") or []
    out = []
    for m in rows or []:
        if not isinstance(m, dict):
            continue
        if m.get("visibility") not in (None, "list"):
            continue
        slug = str(m.get("slug") or m.get("id") or "")
        if slug:
            out.append({"slug": slug, "display_name": str(m.get("display_name") or slug)})
    with _Lock():
        rec = load_creds()
        rec["models"] = out
        _write(creds_path(), rec)
    return out


def auth_status() -> dict:
    """What a `chatgpt-plan/...` tier would run on, without a network call.

    {"mode": "plan" | "disabled" | "none", "account": email, "models": [slugs]}
    """
    rec = load_creds()
    models = [str(m.get("slug")) for m in (rec.get("models") or []) if isinstance(m, dict)]
    if not rec.get("refresh_token"):
        return {"mode": "none", "account": str(rec.get("email") or ""), "models": models}
    if rec.get("plan_enabled") is False:
        return {"mode": "disabled", "account": str(rec.get("email") or ""), "models": models}
    return {"mode": "plan", "account": str(rec.get("email") or ""), "models": models}


# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------
def is_chatgpt(model_name: str) -> bool:
    """True for a model string this provider owns (`chatgpt-plan/...`, or the
    `chatgpt/...` spelling that plan_model translates)."""
    n = str(model_name or "")
    return n.startswith(PROVIDER + "/") or n.startswith(LEGACY_PREFIX)


def plan_model(model_name: str) -> str:
    """The name to hand litellm: `chatgpt/x` becomes `chatgpt-plan/x`."""
    n = str(model_name or "")
    return PROVIDER + "/" + n[len(LEGACY_PREFIX):] if n.startswith(LEGACY_PREFIX) else n


def _slug(model: str) -> str:
    """`chatgpt-plan/gpt-x` -> `gpt-x`; `default` is the first model in the catalog."""
    name = str(model or "")
    if name.startswith(PROVIDER + "/"):
        name = name[len(PROVIDER) + 1:]
    elif name.startswith(LEGACY_PREFIX):
        name = name[len(LEGACY_PREFIX):]
    if name in ("", "default"):
        st = auth_status()
        if not st["models"]:
            try:
                refresh_models()
            except Exception:
                pass
            st = auth_status()
        if not st["models"]:
            raise _terminal("no models are listed for this ChatGPT account — name one, e.g. `chatgpt-plan/<model>`")
        name = st["models"][0]
    return name


def set_stream_sink(fn) -> None:
    """Route every delta to `fn(kind, text)`, as sigil_claude_cc does. None turns it off."""
    global _SINK
    _SINK = fn


def _emit(kind: str, text: str) -> None:
    if _SINK is None or not text:
        return
    try:
        _SINK(kind, text)
    except Exception:
        pass


def _text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(p.get("text", "")) for p in content
                         if isinstance(p, dict) and p.get("type") == "text" and p.get("text"))
    return str(content)


def _parts(content) -> list:
    if isinstance(content, str) or content is None:
        t = content or ""
        return [{"type": "input_text", "text": t}] if t else []
    out = []
    for p in content if isinstance(content, list) else [content]:
        if not isinstance(p, dict):
            out.append({"type": "input_text", "text": str(p)})
        elif p.get("type") == "text" and p.get("text"):
            out.append({"type": "input_text", "text": str(p["text"])})
        elif p.get("type") == "image_url":
            iu = p.get("image_url")
            url = iu.get("url") if isinstance(iu, dict) else iu
            if url:
                out.append({"type": "input_image", "image_url": str(url)})
    return out


def _tool_calls_text(msg: dict) -> str:
    # Replay an earlier turn's tool calls in the <tool_call> form byLLM asked for.
    out = []
    for t in msg.get("tool_calls") or []:
        fn = (t.get("function") if isinstance(t, dict) else getattr(t, "function", None)) or {}
        get = (lambda k: fn.get(k) if isinstance(fn, dict) else getattr(fn, k, None))
        out.append('<tool_call>{"name": %s, "arguments": %s}</tool_call>'
                   % (json.dumps(str(get("name") or "")), str(get("arguments") or "{}")))
    return "\n".join(out)


def build_request(model: str, messages: list) -> dict:
    """OpenAI chat messages -> one plan-usage Responses request body.

    System messages become `instructions`: plan usage rejects system-role input
    items. Tool results ride as user text, since this tier declares no native
    tools and byLLM already speaks its tool protocol in prose.
    """
    instructions = []
    items = []
    for raw in messages or []:
        msg = raw if isinstance(raw, dict) else {
            "role": getattr(raw, "role", "user"),
            "content": getattr(raw, "content", str(raw)),
            "tool_calls": getattr(raw, "tool_calls", None),
        }
        role = str(msg.get("role") or "user")
        if role in ("system", "developer"):
            t = _text(msg.get("content"))
            if t:
                instructions.append(t)
        elif role == "assistant":
            body = (_text(msg.get("content")) + "\n" + _tool_calls_text(msg)).strip()
            if body:
                items.append({"role": "assistant", "content": body})
        elif role in ("tool", "function"):
            t = _text(msg.get("content"))
            if t:
                items.append({"role": "user", "content": [{"type": "input_text", "text": "[TOOL RESULT]\n" + t}]})
        else:
            parts = _parts(msg.get("content"))
            if parts:
                items.append({"role": "user", "content": parts})
    body = {"model": model, "input": items, "store": False, "stream": True}
    if instructions:
        body["instructions"] = "\n\n".join(instructions)
    if not items:
        body["input"] = [{"role": "user", "content": [{"type": "input_text", "text": body.pop("instructions", "")}]}]
    effort = (os.environ.get("SIGIL_CHATGPT_EFFORT") or "").strip()
    if effort:
        body["reasoning"] = {"effort": effort}
    return body


# Codes with a fixed meaning (errors-and-recovery in the reference): each is
# something the user must act on, so none of them is worth a retry.
_CODES = {
    "subscription_sharing_usage_limit_exceeded":
        "your ChatGPT plan's usage limit for Sigil is reached — see " + USAGE_URL,
    "subscription_sharing_user_not_eligible":
        "this ChatGPT account or workspace cannot use its plan in other apps",
    "subscription_sharing_invalid_user":
        "ChatGPT could not validate the signed-in account — run `sigil connect chatgpt` to sign in again",
    "chatpass_v2_scope_not_authorized":
        "the ChatGPT sign-in does not allow this request — run `sigil connect chatgpt` and allow plan use",
    "chatpass_v2_invalid_authorization_context":
        "the ChatGPT sign-in does not allow this request — run `sigil connect chatgpt` and allow plan use",
    "model_not_found":
        "that model is not offered to this ChatGPT account (404) — `sigil connections` lists the ones that are",
}


def _fail(status: int, body) -> Exception:
    err = body.get("error") if isinstance(body, dict) else None
    code = str((err or {}).get("code") or "") if isinstance(err, dict) else ""
    msg = str((err or {}).get("message") or "") if isinstance(err, dict) else ""
    if not msg and isinstance(body, dict):
        msg = str(body.get("detail") or "")
    if code in _CODES:
        return _terminal(_CODES[code])
    if code == "subscription_sharing_unsupported_capability":
        return _terminal("plan usage does not support part of this request (%s)" % ((err or {}).get("param") or msg))
    if status == 401:
        return _terminal("ChatGPT did not accept the sign-in (401) — run `sigil connect chatgpt`")
    if status == 403:
        return _terminal("ChatGPT refused this request (403): %s" % (msg or "a policy or region restriction"))
    return ChatGPTError("chatgpt: the request failed (HTTP %s%s): %s"
                        % (status, (", " + code) if code else "", (msg or "no reason given")[:300]))


def _events(resp):
    """Server-sent events -> parsed JSON objects."""
    data = []
    for line in resp.iter_lines():
        if line is None:
            continue
        if line == "":
            if data:
                raw = "\n".join(data)
                data = []
                if raw.strip() == "[DONE]":
                    return
                try:
                    yield json.loads(raw)
                except Exception:
                    continue
            continue
        if line.startswith("data:"):
            data.append(line[5:].lstrip())
    if data:
        try:
            yield json.loads("\n".join(data))
        except Exception:
            return


def _final_text(response: dict) -> str:
    out = []
    for item in (response or {}).get("output") or []:
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        for c in item.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "output_text":
                out.append(str(c.get("text") or ""))
    return "".join(out)


def consume(events) -> dict:
    """Fold a Responses event stream into {"text", "usage", "finish", "id"}.

    Only `response.completed` is success. `response.incomplete` keeps what was
    written and reports it as truncated; a failure raises.
    """
    deltas = []
    for ev in events:
        kind = str(ev.get("type") or "")
        if kind == "response.output_text.delta":
            d = str(ev.get("delta") or "")
            deltas.append(d)
            _emit("text", d)
        elif kind in ("response.reasoning_summary_text.delta", "response.reasoning_text.delta"):
            _emit("thinking", str(ev.get("delta") or ""))
        elif kind == "response.completed":
            r = ev.get("response") or {}
            return {"text": _final_text(r) or "".join(deltas), "usage": r.get("usage") or {},
                    "finish": "stop", "id": str(r.get("id") or "")}
        elif kind == "response.incomplete":
            r = ev.get("response") or {}
            text = _final_text(r) or "".join(deltas)
            if not text:
                why = (r.get("incomplete_details") or {}).get("reason") or "no reason given"
                raise ChatGPTError("chatgpt: the reply stopped before it began (%s)" % why)
            return {"text": text, "usage": r.get("usage") or {}, "finish": "length", "id": str(r.get("id") or "")}
        elif kind == "response.failed":
            r = ev.get("response") or {}
            raise _fail(0, {"error": r.get("error") or {}})
        elif kind == "error":
            raise _fail(int(ev.get("status") or 0), {"error": {"code": ev.get("code"), "message": ev.get("message")}})
    raise ChatGPTError("chatgpt: the stream ended before the reply was complete — try again")


def _stream(body: dict) -> dict:
    import httpx
    timeout = httpx.Timeout(30.0, read=None)
    for attempt in (0, 1):
        token = access_token(force_refresh=(attempt == 1))
        headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json",
                   "Accept": "text/event-stream"}
        with httpx.stream("POST", RESPONSES_URL, json=body, headers=headers, timeout=timeout) as r:
            if r.status_code == 401 and attempt == 0:
                continue  # the token may have been revoked early: refresh once and retry
            if r.status_code != 200:
                r.read()
                try:
                    parsed = r.json()
                except Exception:
                    parsed = {"detail": r.text[:300]}
                raise _fail(r.status_code, parsed)
            return consume(_events(r))
    raise _terminal("ChatGPT did not accept the sign-in (401) — run `sigil connect chatgpt`")


def _response(model: str, out: dict):
    from litellm.types.utils import Choices, Message, ModelResponse, Usage
    u = out.get("usage") or {}
    prompt_tokens = int(u.get("input_tokens") or 0)
    completion_tokens = int(u.get("output_tokens") or 0)
    cached = int(((u.get("input_tokens_details") or {}).get("cached_tokens")) or 0)
    resp = ModelResponse(
        id="chatgpt-%s" % (out.get("id") or uuid.uuid4().hex),
        created=int(time.time()),
        model="%s/%s" % (PROVIDER, model),
        object="chat.completion",
        choices=[Choices(finish_reason=out.get("finish") or "stop", index=0,
                         message=Message(content=out.get("text") or "", role="assistant"))],
        usage=Usage(prompt_tokens=prompt_tokens, completion_tokens=completion_tokens,
                    total_tokens=prompt_tokens + completion_tokens, cache_read_input_tokens=cached),
    )
    try:
        # Included in the plan: there is no per-call bill to report.
        resp._hidden_params = {"response_cost": 0.0}
    except Exception:
        pass
    return resp


def _call(model: str, messages: list):
    slug = _slug(model)
    return _response(slug, _stream(build_request(slug, messages)))


def _chunk(resp) -> dict:
    usage = resp.usage
    return {
        "text": resp.choices[0].message.content or "",
        "tool_use": None,
        "is_finished": True,
        "finish_reason": resp.choices[0].finish_reason or "stop",
        "index": 0,
        "usage": {"prompt_tokens": usage.prompt_tokens, "completion_tokens": usage.completion_tokens,
                  "total_tokens": usage.total_tokens},
    }


def install() -> bool:
    """Register the `chatgpt` provider with litellm. Idempotent."""
    global _INSTALLED
    if _INSTALLED:
        return True
    try:
        import asyncio
        import litellm
        from litellm import CustomLLM
        from litellm.utils import custom_llm_setup
    except Exception:
        return False

    class ChatGPTHandler(CustomLLM):
        def completion(self, *args, **kwargs):
            return _call(kwargs.get("model", ""), kwargs.get("messages") or [])

        async def acompletion(self, *args, **kwargs):
            return await asyncio.to_thread(_call, kwargs.get("model", ""), kwargs.get("messages") or [])

        def streaming(self, *args, **kwargs):
            yield _chunk(_call(kwargs.get("model", ""), kwargs.get("messages") or []))

        async def astreaming(self, *args, **kwargs):
            yield _chunk(await asyncio.to_thread(_call, kwargs.get("model", ""), kwargs.get("messages") or []))

    existing = [x for x in (litellm.custom_provider_map or []) if x.get("provider") != PROVIDER]
    litellm.custom_provider_map = existing + [{"provider": PROVIDER, "custom_handler": ChatGPTHandler()}]
    custom_llm_setup()
    _INSTALLED = True
    return True
::py::
