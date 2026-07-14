"""Hooks — OpenClaw parity: event-driven automation on lifecycle events.

OpenClaw has a 34-name lifecycle hook bus (before_agent_start, before_tool_call,
message_received, session_start, gateway_start, …). Sigil models the same:
Hook nodes on the Soul, fired by `fire_hooks(event, payload)` at lifecycle points.
Actions: note (observe), shell (run a command), memory (write a durable fact),
webhook (POST out). Decision hooks (block/override) are a straightforward extension
of the return contract.
"""

import subprocess;
import from urllib.request { Request, urlopen }
import from .sigil { awaken, Soul, teach }

edge Observes {}   # Soul -> Hook

node Hook {
    has name: str;
    has event: str;                 # before_solve | after_solve | before_tool | after_tool |
                                    # message_received | session_start | gateway_start | cron_fired
    has action_kind: str = "note";  # note | shell | memory | webhook
    has action: str = "";
    has enabled: bool = True;
    has fired: int = 0;
}

def _hooks(soul: Soul) -> list[Hook] { return [soul -->[?:Hook]]; }

def hook_add(name: str, event: str, action_kind: str, action: str) -> dict {
    soul = awaken();
    for h in _hooks(soul) { if h.name == name { h.event = event; h.action_kind = action_kind; h.action = action; return {"name": name, "updated": True}; } }
    hk = Hook(name=name, event=event, action_kind=action_kind, action=action);
    soul +>:Observes:+> hk;
    return {"name": name, "updated": False};
}

def hook_list() -> list {
    soul = awaken();
    return [{"name": h.name, "event": h.event, "kind": h.action_kind,
             "enabled": h.enabled, "fired": h.fired} for h in _hooks(soul)];
}

def hook_enable(name: str, on: bool) -> str {
    soul = awaken();
    for h in _hooks(soul) { if h.name == name { h.enabled = on; return name + (" enabled" if on else " disabled"); } }
    return "no such hook: " + name;
}

def hook_remove(name: str) -> str {
    soul = awaken();
    for h in _hooks(soul) { if h.name == name { del h; return "removed hook '" + name + "'"; } }
    return "no such hook: " + name;
}

def _run_action(h: Hook, payload: str) -> str {
    if h.action_kind == "shell" {
        try {
            p = subprocess.run(h.action, shell=True, capture_output=True, text=True, timeout=30);
            return "shell: " + str(p.stdout)[:200];
        } except Exception as e { return "shell-err: " + str(e)[:120]; }
    }
    if h.action_kind == "memory" { teach(h.action, "fact"); return "remembered"; }
    if h.action_kind == "webhook" {
        try {
            req = Request(h.action, data=payload.encode("utf-8"), headers={"Content-Type": "text/plain"});
            urlopen(req, timeout=15);
            return "posted";
        } except Exception as e { return "webhook-err: " + str(e)[:120]; }
    }
    return "note: " + h.action;
}

def fire_hooks(event: str, payload: str = "") -> list {
    # Run every enabled hook registered for `event`. Called at solve start/end,
    # tool calls, inbound messages, cron fires, gateway start.
    soul = awaken();
    out: list = [];
    for h in _hooks(soul) {
        if (not h.enabled) or (h.event != event) { continue; }
        h.fired += 1;
        out.append({"hook": h.name, "result": _run_action(h, payload)});
    }
    return out;
}
