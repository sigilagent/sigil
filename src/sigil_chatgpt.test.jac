# Tests for sigil_chatgpt — annex of sigil_chatgpt.jac
# (`jac test src/sigil_chatgpt.jac`). All offline: no sign-in, no request to
# OpenAI. Each test that touches the credential file points SIGIL_HOME at a
# fresh temp directory first.

import os;
import json;
import time;
import base64;
import tempfile;
import urllib.parse;

def _home() -> str {
    d = tempfile.mkdtemp(prefix="sigil-chatgpt-");
    os.environ["SIGIL_HOME"] = d;
    return d;
}

def _jwt(claims: dict[str, any]) -> str {
    head = base64.urlsafe_b64encode(json.dumps({"alg": "none"}).encode()).decode().rstrip("=");
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=");
    return head + "." + body + ".sig";
}

# Stands in for an httpx streaming response: _events only calls iter_lines().
obj FakeResp {
    has lines: list[str] = [];
    def iter_lines() -> any { return iter(self.lines); }
}

def _query(url: str) -> dict[str, str] {
    out: dict[str, str] = {};
    for (k, v) in urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query) { out[str(k)] = str(v); }
    return out;
}

test "is_chatgpt: only the chatgpt/ prefix is ours" {
    assert is_chatgpt("chatgpt/default");
    assert is_chatgpt("chatgpt/gpt-x");
    assert not is_chatgpt("chatgpt-4o-latest");   # an OpenAI API model, billed by key
    assert not is_chatgpt("openai/gpt-5");
    assert not is_chatgpt("");
}

test "build_request: system turns become instructions, never system items" {
    body: any = build_request("m1", [
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hi"}
    ]);
    assert body["instructions"] == "be terse";
    for it in list(body["input"]) { assert str(dict(it)["role"]) != "system"; }
}

test "build_request: stays inside what plan usage accepts" {
    body: any = build_request("m1", [{"role": "user", "content": "hi"}]);
    assert body["store"] == False;
    assert body["stream"] == True;
    for banned in ["temperature", "max_output_tokens", "top_p", "metadata", "previous_response_id", "user"] {
        assert banned not in body, banned;
    }
}

test "build_request: tool calls and results ride as text, images as input_image" {
    body: any = build_request("m1", [
        {"role": "user", "content": "go"},
        {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "f", "arguments": "{}"}}]},
        {"role": "tool", "content": "42"},
        {"role": "user", "content": [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": "data:x"}}]}
    ]);
    items: list[any] = list(body["input"]);
    assert "<tool_call>" in str(dict(items[1])["content"]);
    assert "[TOOL RESULT]" in json.dumps(items[2]);
    assert "input_image" in json.dumps(items[3]);
}

test "build_request: a system-only prompt still sends an input" {
    body: any = build_request("m1", [{"role": "system", "content": "only this"}]);
    assert len(list(body["input"])) == 1;
    assert "only this" in json.dumps(body["input"]);
}

test "consume: deltas, then response.completed, is the reply" {
    out: any = consume(iter([
        {"type": "response.output_text.delta", "delta": "PO"},
        {"type": "response.output_text.delta", "delta": "NG"},
        {"type": "response.completed", "response": {"id": "r1", "usage": {"input_tokens": 9, "output_tokens": 2}}}
    ]));
    assert out["text"] == "PONG";
    assert out["finish"] == "stop";
    assert int(dict(out["usage"])["input_tokens"]) == 9;
}

test "consume: a stream that never completes is not a reply" {
    raised = False;
    try { consume(iter([{"type": "response.output_text.delta", "delta": "half"}])); }
    except Exception as e { raised = True; }
    assert raised;
}

test "consume: an incomplete reply keeps its text and says it was cut" {
    out: any = consume(iter([
        {"type": "response.output_text.delta", "delta": "part"},
        {"type": "response.incomplete", "response": {"incomplete_details": {"reason": "max_output_tokens"}}}
    ]));
    assert out["text"] == "part";
    assert out["finish"] == "length";
}

test "consume: a usage-limit failure names the fix" {
    msg = "";
    try {
        consume(iter([{"type": "response.failed",
                       "response": {"error": {"code": "subscription_sharing_usage_limit_exceeded"}}}]));
    } except Exception as e { msg = str(e); }
    assert "usage limit" in msg;
    assert "chatgpt.com/settings/usage" in msg;
}

test "build_authorize: a first sign-in registers Sigil" {
    _home();
    pair: any = build_authorize("http://127.0.0.1:5000/auth/callback");
    q = _query(pair[0]);
    assert pair[0].startswith(AUTHORIZE_URL);
    assert q["client_id"] == "dynamic_agent_client";
    assert q["agent_name_hint"] == "Sigil";
    assert q["ext_agent_host_id"].startswith("urn:uuid:");
    assert "chatgpt.tokens.use.direct" in q["scope"];
    assert q["resource"] == "https://api.openai.com/v1";
    assert q["code_challenge_method"] == "S256";
    assert q["redirect_uri"] == "http://127.0.0.1:5000/auth/callback";
    assert bool(pair[1]["registering"]);
}

test "host_id: stable across sign-ins" {
    _home();
    a = host_id();
    assert a == host_id();
}

test "build_authorize: a returning sign-in reuses the issued client" {
    _home();
    _write(creds_path(), {"client_id": "oaiapp_1", "email": "u@example.com", "id_token": "IT", "subject": "s"});
    pair: any = build_authorize("http://127.0.0.1:5000/auth/callback");
    q = _query(pair[0]);
    assert q["client_id"] == "oaiapp_1";
    assert "agent_name_hint" not in q;
    assert q["login_hint"] == "u@example.com";
    assert q["id_token_hint"] == "IT";
    assert not bool(pair[1]["registering"]);
    fresh: any = build_authorize("http://127.0.0.1:5000/auth/callback", True);
    assert _query(fresh[0])["client_id"] == "dynamic_agent_client";
}

test "finish_signin: a callback with the wrong state is refused before any exchange" {
    _home();
    pair: any = build_authorize("http://127.0.0.1:5000/auth/callback");
    raised = False;
    try { finish_signin({"state": "not-it", "code": "c"}, pair[1]); }
    except ChatGPTError as e { raised = True; }
    assert raised;
}

test "finish_signin: a declined consent says so" {
    _home();
    pair: any = build_authorize("http://127.0.0.1:5000/auth/callback");
    msg = "";
    try { finish_signin({"state": pair[1]["state"], "error": "access_denied"}, pair[1]); }
    except ChatGPTError as e { msg = str(e); }
    assert "declined" in msg;
}

test "_check_id_token: issuer, audience, expiry and nonce are each checked" {
    good: dict[str, any] = {"iss": ISSUER, "aud": "oaiapp_1", "exp": time.time() + 3600, "nonce": "n1", "sub": "s"};
    assert str(dict(_check_id_token(_jwt(good), "oaiapp_1", "n1"))["sub"]) == "s";
    for bad in [{"nonce": "other"}, {"aud": "someone-else"}, {"iss": "https://example.com"}, {"exp": 1}] {
        c = dict(good);
        for (k, v) in dict(bad).items() { c[str(k)] = v; }
        raised = False;
        try { _check_id_token(_jwt(c), "oaiapp_1", "n1"); }
        except ChatGPTError as e { raised = True; }
        assert raised, json.dumps(bad);
    }
}

test "auth_status: none, plan, and plan-not-allowed" {
    _home();
    assert str(dict(auth_status())["mode"]) == "none";
    _write(creds_path(), {"client_id": "oaiapp_1", "email": "u@x", "refresh_token": "r", "access_token": "a",
                          "expires_at": time.time() + 3600, "plan_enabled": True, "models": [{"slug": "gpt-a"}]});
    st: any = auth_status();
    assert st["mode"] == "plan";
    assert st["account"] == "u@x";
    assert list(st["models"]) == ["gpt-a"];
    _write(creds_path(), {"client_id": "oaiapp_1", "refresh_token": "r", "plan_enabled": False});
    assert str(dict(auth_status())["mode"]) == "disabled";
}

test "access_token: a live token is used as is, with no refresh" {
    _home();
    _write(creds_path(), {"client_id": "oaiapp_1", "refresh_token": "r", "access_token": "LIVE",
                          "expires_at": time.time() + 3600, "plan_enabled": True});
    assert access_token() == "LIVE";
}

test "the credential file is private" {
    _home();
    _write(creds_path(), {"client_id": "x"});
    assert (os.stat(str(creds_path())).st_mode & 0o777) == 0o600;
}

test "_slug: default is the account's first model" {
    _home();
    _write(creds_path(), {"refresh_token": "r", "plan_enabled": True, "models": [{"slug": "gpt-a"}, {"slug": "gpt-b"}]});
    assert _slug("chatgpt/default") == "gpt-a";
    assert _slug("chatgpt/gpt-b") == "gpt-b";
    assert _slug("gpt-b") == "gpt-b";   # litellm may strip the prefix first
}

test "_events: server-sent events parse to JSON objects" {
    lines = ["event: response.output_text.delta", "data: {\"type\": \"response.output_text.delta\", \"delta\": \"a\"}", "",
             "data: {\"type\": \"response.completed\", \"response\": {}}", ""];
    evs: any = list(_events(FakeResp(lines=lines)));
    assert len(evs) == 2;
    assert str(dict(evs[1])["type"]) == "response.completed";
}
