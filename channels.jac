"""Channels — OpenClaw parity: the messaging surface + the inbound→agent→reply loop.

OpenClaw ships ~27 channel plugins (discord/slack/telegram/whatsapp/matrix/imessage/…);
they all reduce to one contract: an inbound message routes to the agent, the agent's
reply goes back out. Prometheus models that contract on the graph — a Channel node is
config (like OpenClaw's channel plugin registration), and `inbound()` is the loop. A
concrete adapter (a Discord bot, a webhook) just calls `inbound()` and delivers `outbound`;
the `api_inbound` HTTP endpoint IS a ready webhook channel.
"""

import from prometheus { awaken, Soul, solve_task }

edge Connects {}    # Soul -> Channel
edge Carried {}     # Channel -> Message

node Channel {
    has name: str;
    has kind: str = "webhook";   # webhook | cli | discord | slack | telegram | matrix | ...
    has config: str = "";        # adapter config (token ref, endpoint, …) — a SecretRef in prod
    has enabled: bool = True;
    has dm_scope: str = "per-peer";   # main | per-peer | per-channel-peer  (OpenClaw session.dmScope)
}

node Message {
    has direction: str = "in";   # in | out
    has peer: str = "";
    has text: str = "";
    has ts: float = 0.0;
}

def _ts() -> float {
    import time;
    return time.time();
}

def _channels(soul: Soul) -> list[Channel] { return [soul -->[?:Channel]]; }

def channel_add(name: str, kind: str, config: str = "", dm_scope: str = "per-peer") -> dict {
    soul = awaken();
    for c in _channels(soul) { if c.name == name { c.kind = kind; c.config = config; c.enabled = True; return {"name": name, "kind": kind, "updated": True}; } }
    ch = Channel(name=name, kind=kind, config=config, dm_scope=dm_scope);
    soul +>:Connects:+> ch;
    return {"name": name, "kind": kind, "updated": False};
}

def channel_remove(name: str) -> str {
    soul = awaken();
    for c in _channels(soul) { if c.name == name { del c; return "removed channel '" + name + "'"; } }
    return "no such channel: " + name;
}

def channel_list() -> list {
    soul = awaken();
    out: list = [];
    for c in _channels(soul) {
        msgs = [c -->[?:Message]];
        out.append({"name": c.name, "kind": c.kind, "enabled": c.enabled,
                    "dm_scope": c.dm_scope, "messages": len(msgs)});
    }
    return out;
}

def _get_channel(soul: Soul, name: str) -> Channel {
    for c in _channels(soul) { if c.name == name { return c; } }
    ch = Channel(name=name, kind="webhook");
    soul +>:Connects:+> ch;
    return ch;
}

def _record(ch: Channel, direction: str, peer: str, text: str) -> Message {
    m = Message(direction=direction, peer=peer, text=text, ts=_ts());
    ch +>:Carried:+> m;
    return m;
}

def inbound(channel: str, peer: str, text: str) -> dict {
    # The core loop: a message arrives on a channel -> the agent solves it ->
    # the reply is recorded as outbound (an adapter delivers it). The peer becomes
    # part of the routing key (per OpenClaw's dm_scope) — here, memory context.
    soul = awaken();
    ch = _get_channel(soul, channel);
    if not ch.enabled { return {"ok": False, "reply": "", "error": "channel disabled"}; }
    _record(ch, "in", peer, text);
    res = solve_task(text, "");
    reply = str(res["result"]);
    _record(ch, "out", peer, reply);
    return {"ok": True, "channel": channel, "peer": peer, "reply": reply,
            "signature": str(res["signature"])};
}

def message_send(channel: str, peer: str, text: str) -> dict {
    # Outbound send (agent-initiated / broadcast). The adapter for `channel`
    # delivers it; we record it on the graph.
    soul = awaken();
    ch = _get_channel(soul, channel);
    _record(ch, "out", peer, text);
    return {"ok": True, "channel": channel, "peer": peer, "text": text};
}

def channel_history(channel: str, n: int = 20) -> list {
    soul = awaken();
    for c in _channels(soul) {
        if c.name == channel {
            msgs = [{"dir": m.direction, "peer": m.peer, "text": m.text[:200], "ts": m.ts}
                    for m in [c -->[?:Message]]];
            return msgs[-n:];
        }
    }
    return [];
}
