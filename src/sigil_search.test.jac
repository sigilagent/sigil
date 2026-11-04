# Tests for sigil_search — annex of sigil_search.jac
# (`jac test src/sigil_search.jac`). Offline: no sign-in, no search, no network.
# The parsing tests use the result shapes Tavily's and Exa's MCP servers return.

import os;
import json;
import time;
import tempfile;
import urllib.parse;

def _home() -> str {
    d = tempfile.mkdtemp();
    os.environ["SIGIL_HOME"] = d;
    return d;
}

test "parse_sse: picks the reply with the asked-for id" {
    body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
           + "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":1}}\n\n";
    m: dict[str, any] = dict(parse_sse(body, 2));
    assert m["result"]["ok"] == 1, str(m);
    assert dict(parse_sse(body, 9)) == {};
}

test "parse_results: Tavily's Title/URL/Content text, raw content left out" {
    txt = "Detailed Results:\n\nTitle: Jac\nURL: https://jaclang.org\nContent: The Jac language.\nRaw Content: lots of page\n\n"
          + "Title: Sigil\nURL: https://sigilagent.com\nContent: A skill compiler.";
    items: list[any] = list(parse_results({"content": [{"type": "text", "text": txt}]}));
    assert len(items) == 2, str(items);
    assert items[0] == {"title": "Jac", "url": "https://jaclang.org", "desc": "The Jac language."}, str(items[0]);
    assert items[1]["url"] == "https://sigilagent.com";
}

test "parse_results: Exa's Highlights block becomes the snippet" {
    txt = "Title: The Jac Programming Language\nURL: https://jaclang.org/\nPublished: N/A\nAuthor: Jaseci Labs\nHighlights:\nOne universal language\nAgents built in\n\n"
          + "Title: jac\nURL: https://github.com/jaseci-labs/jac\nHighlights:\nThe repo";
    items: list[any] = list(parse_results({"content": [{"type": "text", "text": txt}]}));
    assert len(items) == 2, str(items);
    assert "One universal language" in items[0]["desc"], str(items[0]);
    assert "Jaseci Labs" not in items[0]["desc"];
}

test "parse_results: JSON text, structured content, and prose" {
    j = json.dumps({"results": [{"title": "A", "url": "u", "content": "c"}]});
    assert list(parse_results({"content": [{"type": "text", "text": j}]})) == [{"title": "A", "url": "u", "desc": "c"}];
    sc = {"structuredContent": {"results": [{"title": "B", "link": "l", "snippet": "s"}]}};
    assert list(parse_results(sc)) == [{"title": "B", "url": "l", "desc": "s"}];
    assert list(parse_results({"content": [{"type": "text", "text": "no fields here"}]})) == [{"raw": "no fields here"}];
    assert list(parse_results({"content": []})) == [];
}

test "authorize_url: PKCE S256, the MCP resource, and the scope" {
    meta = {"authorization_endpoint": "https://as.example/authorize", "resource": "https://mcp.example/mcp"};
    u = str(authorize_url(meta, "cid", "http://127.0.0.1:5555/callback", "openid offline_access", "st", "ch"));
    q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(u).query));
    assert u.startswith("https://as.example/authorize?");
    assert q["response_type"] == "code" and q["client_id"] == "cid";
    assert q["code_challenge"] == "ch" and q["code_challenge_method"] == "S256";
    assert q["resource"] == "https://mcp.example/mcp";
    assert q["redirect_uri"] == "http://127.0.0.1:5555/callback";
    assert q["scope"] == "openid offline_access" and q["state"] == "st";
}

test "finish_signin: refuses a wrong state, an error, and a missing code" {
    ctx = {"state": "s1", "meta": {"issuer": "https://as.example/"}, "redirect_uri": "r", "client_id": "c", "verifier": "v"};
    for bad in [{"state": "nope", "code": "x"}, {"error": "access_denied", "state": "s1"}, {"state": "s1"},
                {"state": "s1", "code": "x", "iss": "https://evil.example/"}] {
        raised = False;
        try { finish_signin("tavily", bad, ctx); } except SearchAuthError as e { raised = True; }
        assert raised, str(bad);
    }
}

test "credential record: status, expiry and sign-out without the network" {
    prev = os.environ.get("SIGIL_HOME");
    _home();
    assert dict(auth_status("tavily"))["connected"] == False;
    assert list(signed_in()) == [];
    raised = False;
    try { access_token("tavily"); } except SearchAuthError as e { raised = "sigil connect tavily" in str(e); }
    assert raised;
    _write(str(creds_path("tavily")), {"provider": "tavily", "access_token": "AT", "client_id": "c",
                                  "registration": {"client_id": "c"}, "account": "me@example.com",
                                  "expires_at": time.time() + 3600});
    assert (os.stat(str(creds_path("tavily"))).st_mode & 0o777) == 0o600;
    st: dict[str, any] = dict(auth_status("tavily"));
    assert st["connected"] and st["account"] == "me@example.com", str(st);
    assert list(signed_in()) == ["tavily"];
    assert str(access_token("tavily")) == "AT";   # not near expiry: no refresh, no network
    out: dict[str, any] = dict(sign_out("tavily"));                # no revocation endpoint on record: local only
    assert out["ok"] and not out["revoked"];
    kept: dict[str, any] = dict(load_creds("tavily"));
    assert "access_token" not in kept and kept["registration"]["client_id"] == "c", str(kept);
    if prev is None { os.environ.pop("SIGIL_HOME", None); } else { os.environ["SIGIL_HOME"] = prev; }
}
