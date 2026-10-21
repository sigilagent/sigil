"""Sigil Observatory — the full-stack entry (`jac start observatory.jac`).

Lives at the project root, not in src/, and has to: jac derives the client entry
module from the BASENAME of entry-point (cli/commands/impl/eject.impl.jac), so a
subdirectory entry emits compiled/src/observatory.js while _entry.js imports
./observatory.js — and the build dies at "Could not resolve ./observatory.js".

Sigil's web console, built in Jac: compile a SKILL.md and watch every stage, see
each compiled skill from its source to its AG-IR and gates, chat with the agent,
and run everything around it (runs, spend, memory, schedules, approvals,
channels, MCP, keys and models). Importing `sigil` and `sigil_console` registers
their `api_*` walkers as HTTP endpoints; `app()` below mounts the browser app.
"""

import from src.sigil {
    api_solve,
    api_graph,
    api_observability,
    api_add_mcp,
    api_register_skill,
    api_teach,
    api_soul,
    api_library,
    api_mcp,
    api_configure,
    api_recall,
    api_eval,
    api_relearn,
    api_forget,
    api_cron_list,
    api_cron_runs,
    api_cron_enable,
    api_cron_remove,
    api_skill_agir,
    api_tasks,
    api_hooks,
    api_channels,
    api_approvals
}
import from src.agent { api_chat_completions, api_models, api_tools_invoke }
import from src.cron { api_cron_tick }
import from src.channels { api_inbound }
import from src.sigil_console { api_console }

import "./src/global.css";
import from web.app { App }
import from "./web/embed_interop.js" { embedAllowed }

def:pub app() -> JsxElement {
    # Framed by any site but local.sigilagent.com: a notice, not the Observatory
    # (clickjacking — see web/embed_interop.js).
    if not embedAllowed() {
        return <div className="min-h-screen bg-[#08080d] text-slate-300 p-8 font-sans text-sm">
            Sigil's Observatory runs on this machine. Open it at local.sigilagent.com
            or on localhost directly — it does not load inside other sites.
        </div>;
    }
    return <App/>;
}
