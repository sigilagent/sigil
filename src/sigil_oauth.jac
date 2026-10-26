"""Browser sign-in plumbing shared by every provider that connects through a link.

A connection that "gives you a link, you sign in, it works" is the same three
moves whichever provider is on the other end: start a one-shot listener on a
loopback port, send the browser to the provider's authorize page with that port
as the callback, and trade the code the browser comes back with for a credential.
The provider-specific parts are the URL and the trade (`sigil_chatgpt`,
`sigil_connect` for OpenRouter); this module is everything else.

    url, ctx = build(redirect_uri)        # provider: the authorize URL
    params   = <browser returns here>     # this module: the loopback listener
    result   = finish(params, ctx)        # provider: code -> credential

`browser_flow` runs that in the foreground for the CLI. `start_flow` runs it on a
thread and records its progress in a file under $SIGIL_HOME/auth/flows, so the
Observatory can open the link in a tab and poll for the outcome from whichever
request happens to ask.

The page the browser lands on waits for `finish` before it renders, so it says
whether the sign-in actually completed — not merely that a code arrived.

Pure stdlib, in a ``::py::`` block like the other runtime-manipulation modules:
an HTTP server and a thread are Python objects first.
"""

::py::
import base64
import hashlib
import html
import http.server
import json
import os
import secrets
import threading
import time
import urllib.parse
import uuid
import webbrowser


class OAuthError(RuntimeError):
    """A sign-in that did not produce a credential, in one sentence for the user."""


def auth_dir() -> str:
    """$SIGIL_HOME/auth, created 0700. Every connection's credential lives here."""
    d = os.path.join(os.environ.get("SIGIL_HOME") or os.path.expanduser("~/.sigil"), "auth")
    os.makedirs(d, mode=0o700, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except Exception:
        pass
    return d


def random_token(n: int = 32) -> str:
    return secrets.token_urlsafe(n)


def pkce_pair() -> tuple:
    """(verifier, S256 challenge): base64url without padding, as RFC 7636 asks."""
    verifier = secrets.token_urlsafe(64)[:96]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


def write_private(path: str, data: dict) -> None:
    """Atomic JSON write, readable by the owner alone (0600)."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path: str) -> dict:
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


_PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>Sigil</title>
<style>body{font:15px/1.5 system-ui,sans-serif;background:#0f1115;color:#e6e6e6;
display:grid;place-items:center;height:100vh;margin:0}main{max-width:420px;padding:24px}
h1{font-size:18px;margin:0 0 8px}p{color:#a0a4ad;margin:0}</style></head>
<body><main><h1>%s</h1><p>%s</p></main></body></html>"""


class Callback:
    """A one-shot HTTP listener on 127.0.0.1 for an OAuth redirect.

    Binds an ephemeral port unless one is named. Requests to any other path (a
    favicon, a prefetch) get a 404 and the wait goes on.
    """

    def __init__(self, path: str, port: int = 0):
        self.path = path
        self.params = None
        self._got = threading.Event()
        self._done = threading.Event()
        self._outcome = (True, "")
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path != outer.path:
                    self.send_response(404)
                    self.end_headers()
                    return
                if outer.params is None:
                    q = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
                    outer.params = {k: (v[0] if v else "") for k, v in q.items()}
                    outer._got.set()
                # Render the real outcome: hold the page until finish() has run.
                outer._done.wait(60)
                ok, msg = outer._outcome
                title = "Sigil is connected" if ok else "Sign-in did not complete"
                body = msg or ("You can close this tab and go back to Sigil." if ok else "Go back to Sigil for details.")
                page = (_PAGE % (html.escape(title), html.escape(body))).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(page)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(page)

            def log_message(self, *args):
                pass  # the terminal belongs to Sigil, not to an access log

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), Handler)
        self._server.daemon_threads = True
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def start(self) -> "Callback":
        self._thread.start()
        return self

    def uri(self, host: str = "127.0.0.1") -> str:
        return "http://%s:%d%s" % (host, self.port, self.path)

    def wait(self, timeout: float):
        """The callback's query parameters, or None if the browser never came back."""
        self._got.wait(timeout)
        return self.params

    def complete(self, ok: bool, message: str = "") -> None:
        self._outcome = (bool(ok), str(message or ""))
        self._done.set()

    def close(self) -> None:
        self._done.set()
        # Give the held page a moment to flush before the socket goes away.
        time.sleep(0.2)
        try:
            self._server.shutdown()
            self._server.server_close()
        except Exception:
            pass


def _run(cb: "Callback", build, finish, host: str, timeout: float, on_url) -> dict:
    url, ctx = build(cb.uri(host))
    if on_url is not None:
        on_url(url)
    params = cb.wait(timeout)
    if params is None:
        cb.complete(False, "Sigil stopped waiting for this sign-in.")
        raise OAuthError("no sign-in arrived within %d minutes — run it again when you are ready" % int(timeout / 60))
    try:
        result = finish(params, ctx)
    except Exception as e:
        cb.complete(False, str(e))
        raise
    cb.complete(True, "")
    return result


def browser_flow(build, finish, path: str, host: str = "127.0.0.1", timeout: float = 600,
                 on_url=None, open_browser: bool = True) -> dict:
    """Run one sign-in in the foreground. Returns whatever `finish` returns.

    `build(redirect_uri) -> (url, ctx)`; `finish(params, ctx) -> dict`. `on_url`
    sees the link first, so a terminal can print it for a browser on another
    machine (or when opening one fails).
    """
    cb = Callback(path).start()
    try:
        def _shown(url):
            if on_url is not None:
                on_url(url)
            if open_browser:
                try:
                    webbrowser.open(url)
                except Exception:
                    pass
        return _run(cb, build, finish, host, timeout, _shown)
    finally:
        cb.close()


# ---------------------------------------------------------------------------
# Background flows, for the Observatory: start one, hand the page the link, and
# let the page poll. State lives in a file so any process can answer the poll.
# ---------------------------------------------------------------------------
def _flows_dir() -> str:
    d = os.path.join(auth_dir(), "flows")
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def _flow_path(fid: str) -> str:
    safe = "".join(ch for ch in str(fid) if ch.isalnum() or ch == "-")
    return os.path.join(_flows_dir(), safe + ".json")


def _flow_write(fid: str, data: dict) -> None:
    write_private(_flow_path(fid), data)


def start_flow(provider: str, build, finish, path: str, host: str = "127.0.0.1",
               timeout: float = 600) -> dict:
    """Start a sign-in on a thread. Returns {"id", "url"} at once."""
    fid = uuid.uuid4().hex
    cb = Callback(path).start()
    holder = {}
    ready = threading.Event()

    def _on_url(url):
        holder["url"] = url
        _flow_write(fid, {"id": fid, "provider": provider, "state": "waiting", "url": url,
                          "detail": "", "started": time.time()})
        ready.set()

    def _go():
        try:
            out = _run(cb, build, finish, host, timeout, _on_url)
            _flow_write(fid, {"id": fid, "provider": provider, "state": "ok", "url": holder.get("url", ""),
                              "detail": str((out or {}).get("detail") or ""), "result": _public(out),
                              "started": time.time()})
        except Exception as e:
            _flow_write(fid, {"id": fid, "provider": provider, "state": "error", "url": holder.get("url", ""),
                              "detail": str(e)[:400], "started": time.time()})
        finally:
            ready.set()
            cb.close()

    threading.Thread(target=_go, daemon=True).start()
    ready.wait(30)
    return {"id": fid, "url": holder.get("url", "")}


def _public(out) -> dict:
    # A flow file is read back by the browser: never let a credential into it.
    if not isinstance(out, dict):
        return {}
    keep = ("provider", "account", "detail", "models")
    return {k: out[k] for k in keep if k in out}


def flow_status(fid: str) -> dict:
    d = read_json(_flow_path(fid))
    if not d:
        return {"id": fid, "state": "unknown", "detail": "no such sign-in"}
    return d
::py::
