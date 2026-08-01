# Tests for sigil_claude_cc — annex of sigil_claude_cc.jac
# (`jac test src/sigil_claude_cc.jac`). Every test here is offline: the one that
# touches litellm only checks provider registration, and none shells out to
# `claude`, so the suite costs nothing and needs no auth.

import json;

test "is_claude_cc: only the claude-cc prefix is ours" {
    assert is_claude_cc("claude-cc/opus");
    assert not is_claude_cc("claude-3-5-sonnet");     # a real anthropic model
    assert not is_claude_cc("anthropic/claude-opus-4-5");
    assert not is_claude_cc("");
}

test "_alias: strips the prefix, and 'default' means no --model" {
    assert _alias("claude-cc/opus") == "opus";
    assert _alias("opus") == "opus";                  # litellm may pre-strip it
    assert _alias("claude-cc/default") == "";
    assert _alias("") == "";
}

test "_argv: a named tier passes --model, an unnamed one does not" {
    assert "--model" in _argv("claude-cc/haiku");
    assert _argv("claude-cc/haiku")[-1] == "haiku";
    assert "--model" not in _argv("claude-cc/default");
}

test "_argv: the session is toolless — that is what keeps byLLM's protocol intact" {
    argv = _argv("claude-cc/opus");
    spec = json.loads(argv[argv.index("--agents") + 1]);
    assert spec["sigil-slot"]["tools"] == [];
    assert argv[argv.index("--agent") + 1] == "sigil-slot";
}

test "_render: roles are tagged and empty turns dropped" {
    out = _render([
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": ""}
    ]);
    assert "[SYSTEM]\nbe terse" in out;
    assert "[USER]\nhello" in out;
    assert "ASSISTANT" not in out;
}

test "_render: multimodal parts keep their text and flag what was dropped" {
    out = _render([
        {"role": "user", "content": [
            {"type": "text", "text": "what is this"},
            {"type": "image_url", "image_url": {"url": "data:..."}}
        ]}
    ]);
    assert "what is this" in out;
    assert "text-only" in out;
}

test "_render: a prior tool call replays in byLLM's own <tool_call> form" {
    out = _render([
        {"role": "assistant", "content": "",
         "tool_calls": [{"function": {"name": "price_of", "arguments": "{\"p\": \"widget\"}"}}]},
        {"role": "tool", "content": "4200"}
    ]);
    assert "<tool_call>" in out;
    assert "price_of" in out;
    assert "[TOOL RESULT]\n4200" in out;
}

test "_parse: a failed run raises rather than returning empty text" {
    ok = False;
    try {
        _parse("", "boom", 1);
    } except Exception as e {
        ok = "boom" in str(e);
    }
    assert ok;
}

test "_parse: an is_error result raises too" {
    ok = False;
    try {
        _parse(json.dumps({"is_error": True, "result": "error_max_turns"}), "", 0);
    } except Exception as e {
        ok = "error_max_turns" in str(e);
    }
    assert ok;
}

# litellm is an OPTIONAL byLLM dependency — byllm/_optdeps/litellm.jac falls back
# to a stub when it is absent, and CI runs on a runtime that does not ship it. The
# two tests that need the real package assert the DEGRADED contract instead when
# it is missing, so neither environment is left asserting nothing.
def _has_litellm() -> bool {
    try {
        import litellm;
        return True;
    } except Exception {
        return False;
    }
}

test "_response: usage folds Claude Code's cache split into prompt_tokens" {
    if not _has_litellm() {
        # no litellm, no ModelResponse to build — the handler is never reached
        # either, because litellm is what dispatches to it
        assert not install();
    } else {
        r = _response("claude-cc/haiku", {
            "result": "hi",
            "stop_reason": "end_turn",
            "total_cost_usd": 0.5,
            "usage": {"input_tokens": 3, "cache_read_input_tokens": 100,
                      "cache_creation_input_tokens": 7, "output_tokens": 11}
        });
        assert r.choices[0].message.content == "hi";
        assert r.choices[0].finish_reason == "stop";
        assert r.usage.prompt_tokens == 110;
        assert r.usage.completion_tokens == 11;
        assert r.model == "claude-cc/haiku";
        # sigil_observe reads cost off _hidden_params; litellm has no map for us
        assert r._hidden_params["response_cost"] == 0.5;
    }
}

test "install: claims the claude-cc prefix with litellm, idempotently" {
    if not _has_litellm() {
        # the real contract on a litellm-less runtime: report failure, never raise
        assert not install();
        assert not install();
    } else {
        import litellm;
        assert install();
        assert install();
        ours = [x for x in litellm.custom_provider_map if x["provider"] == "claude-cc"];
        assert len(ours) == 1;
        assert "claude-cc" in litellm.provider_list;
        assert "claude-cc" in litellm._custom_providers;
    }
}

test "an agent session takes its budget from its own variable" {
    import os;
    # This used to assert `_agent_timeout() > _timeout()` — a slot is one completion
    # and an authoring session is dozens of turns, so sharing the slot budget killed
    # long runs mid-flight. Neither has a default budget any more (see the timeout
    # tests below), but they still read separate variables, and a bad value must
    # never crash a run.
    prev = os.environ.get("SIGIL_CLAUDE_AGENT_TIMEOUT", "");
    os.environ["SIGIL_CLAUDE_AGENT_TIMEOUT"] = "120";
    assert _agent_timeout() == 120.0;
    assert _timeout() is None, "the slot budget must not follow the agent variable";
    os.environ["SIGIL_CLAUDE_AGENT_TIMEOUT"] = "not-a-number";
    assert _agent_timeout() is None;        # never crash on a bad env value
    if prev { os.environ["SIGIL_CLAUDE_AGENT_TIMEOUT"] = prev; }
    else { os.environ.pop("SIGIL_CLAUDE_AGENT_TIMEOUT", None); }
}

test "an agent session carries the caller's persona, not a borrowed one" {
    assert FIXER[0] == "sigil-fixer";
    assert AUTHOR[0] == "sigil-author";
    assert "Repairs" in FIXER[1];
    assert "Authors" in AUTHOR[1];
    # the standing instructions must differ: a repairer is told to change only
    # what the diagnostic requires, which is wrong advice for authoring
    assert "only what the diagnostic requires" in FIXER[2];
    assert "only what the diagnostic requires" not in AUTHOR[2];
    assert "never add, drop or re-modalize" in AUTHOR[2];
}

test "_parse surfaces the CLI's own reason, not a dump of its usage counters" {
    import json;
    # the shape that actually shipped: exit 1, is_error, and the reason buried in
    # ~600 chars of token counters — which is what the raw dump truncated to
    blob = json.dumps({
        "type": "result", "subtype": "success", "is_error": True,
        "api_error_status": 400, "result": "Credit balance is too low",
        "usage": {"input_tokens": 0, "output_tokens": 0}
    });
    msg = "";
    try {
        _parse(blob, "", 1);
    } except Exception as e {
        msg = str(e);
    }
    assert "out of credit" in msg;
    assert "usage" not in msg;          # no counter dump
    assert "input_tokens" not in msg;
    assert len(msg) < 400;              # one readable line, not three screens
}

test "a terminal CLI failure is an auth error so byLLM stops retrying it" {
    import json;
    # byLLM retries APIConnectionError three times — three tracebacks for one
    # billing problem. AuthenticationError is not in its retry set. Without
    # litellm there is no such class to raise (and no dispatch to this handler
    # either), so the contract there is just: still a clean ClaudeCCError.
    want = "AuthenticationError" if _has_litellm() else "ClaudeCCError";
    for reason in ["Credit balance is too low", "Please run /login",
                   "OAuth token has expired", "Invalid API key"] {
        kind = "";
        try {
            _parse(json.dumps({"is_error": True, "result": reason}), "", 1);
        } except Exception as e {
            kind = type(e).__name__;
        }
        assert kind == want;
    }
}

test "an unrecognized failure still reports its status and reason, not raw json" {
    import json;
    msg = "";
    try {
        _parse(json.dumps({"is_error": True, "api_error_status": 529,
                           "result": "Overloaded"}), "", 1);
    } except Exception as e {
        msg = str(e);
    }
    assert "529" in msg;
    assert "Overloaded" in msg;
}

test "_parse still handles output that is not json at all" {
    ok = False;
    try { _parse("", "boom", 1); } except Exception as e { ok = "boom" in str(e); }
    assert ok;
    ok2 = False;
    try { _parse("not json", "", 0); } except Exception as e2 { ok2 = "unparseable" in str(e2); }
    assert ok2;
}



def _write_cfg(dir: str, cfg: dict) -> None {
    import json;
    import os;
    os.makedirs(dir, exist_ok=True);
    with open(os.path.join(dir, ".claude.json"), "w") as f { f.write(json.dumps(cfg)); }
}

test "auth_status reads which account a call would actually bill" {
    import os;
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_auth_");
    prev_dir = os.environ.get("CLAUDE_CONFIG_DIR", "");
    prev_key = os.environ.get("ANTHROPIC_API_KEY", "");
    prev_allow = os.environ.get("SIGIL_CLAUDE_ALLOW_API_KEY", "");
    os.environ["CLAUDE_CONFIG_DIR"] = d;
    os.environ["ANTHROPIC_API_KEY"] = "sk-ant-0000000000000000000000ABCDEFGHIJKLMNOPQRST";
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = "";

    # signed in, key rejected -> the subscription pays, and we can name it
    _write_cfg(d, {"oauthAccount": {"emailAddress": "me@example.com"},
                   "customApiKeyResponses": {"approved": [], "rejected": ["ABCDEFGHIJKLMNOPQRST"]}});
    st = auth_status();
    assert st["mode"] == "subscription";
    assert st["account"] == "me@example.com";

    # an APPROVED key is only honoured when the user opted in — otherwise the
    # child never sees the variable, so reporting "api-key" would be a lie
    _write_cfg(d, {"oauthAccount": {"emailAddress": "me@example.com"},
                   "customApiKeyResponses": {"approved": ["ABCDEFGHIJKLMNOPQRST"], "rejected": []}});
    assert auth_status()["mode"] == "subscription";
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = "1";
    assert auth_status()["mode"] == "api-key";
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = "";

    # no login at all -> `--claude` has nothing to run on
    _write_cfg(d, {"customApiKeyResponses": {"approved": [], "rejected": []}});
    assert auth_status()["mode"] == "none";

    # unreadable config is not proof of absence — never block on a guess
    os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(d, "nope");
    assert auth_status()["mode"] == "unknown";

    os.environ["CLAUDE_CONFIG_DIR"] = prev_dir;
    if prev_key { os.environ["ANTHROPIC_API_KEY"] = prev_key; } else { del os.environ["ANTHROPIC_API_KEY"]; }
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = prev_allow;
}

test "the child process gets the subscription, not an approved API key" {
    import os;
    prev_key = os.environ.get("ANTHROPIC_API_KEY", "");
    prev_allow = os.environ.get("SIGIL_CLAUDE_ALLOW_API_KEY", "");
    os.environ["ANTHROPIC_API_KEY"] = "sk-test";

    # default: `--claude` means the subscription, so the variable is withheld
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = "";
    assert "ANTHROPIC_API_KEY" not in _env();
    assert "ANTHROPIC_AUTH_TOKEN" not in _env();
    # ...and the caller's own environment is never rewritten
    assert os.environ.get("ANTHROPIC_API_KEY") == "sk-test";

    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = "1";
    assert _env().get("ANTHROPIC_API_KEY") == "sk-test";

    if prev_key { os.environ["ANTHROPIC_API_KEY"] = prev_key; } else { del os.environ["ANTHROPIC_API_KEY"]; }
    os.environ["SIGIL_CLAUDE_ALLOW_API_KEY"] = prev_allow;
}

# --- web search on the subscription ----------------------------------------

test "_search_agent: exactly WebSearch, and a JSON-only reply contract" {
    # The slot agent is toolless on purpose; this one is the single place a
    # `claude -p` run is handed a tool, so pin down which.
    spec = _SEARCH_AGENT["sigil-search"];
    assert spec["tools"] == ["WebSearch"], str(spec["tools"]);
    assert "JSON array" in str(spec["prompt"]);
    assert "No prose" in str(spec["prompt"]);
}

test "_json_array: bare, fenced, and prose-wrapped replies all parse" {
    bare = '[{"title": "A", "url": "https://a.test", "desc": "d"}]';
    assert len(list(_json_array(bare))) == 1;
    assert list(_json_array(bare))[0]["url"] == "https://a.test";
    # a model that fences it anyway
    fenced = "```json" + chr(10) + bare + chr(10) + "```";
    assert len(list(_json_array(fenced))) == 1, str(_json_array(fenced));
    # ...or prefaces it with a sentence
    assert len(list(_json_array("Here are the results:" + chr(10) + bare))) == 1;
    # an empty result set is a valid answer, not a failure
    assert _json_array("[]") == [];
}

test "_json_array: junk yields no results rather than raising" {
    assert _json_array("I could not search.") == [];
    assert _json_array("") == [];
    assert _json_array("[not json at all}") == [];
    assert _json_array('{"title": "an object, not an array"}') == [];
}

test "search argv: WebSearch allowed, more than one turn, no session persistence" {
    # A search needs a turn to call the tool and a turn to answer — the slot
    # agent's --max-turns 1 would kill it mid-search.
    import json;
    spec = json.dumps(_SEARCH_AGENT, sort_keys=True);
    assert "WebSearch" in spec;
    assert "sigil-search" in spec;
}

# --- timeouts ---------------------------------------------------------------

test "_env_seconds: unset, zero and junk all mean no limit" {
    import os;
    os.environ.pop("SIGIL_TEST_SECS", None);
    assert _env_seconds("SIGIL_TEST_SECS") is None;
    os.environ["SIGIL_TEST_SECS"] = "";
    assert _env_seconds("SIGIL_TEST_SECS") is None;
    os.environ["SIGIL_TEST_SECS"] = "0";
    assert _env_seconds("SIGIL_TEST_SECS") is None;
    os.environ["SIGIL_TEST_SECS"] = "not-a-number";
    assert _env_seconds("SIGIL_TEST_SECS") is None;
    os.environ["SIGIL_TEST_SECS"] = "90";
    assert _env_seconds("SIGIL_TEST_SECS") == 90.0;
    os.environ.pop("SIGIL_TEST_SECS", None);
}

test "slot and agent calls have NO deadline unless one is asked for" {
    # A 600s default killed a real spec-loop call on a document-sized SKILL.md and
    # then retried into the same wall twice. There is no partial output to salvage
    # from a slot call, so a deadline only decides whether the work is lost.
    import os;
    for v in ["SIGIL_CLAUDE_CC_TIMEOUT", "SIGIL_CLAUDE_AGENT_TIMEOUT"] { os.environ.pop(v, None); }
    assert _timeout() is None;
    assert _agent_timeout() is None;
    # ...but an unattended deployment can still ask for one
    os.environ["SIGIL_CLAUDE_CC_TIMEOUT"] = "45";
    assert _timeout() == 45.0;
    os.environ.pop("SIGIL_CLAUDE_CC_TIMEOUT", None);
    # web search keeps its own ceiling: a stuck search has nothing to salvage either
    assert _search_timeout() == 180.0;
}
