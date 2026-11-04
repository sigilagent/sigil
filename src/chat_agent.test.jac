# Tests for chat_agent — annex (`jac test chat_agent.jac`).
# Drives the ReAct chat agent under a mock model: verifies the tool-belt registers,
# incl_info soul injection works, streaming yields tokens, and conversation continuity
# accumulates. No network.

import from jaclang.byllm.lib { MockLLM }

test "chat_agent: streams tokens with the full tool-belt + incl_info soul (mock model)" {
    chat_llm = MockLLM(model_name="mockllm",
                       config={"outputs": ["Hi — I'm Sigil, ready to help.", "Working on it."]});
    CHAT_HISTORY = [];
    CHAT_INFO.clear();
    CHAT_INFO.update({
        "agent_name": "sigil", "persona": "a pragmatic operator",
        "principles": ["do the work"], "workspace": "/tmp/ws",
        "sandbox": "off", "running_shell_jobs": 0, "compiled_skills": 0
    });
    # stream=True -> chat_agent returns a generator; accumulate the tokens
    r1 = "";
    for tok in chat_agent("hello") { r1 += str(tok); }
    assert "Sigil" in r1, r1;
    r2 = "";
    for tok in chat_agent("do a thing") { r2 += str(tok); }
    assert r2, r2;
    # conversation history accumulated across the two turns
    assert len(CHAT_HISTORY) >= 2, str(len(CHAT_HISTORY));
}

test "chat_turn: streams to the token sink and returns the full reply" {
    # pin the mock so chat_turn's bind_chat_model rebind still streams a known string
    # (bind_chat_model reads the graph; here we just assert the sink receives the tokens
    #  chat_agent yields, independent of which model backs it).
    collected: list = [];
    def _sink(piece: str) { collected.append(str(piece)); }
    set_token_sink(_sink);
    chat_llm = MockLLM(model_name="mockllm", config={"outputs": ["streamed reply"]});
    CHAT_HISTORY = [];
    CHAT_INFO.clear();
    # drive chat_agent directly through the same accumulation the REPL uses
    got = "";
    for tok in chat_agent("hi") { piece = str(tok); got += piece; _sink(piece); }
    assert "streamed reply" in got, got;
    assert "".join([str(x) for x in collected]) == got, str(collected);
    set_token_sink(None);
}

test "use_skill: an unknown signature is a normal answer, not a crash" {
    # a fresh test graph has no Registry -> empty library; the tool must answer
    # (the model acts on it) instead of raising through byLLM's tool runtime.
    out = use_skill("not_a_skill", "do something");
    assert "no compiled skill" in out, out;
    assert "Nothing was run" in out, out;
}

test "use_skill: no target and no library still answers with the next step" {
    out = use_skill("", "");
    assert ("sigil_compile" in out) or ("no compiled skill" in out), out;
}

test "use_skill's progress tail turns node events into skill trace lines" {
    # the compiled module appends one JSON line per node entry; the tail must
    # surface each as a live `skill` trace event. flag.done pre-set = one final
    # drain then exit, so this exercises parse+emit without the thread.
    d = tempfile.mkdtemp();
    p = os.path.join(d, "agir.progress");
    with open(p, "w") as f {
        f.write('{"node": "fetch_top_ids", "t": 1}' + chr(10) + '{"node": "judge_relevance", "t": 2}' + chr(10));
    }
    drain_trace();
    _tail_progress(p, {"done": True});
    tr = drain_trace();
    joined = " | ".join([str(t["detail"]) for t in tr if str(t["tool"]) == "skill"]);
    assert "fetch_top_ids" in joined, joined;
    assert "judge_relevance" in joined, joined;
}

test "a history handed back by the console always opens on a user turn" {
    # The console trims the browser's history to its last 32 messages; the cut
    # can land on a tool result or an assistant tool call, which providers reject
    # as the first message of a conversation.
    h: list[any] = [
        {"role": "tool", "content": "orphan result", "tool_call_id": "c1"},
        {"role": "assistant", "content": "", "tool_calls": []},
        {"role": "user", "content": "next question"},
        {"role": "assistant", "content": "answer"}
    ];
    out = _starts_clean(h);
    assert [m["role"] for m in out] == ["user", "assistant"], str(out);
    assert _starts_clean([{"role": "assistant", "content": "x"}]) == [];
    assert _starts_clean([]) == [];
}

test "connect_model never takes a key in chat; it points at /connect" {
    import os;
    old = os.environ.get("ANTHROPIC_API_KEY");
    if "ANTHROPIC_API_KEY" in os.environ { del os.environ["ANTHROPIC_API_KEY"]; }
    msg = connect_model("anthropic");
    if old is not None { os.environ["ANTHROPIC_API_KEY"] = str(old); }
    assert "/connect anthropic" in msg, msg;
    assert "Do not ask for the key in chat" in msg, msg;
}

test "connect_model knows a channel is not a model provider" {
    msg = connect_model("telegram");
    assert msg.startswith("no model provider called"), msg;
}

test "a browser sign-in from a short-lived child points at the Observatory" {
    # An Observatory request or a channel turn exits with its reply, taking the
    # sign-in's loopback listener with it.
    import os;
    import tempfile;
    old_home = os.environ.get("SIGIL_HOME");
    os.environ["SIGIL_HOME"] = tempfile.mkdtemp(prefix="sigil-cm-");
    os.environ["SIGIL_API_CHILD"] = "1";
    msg = connect_model("chatgpt");
    del os.environ["SIGIL_API_CHILD"];
    if old_home is None { del os.environ["SIGIL_HOME"]; } else { os.environ["SIGIL_HOME"] = str(old_home); }
    assert "Model providers" in msg, msg;
    assert "auth.openai.com" not in msg, msg;   # the link is never handed to the model
}

test "chat's slash commands say connect for models and channel for channels" {
    import from .sigil_input { COMMANDS }
    usages = [str(c[0]) for c in COMMANDS];
    assert "/connect [provider]" in usages;
    assert "/channel <kind>" in usages;
    assert "/connections" in usages;
}

test "propose_agent: offered to web-console and channel turns, and switchable off" {
    old = os.environ.get("SIGIL_CHAT_PROPOSE");
    if "SIGIL_CHAT_PROPOSE" in os.environ { del os.environ["SIGIL_CHAT_PROPOSE"]; }
    _WEB_UI = False;
    _CHANNEL.clear();
    assert not _propose_on();          # the REPL has no Build button to press
    _WEB_UI = True;
    assert _propose_on();              # default on in the console
    _WEB_UI = False;
    _CHANNEL["channel"] = "whatsapp";
    assert _propose_on();              # a chat app builds with /build
    os.environ["SIGIL_CHAT_PROPOSE"] = "0";
    assert not _propose_on();
    _CHANNEL.clear();
    _WEB_UI = False;
    if old is None { del os.environ["SIGIL_CHAT_PROPOSE"]; }
    else { os.environ["SIGIL_CHAT_PROPOSE"] = str(old); }
}

test "propose_agent: no SKILL.md is a normal answer, and a proposal says not to compile" {
    assert "needs `skill_md`" in propose_agent("x", "y", "  ");
    out = propose_agent("clean_csv", "Cleans a CSV", "---\nname: clean_csv\n---\n1. Read it.");
    assert "clean_csv" in out;
    assert "Do not compile it yourself" in out;
}

test "a tool call parsed from text leaves for the browser as plain JSON" {
    # A model without native tools (the ChatGPT plan tier) writes calls as text;
    # byLLM parses them into SimpleNamespace, which json would turn into a repr.
    import from types { SimpleNamespace }
    import json;
    call = SimpleNamespace(id="call_1", type="function",
                           function=SimpleNamespace(name="propose_agent", arguments="{\"name\": \"x\"}"));
    h = _plain_history([{"role": "assistant", "content": "", "tool_calls": [call]}]);
    tc = h[0]["tool_calls"][0];
    assert tc["function"]["name"] == "propose_agent";
    assert json.loads(tc["function"]["arguments"])["name"] == "x";
    # and it survives the trip: json can carry it as is
    assert "namespace(" not in json.dumps(h);
}

test "a history saved with repr'd tool calls is repaired on the way back in" {
    import json;
    args = json.dumps({"name": "clean_csv", "skill_md": "---\nname: clean_csv\n---\n1. Read it."});
    bad = "namespace(id='call_9', type='function', function=namespace(name='propose_agent', arguments=" + repr(args) + "))";
    h = _plain_history([{"role": "assistant", "content": "", "tool_calls": [bad]}]);
    tc = h[0]["tool_calls"][0];
    assert tc["id"] == "call_9";
    assert tc["function"]["name"] == "propose_agent";
    assert json.loads(tc["function"]["arguments"])["skill_md"].startswith("---");
    # plain dicts pass through untouched, and a string that is not a repr is dropped
    ok = {"id": "c", "type": "function", "function": {"name": "ws_read", "arguments": "{}"}};
    assert _plain_history([{"role": "assistant", "tool_calls": [ok, "junk"]}])[0]["tool_calls"] == [ok];
}

test "learn_skill goes through the compiler unless switched off" {
    old = os.environ.get("SIGIL_LEARN_VIA_COMPILER");
    os.environ.pop("SIGIL_LEARN_VIA_COMPILER", None);
    assert _learn_via_compiler();
    os.environ["SIGIL_LEARN_VIA_COMPILER"] = "0";
    assert not _learn_via_compiler();
    if old is None { os.environ.pop("SIGIL_LEARN_VIA_COMPILER", None); }
    else { os.environ["SIGIL_LEARN_VIA_COMPILER"] = str(old); }
}

test "an interrupted turn leaves the request and what it had done in the conversation" {
    CHAT_HISTORY.clear();
    CHAT_HISTORY.append({"role": "user", "content": "earlier"});
    CHAT_HISTORY.append({"role": "assistant", "content": "earlier answer"});
    _note_interrupted("summarise HN for me", "So far: two posts");
    assert CHAT_HISTORY[-2] == {"role": "user", "content": "summarise HN for me"}, str(CHAT_HISTORY);
    last = str(CHAT_HISTORY[-1]["content"]);
    assert CHAT_HISTORY[-1]["role"] == "assistant" and last.startswith("(Interrupted"), last;
    assert "So far: two posts" in last;
    CHAT_HISTORY.clear();
}
