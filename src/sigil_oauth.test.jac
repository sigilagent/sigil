# Tests for sigil_oauth — annex of sigil_oauth.jac
# (`jac test src/sigil_oauth.jac`). The listener tests are real HTTP over
# 127.0.0.1 and never leave the machine; nothing opens a browser.

import os;
import json;
import time;
import base64;
import hashlib;
import tempfile;
import threading;
import urllib.request;

glob _GOT: dict[str, any] = {};

def _hit(url: str) {
    # What a browser does on the redirect: a favicon first, then the callback.
    time.sleep(0.2);
    try { urllib.request.urlopen(url.split("?")[0].rsplit("/", 1)[0] + "/favicon.ico"); }
    except Exception as e { _GOT["favicon"] = str(e); }
    try { _GOT["page"] = urllib.request.urlopen(url).read().decode(); }
    except Exception as e { _GOT["page"] = "error: " + str(e); }
}

def _build(redirect: str) -> any {
    threading.Thread(target=_hit, args=(redirect + "?code=abc&state=s1",), daemon=True).start();
    return ("https://provider.invalid/authorize", {"state": "s1"});
}

def _finish_ok(params: any, ctx: any) -> any {
    if str(params["state"]) != str(ctx["state"]) { raise OAuthError("state"); }
    return {"provider": "test", "detail": "done " + str(params["code"]), "token": "NEVER-IN-A-FLOW-FILE"};
}

def _finish_bad(params: any, ctx: any) -> any { raise OAuthError("the exchange broke"); }

test "pkce_pair: S256 challenge of the verifier, unpadded" {
    pair: any = pkce_pair();
    v = str(pair[0]);
    expect = base64.urlsafe_b64encode(hashlib.sha256(v.encode("ascii")).digest()).decode().rstrip("=");
    assert str(pair[1]) == expect;
    assert (len(v) >= 43) and (len(v) <= 128);
    assert "=" not in str(pair[1]);
}

test "browser_flow: the callback's parameters reach finish, and the page says it worked" {
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp(prefix="sigil-oauth-");
    _GOT.clear();
    out: any = browser_flow(_build, _finish_ok, "/cb", "127.0.0.1", 10, None, False);
    assert str(out["detail"]) == "done abc";
    time.sleep(0.3);
    assert "Sigil is connected" in str(_GOT.get("page") or "");
    assert "404" in str(_GOT.get("favicon") or "");   # other paths are not the callback
}

test "browser_flow: a failed exchange raises, and the page says so" {
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp(prefix="sigil-oauth-");
    _GOT.clear();
    msg = "";
    try { browser_flow(_build, _finish_bad, "/cb", "127.0.0.1", 10, None, False); }
    except OAuthError as e { msg = str(e); }
    assert msg == "the exchange broke";
    time.sleep(0.3);
    assert "did not complete" in str(_GOT.get("page") or "");
}

test "start_flow: the outcome is pollable, and no credential is written into it" {
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp(prefix="sigil-oauth-");
    _GOT.clear();
    f: any = start_flow("test", _build, _finish_ok, "/cb");
    assert str(f["url"]).startswith("https://provider.invalid/");
    st: any = {};
    for i in range(50) {
        st = flow_status(str(f["id"]));
        if str(st["state"]) != "waiting" { break; }
        time.sleep(0.1);
    }
    assert str(st["state"]) == "ok";
    assert "NEVER-IN-A-FLOW-FILE" not in json.dumps(st);
    assert str(dict(st["result"])["detail"]) == "done abc";
}

test "flow_status: an unknown flow is reported, not raised" {
    assert str(flow_status("nope")["state"]) == "unknown";
}

test "write_private: owner-only" {
    d = tempfile.mkdtemp(prefix="sigil-oauth-");
    p = os.path.join(d, "x.json");
    write_private(p, {"a": 1});
    assert (os.stat(p).st_mode & 0o777) == 0o600;
    assert int(read_json(p)["a"]) == 1;
}
