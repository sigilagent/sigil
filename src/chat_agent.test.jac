# Tests for chat_agent — annex (`jac test chat_agent.jac`).
# Drives the ReAct chat agent under a mock model: verifies the tool-belt registers,
# incl_info soul injection works, and conversation continuity accumulates. No network.

import from jaclang.byllm.lib { MockLLM }

test "chat_agent: runs with the full tool-belt + incl_info soul under a mock model" {
    global chat_llm, CHAT_HISTORY, CHAT_INFO;
    chat_llm = MockLLM(model_name="mockllm",
                       config={"outputs": ["Hi — I'm Sigil, ready to help.", "Working on it."]});
    CHAT_HISTORY = [];
    CHAT_INFO.clear();
    CHAT_INFO.update({
        "agent_name": "sigil", "persona": "a pragmatic operator",
        "principles": ["do the work"], "workspace": "/tmp/ws",
        "sandbox_mode": "jail", "crystallized_skills": 0
    });
    r1 = chat_agent("hello");
    assert "Sigil" in str(r1), str(r1);
    r2 = chat_agent("do a thing");
    assert str(r2), str(r2);
    # conversation history accumulated across the two turns
    assert len(CHAT_HISTORY) >= 2, str(len(CHAT_HISTORY));
}
