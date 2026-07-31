# Tests for sigil_mcp_serve — annex of sigil_mcp_serve.jac
# (`jac test src/sigil_mcp_serve.jac`). The protocol is exercised through
# _dispatch with stub callables, so nothing here touches the graph, spawns a
# process, or spends a token.

import json;

glob SKILLS: list = [
    {"signature": "clean-csv", "version": 2, "origin": "compiled-skill",
     "runs": 5, "successes": 4,
     "intent": "Use when a messy CSV needs snake_case headers and blank rows removed."},
    {"signature": "one_line_tldr", "version": 1, "origin": "compiled-skill",
     "runs": 0, "successes": 0, "intent": ""}
];

def _skills() -> list { return SKILLS; }

def _run(task: str, sig: str) -> dict {
    return {"result": "ran " + sig + " on " + task, "trace": "DONE ok"};
}

def _solve(task: str, skill: str) -> dict {
    return {"result": "solved " + task, "trace": "route -> x\nDONE ok"};
}

def _tc(name: str, args: dict) -> dict {
    return _dispatch({"method": "tools/call",
                      "params": {"name": name, "arguments": args}},
                     _skills, _run, _solve);
}

test "tool names are legal MCP identifiers" {
    assert _tool_name("clean-csv") == "skill_clean-csv";
    assert _tool_name("pdf extract/v2") == "skill_pdf_extract_v2";
    assert len(_tool_name("x" * 200)) <= 64;
}

test "initialize echoes the client's protocol version and names the server" {
    r = _dispatch({"method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                  _skills, _run, _solve);
    assert r["protocolVersion"] == "2025-06-18";
    assert r["serverInfo"]["name"] == "sigil";
    assert "tools" in r["capabilities"];
}

test "initialize without a version falls back to ours" {
    r = _dispatch({"method": "initialize", "params": {}}, _skills, _run, _solve);
    assert r["protocolVersion"] == PROTOCOL_VERSION;
}

test "an unknown method is a JSON-RPC method-not-found, not a crash" {
    raised = False;
    try {
        _dispatch({"method": "tools/nope"}, _skills, _run, _solve);
    } except LookupError {
        raised = True;
    }
    assert raised;
}

test "tools/list publishes one tool per skill plus solve and library" {
    r = _dispatch({"method": "tools/list"}, _skills, _run, _solve);
    names = [t["name"] for t in r["tools"]];
    assert "skill_clean-csv" in names;
    assert "skill_one_line_tldr" in names;
    assert "sigil_solve" in names;
    assert "sigil_library" in names;
    assert len(names) == 4;
}

test "the skill's own description is the tool trigger, with its track record" {
    r = _dispatch({"method": "tools/list"}, _skills, _run, _solve);
    byname = {t["name"]: t for t in r["tools"]};
    d = byname["skill_clean-csv"]["description"];
    assert d.startswith("Use when a messy CSV");
    assert "4/5 runs succeeded" in d;
    # no description and no runs: still says what it is, and admits it's unproven
    d2 = byname["skill_one_line_tldr"]["description"];
    assert "one_line_tldr" in d2;
    assert "not yet run" in d2;
}

test "a skill tool declares a required task argument" {
    r = _dispatch({"method": "tools/list"}, _skills, _run, _solve);
    byname = {t["name"]: t for t in r["tools"]};
    schema = byname["skill_clean-csv"]["inputSchema"];
    assert schema["required"] == ["task"];
    assert schema["properties"]["task"]["type"] == "string";
}

test "calling a skill tool pins that skill — it does not re-route" {
    r = _tc("skill_clean-csv", {"task": "tidy sales.csv"});
    assert not r["isError"];
    assert "ran clean-csv on tidy sales.csv" in r["content"][0]["text"];
}

test "sigil_solve routes instead of pinning" {
    r = _tc("sigil_solve", {"task": "tidy sales.csv"});
    assert not r["isError"];
    assert "solved tidy sales.csv" in r["content"][0]["text"];
}

test "sigil_library needs no arguments and lists the skills" {
    r = _tc("sigil_library", {});
    assert not r["isError"];
    text = r["content"][0]["text"];
    assert "clean-csv" in text;
    assert "runs=5 ok=4" in text;
}

test "a failed run comes back as isError, with its trace" {
    def failing(task: str, sig: str) -> dict {
        return {"result": "", "trace": "route -> x\nDONE fail"};
    }
    r = _dispatch({"method": "tools/call",
                   "params": {"name": "skill_clean-csv", "arguments": {"task": "t"}}},
                  _skills, failing, _solve);
    assert r["isError"];
    assert "DONE fail" in r["content"][0]["text"];
}

test "a missing task and an unknown tool are errors, not exceptions" {
    assert _tc("skill_clean-csv", {})["isError"];
    assert _tc("sigil_solve", {"task": "   "})["isError"];
    assert _tc("skill_does_not_exist", {"task": "t"})["isError"];
}

test "tools/list is valid JSON — it goes on the wire verbatim" {
    r = _dispatch({"method": "tools/list"}, _skills, _run, _solve);
    assert json.loads(json.dumps(r)) == r;
}
