"""Sigil Observatory — the full-stack entry (`jac start observatory.jac`).

Lives at the project root, not in src/, and has to: jac derives the client entry
module from the BASENAME of entry-point (cli/commands/impl/eject.impl.jac), so a
subdirectory entry emits compiled/src/observatory.js while _entry.js imports
./observatory.js — and the build dies at "Could not resolve ./observatory.js".

An OpenClaw-style web front-end, built in Jac: watch the agent's own graph evolve
live (soul, skills, memory, MCP servers, run lineage) and see 100% token
observability on every LLM call. Importing `sigil` registers its `api_*`
walkers as HTTP endpoints; the `cl` block mounts the browser app.
"""

import from src.sigil {
    api_solve, api_graph, api_observability, api_add_mcp, api_register_skill,
    api_teach, api_soul, api_library, api_mcp, api_configure, api_recall,
    api_eval, api_relearn, api_forget,
    api_cron_list, api_cron_runs, api_cron_enable, api_cron_remove,
    api_skill_agir, api_tasks, api_hooks, api_channels, api_approvals
}
import from src.agent { api_chat_completions, api_models, api_tools_invoke }
import from src.cron { api_cron_tick }
import from src.channels { api_inbound }

cl {
    import "./src/global.css";
    import from web.app { App }

    def:pub app() -> JsxElement {
        return <App />;
    }
}
