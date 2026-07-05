"""Prometheus Observatory — the full-stack entry (`jac start observatory.jac`).

An OpenClaw-style web front-end, built in Jac: watch the agent's own graph evolve
live (soul, skills, memory, MCP servers, run lineage) and see 100% token
observability on every LLM call. Importing `prometheus` registers its `api_*`
walkers as HTTP endpoints; the `cl` block mounts the browser app.
"""

import from prometheus {
    api_solve, api_graph, api_observability, api_add_mcp, api_register_skill,
    api_teach, api_soul, api_library, api_mcp, api_configure, api_recall
}
import from agent { api_chat_completions }

cl {
    import from web.app { App }

    def:pub app() -> JsxElement {
        return <App />;
    }
}
