"""Sigil Observatory — the full-stack entry (`jac start observatory.jac`).

An OpenClaw-style web front-end, built in Jac: watch the agent's own graph evolve
live (soul, skills, memory, MCP servers, run lineage) and see 100% token
observability on every LLM call. Importing `sigil` registers its `api_*`
walkers as HTTP endpoints; the `cl` block mounts the browser app.
"""

import from src.sigil {
    api_solve, api_graph, api_observability, api_add_mcp, api_register_skill,
    api_teach, api_soul, api_library, api_mcp, api_configure, api_recall,
    api_eval, api_relearn, api_forget
}
import from src.agent { api_chat_completions, api_models, api_tools_invoke }

cl {
    import from web.app { App }

    def:pub app() -> JsxElement {
        return <App />;
    }
}
