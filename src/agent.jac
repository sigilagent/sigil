"""Agent coordinator — the one place that fires the lifecycle hook bus around a solve.

`run_task` wraps the compile→execute→learn loop with `before_solve` / `after_solve`
hooks (and surfaces `solve_failed`). Channels, cron, and the CLI route through here so
hooks are load-bearing on every path — without a circular import (this module imports
sigil + hooks; neither imports this one).
"""

import from .sigil_mcp { dispatch }
import from .sigil { solve_task, library, describe_soul }
import from .hooks { fire_hooks }

def run_task(task: str, skill: str = "") -> dict {
    fire_hooks("before_solve", task);
    r = solve_task(task, skill);
    ok = "DONE ok" in str(r["trace"]);
    fire_hooks("after_solve" if ok else "solve_failed", str(r["result"]));
    return r;
}

# ---------------------------------------------------------------------------
# OpenAI-compatible endpoint — any OpenClaw channel / OpenAI client can point at
# Sigil as a "model" (POST /walker/api_chat_completions). The last user
# message becomes the task; the compile->execute reply comes back in the
# OpenAI chat-completion shape.
# ---------------------------------------------------------------------------
walker:pub api_chat_completions {
    has messages: list = [];
    has model: str = "sigil";
    can run with Root entry {
        text = "";
        for m in self.messages { if str(m.get("role")) == "user" { text = str(m.get("content")); } }
        r = run_task(text, "");
        report {
            "id": "sigil-chatcmpl", "object": "chat.completion", "model": self.model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": str(r["result"])}}]
        };
    }
}

# GET-style: list the tiers + each compiled skill as an OpenAI "model" so a
# client can discover what Sigil can route to (POST /walker/api_models).
walker:pub api_models {
    can run with Root entry {
        data: list = [];
        for tier in ["frontier", "small", "router"] {
            data.append({"id": "sigil-" + tier, "object": "model", "owned_by": "sigil"});
        }
        for e in list(library()) {
            data.append({"id": "sigil-skill/" + str(e["signature"]), "object": "model", "owned_by": "sigil"});
        }
        report {"object": "list", "data": data};
    }
}

# Invoke a registered MCP tool by name (POST /walker/api_tools_invoke) — the
# `/tools/invoke` analog. Returns the tool result or an error if no server has it.
walker:pub api_tools_invoke {
    has name: str = "";
    has arguments: dict = {};
    can run with Root entry {
        res = dispatch(self.name, [self.arguments]);
        if res is None { report {"ok": False, "error": "no registered tool '" + self.name + "'"}; }
        else { report res; }
    }
}
