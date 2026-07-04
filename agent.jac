"""Agent coordinator — the one place that fires the lifecycle hook bus around a solve.

`run_task` wraps the crystallize→execute→learn loop with `before_solve` / `after_solve`
hooks (and surfaces `solve_failed`). Channels, cron, and the CLI route through here so
hooks are load-bearing on every path — without a circular import (this module imports
prometheus + hooks; neither imports this one).
"""

import from prometheus { solve_task }
import from hooks { fire_hooks }

def run_task(task: str, skill: str = "") -> dict {
    fire_hooks("before_solve", task);
    r = solve_task(task, skill);
    ok = "DONE ok" in str(r["trace"]);
    fire_hooks("after_solve" if ok else "solve_failed", str(r["result"]));
    return r;
}

# ---------------------------------------------------------------------------
# OpenAI-compatible endpoint — any OpenClaw channel / OpenAI client can point at
# Prometheus as a "model" (POST /walker/api_chat_completions). The last user
# message becomes the task; the crystallize->execute reply comes back in the
# OpenAI chat-completion shape.
# ---------------------------------------------------------------------------
walker:pub api_chat_completions {
    has messages: list = [];
    has model: str = "prometheus";
    can run with Root entry {
        text = "";
        for m in self.messages { if str(m.get("role")) == "user" { text = str(m.get("content")); } }
        r = run_task(text, "");
        report {
            "id": "prom-chatcmpl", "object": "chat.completion", "model": self.model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": str(r["result"])}}]
        };
    }
}
