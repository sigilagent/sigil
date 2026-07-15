# Tests for sigil_subagents — annex (`jac test sigil_subagents.jac`).
# Verifies the flow/wait fan-out and walker spawn under a mock model (no network).

import from jaclang.byllm.lib { MockLLM }

test "spawn_subagents: empty task list is a no-op" {
    assert "no sub-tasks" in spawn_subagents([]);
}

test "spawn_parallel: fans out one walker per task via flow/wait" {
    pin_sub_llm(MockLLM(model_name="mockllm",
                        config={"outputs": ["did alpha", "did beta", "did gamma", "did delta"]}));
    out = spawn_parallel(["task-a", "task-b"]);
    # both sub-agents ran and reported; results are labelled and joined
    assert "sub-agent 1" in out and "sub-agent 2" in out, out;
    assert "did " in out, out;
}

test "spawn_subagent: single delegate returns its result" {
    pin_sub_llm(MockLLM(model_name="mockllm", config={"outputs": ["done the thing"]}));
    out = spawn_subagent("do one thing");
    assert "done the thing" in out, out;
}
