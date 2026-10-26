# Tests for sigil_connect — annex of sigil_connect.jac
# (`jac test src/sigil_connect.jac`). Offline: the tier logic runs on rows built
# here, and nothing signs in, pulls a model or asks Ollama anything.

import os;

def _fake(pid: str, connected: bool, models: list[str]) -> dict[str, any] {
    return {"id": pid, "label": pid, "kind": "", "about": "", "connected": connected,
            "account": "", "detail": "connected" if connected else "not connected", "models": models, "env": ""};
}

test "provider_of: each prefix lands on its route" {
    assert provider_of("chatgpt/gpt-x") == "chatgpt";
    assert provider_of("claude-cc/opus") == "claude-code";
    assert provider_of("ollama_chat/qwen3:8b") == "ollama";
    assert provider_of("openrouter/openrouter/auto") == "openrouter";
    assert provider_of("gpt-5") == "openai";
    assert provider_of("chatgpt-4o-latest") == "openai";   # the API model, not the plan
    assert provider_of("anthropic/claude-sonnet-5-5") == "anthropic";
    assert provider_of("claude-sonnet-4-6") == "anthropic";
    assert provider_of("gemini/gemini-2.5-flash") == "gemini";
    assert provider_of("zai/glm-4.6") == "zai";
    assert provider_of("mystery/model") == "";
}

test "suggest_tiers: subscriptions take the frontier, the cheap model the small tier" {
    rows = [_fake("chatgpt", True, ["chatgpt/gpt-a", "chatgpt/gpt-a-mini"]), _fake("openai", True, [])];
    t = suggest_tiers(rows);
    assert t["frontier"] == "chatgpt/gpt-a";
    assert t["chat"] == "chatgpt/gpt-a";
    assert t["small"] == "chatgpt/gpt-a-mini";
    assert t["router"] == t["small"];
}

test "suggest_tiers: Claude Code is a frontier, never the small tier while anything else is there" {
    rows = [_fake("claude-code", True, ["claude-cc/opus"]), _fake("openai", True, [])];
    t = suggest_tiers(rows);
    assert t["frontier"] == "claude-cc/opus";
    assert t["small"] == "openai/gpt-5-mini";
}

test "suggest_tiers: one route alone covers every tier" {
    t = suggest_tiers([_fake("anthropic", True, [])]);
    assert t["frontier"] == "anthropic/claude-sonnet-5-5";
    assert t["small"] == "anthropic/claude-haiku-5-5";
}

test "suggest_tiers: nothing connected suggests nothing" {
    t = suggest_tiers([_fake("chatgpt", False, []), _fake("openai", False, [])]);
    assert t["frontier"] == "";
    assert t["small"] == "";
}

test "tiers_for: the route you picked takes the frontier; a CLI does not take the small tier" {
    rows = [_fake("claude-code", True, ["claude-cc/opus"]), _fake("chatgpt", True, ["chatgpt/gpt-a"])];
    t = tiers_for("claude-code", rows);
    assert t["frontier"] == "claude-cc/opus";
    assert t["small"] == "chatgpt/gpt-a";
    assert tiers_for("openai", rows) == {};   # not connected: nothing to offer
}

test "model_ready: a tier on a disconnected route says why" {
    rows = [_fake("chatgpt", False, []), _fake("openai", True, [])];
    bad = model_ready("chatgpt/default", rows);
    assert not bad["ok"];
    assert bad["provider"] == "chatgpt";
    assert bool(bad["why"]);
    assert model_ready("openai/gpt-5", rows)["ok"];
    assert not model_ready("", rows)["ok"];
}

test "model_ready: an Ollama model has to be pulled, not just Ollama running" {
    rows = [_fake("ollama", True, ["ollama_chat/qwen3:8b"])];
    assert model_ready("ollama_chat/qwen3:8b", rows)["ok"];
    assert not model_ready("ollama_chat/llama3:70b", rows)["ok"];
}

test "model_ready: a provider Sigil cannot check is not blocked" {
    assert model_ready("mystery/model", [])["ok"];
}

test "gate_on: default on, and the flag turns it off" {
    old = os.environ.get("SIGIL_REQUIRE_CONNECTION");
    if "SIGIL_REQUIRE_CONNECTION" in os.environ { del os.environ["SIGIL_REQUIRE_CONNECTION"]; }
    assert gate_on();
    for v in ["0", "false", "off", "no"] {
        os.environ["SIGIL_REQUIRE_CONNECTION"] = v;
        assert not gate_on(), v;
    }
    os.environ["SIGIL_REQUIRE_CONNECTION"] = "1";
    assert gate_on();
    if old is None { del os.environ["SIGIL_REQUIRE_CONNECTION"]; } else { os.environ["SIGIL_REQUIRE_CONNECTION"] = str(old); }
}

test "_billions: Ollama's parameter sizes" {
    assert _billions("8.2B") == 8.2;
    assert _billions("500M") == 0.5;
    assert _billions("") == 0.0;
}

test "every route has a status row and a way to connect it" {
    for p in PROVIDERS {
        assert bool(how_to(str(p[0]))), str(p[0]);
        assert str(_row(str(p[0]))["id"]) == str(p[0]);
    }
    for k in KEYED.keys() { assert str(KEYED[k][0]).endswith("_API_KEY"), str(k); }
}
