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

test "_response: usage folds Claude Code's cache split into prompt_tokens" {
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

test "install: claims the claude-cc prefix with litellm, idempotently" {
    import litellm;
    assert install();
    assert install();
    ours = [x for x in litellm.custom_provider_map if x["provider"] == "claude-cc"];
    assert len(ours) == 1;
    assert "claude-cc" in litellm.provider_list;
    assert "claude-cc" in litellm._custom_providers;
}
