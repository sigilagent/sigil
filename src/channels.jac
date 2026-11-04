"""Channels — OpenClaw parity: the messaging surface + the inbound→agent→reply loop.

OpenClaw ships ~27 channel plugins (discord/slack/telegram/whatsapp/matrix/imessage/…);
they all reduce to one contract: an inbound message routes to the agent, the agent's
reply goes back out. Sigil models that contract on the graph — a Channel node is
config (like OpenClaw's channel plugin registration), and `inbound()` is the loop. A
concrete adapter (a Discord bot, a webhook) just calls `inbound()` and delivers `outbound`;
the `api_inbound` HTTP endpoint IS a ready webhook channel.
"""

import from .sigil_core { awaken, Soul }
import from .hooks { fire_hooks }
import from .sigil_sessions { session_note, chat_history, chat_history_save, chat_history_reset }
import from .sigil_secrets { resolve_credential }
import from .sigil_transports { deliver }
import from .sigil_api { report_for }

edge Connects: any --> any {}    # Soul -> Channel
edge Carried: any --> any {}     # Channel -> Message

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
    has mid: str = "";              # stable message id — adapters reference it for react/edit/thread
    has thread_id: str = "";        # thread linkage (empty = top-level)
    has reactions: list[str] = [];  # emoji reactions applied to this message
    has edited: bool = False;       # set once the message text has been edited
}

def _ts() -> float {
    import time;
    return time.time();
}

def _mid() -> str {
    import uuid;
    return str(uuid.uuid4()).split("-")[0];
}

def _channels(soul: Soul) -> list[Channel] { return [soul -->[?:Channel]]; }

def channel_add(name: str, kind: str, config: str = "", dm_scope: str = "per-peer") -> dict[str, any] {
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

def channel_list() -> list[any] {
    soul = awaken();
    out: list[any] = [];
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

def _record(ch: Channel, direction: str, peer: str, text: str, thread_id: str = "") -> Message {
    m = Message(direction=direction, peer=peer, text=text, ts=_ts(), mid=_mid(), thread_id=thread_id);
    ch +>:Carried:+> m;
    return m;
}

def inbound(channel: str, peer: str, text: str, thread_id: str = "") -> dict[str, any] {
    # The core loop: a message arrives on a channel -> the agent solves it ->
    # the reply is recorded as outbound (an adapter delivers it). The peer becomes
    # part of the routing key (per OpenClaw's dm_scope) — here, memory context.
    # The reply threads under the inbound message so thread_id round-trips.
    soul = awaken();
    ch = _get_channel(soul, channel);
    if not ch.enabled { return {"ok": False, "reply": "", "error": "channel disabled"}; }
    inm = _record(ch, "in", peer, text, thread_id);
    fire_hooks("message_received", channel + ":" + peer + ": " + text);
    session_note(channel, peer, ch.dm_scope, "user", text);   # transcript, scoped by dm_scope
    # Each channel conversation is an ongoing chat with the agent `sigil chat`
    # talks to, not a fresh task per message: a message is answered knowing what
    # was said before on this channel, and the agent reaches compiled skills as
    # its tools. (Routing every message through the task solver compiled a "Hi"
    # into a greeting skill and sent its raw output back.)
    if str(text).strip().lower() in ["/new", "/reset"] {
        chat_history_reset(channel, peer, ch.dm_scope);
        reply = "Started a new conversation.";
    } else {
        import from .chat_agent { channel_chat_turn };
        res = channel_chat_turn(text, chat_history(channel, peer, ch.dm_scope), surface_hint(str(ch.kind)));
        chat_history_save(channel, peer, ch.dm_scope, list(res["history"]));
        reply = str(res["reply"]);
    }
    reply_thread = thread_id if thread_id else inm.mid;
    outm = _record(ch, "out", peer, reply, reply_thread);
    session_note(channel, peer, ch.dm_scope, "assistant", reply);
    return {"ok": True, "channel": channel, "peer": peer, "reply": reply,
            "signature": "chat", "in_mid": inm.mid, "out_mid": outm.mid, "thread_id": reply_thread};
}

def surface_hint(kind: str) -> str {
    # Where the reply is read, for the model's formatting. Chat apps render
    # little markdown, and a reply is read on a phone.
    k = str(kind or "").lower();
    if k == "whatsapp" {
        return "a WhatsApp chat on the user's phone: reply in short plain text. WhatsApp renders *bold*, _italic_ and ```code``` only; no headings, tables or [text](url) links.";
    }
    if k == "telegram" {
        return "a Telegram chat: reply in short plain text; no markdown headings or tables.";
    }
    if k in ["slack", "discord"] {
        return "a " + k.capitalize() + " chat: keep replies short; light markdown is fine, no headings or tables.";
    }
    return "a messaging channel (" + (k or "webhook") + "): keep replies short and plain.";
}

def channel_credentials(ch: Channel) -> list[str] {
    # [token, target]. `config` holds a `secret:<name>` reference, never a value —
    # resolved from the environment at send time so the token stays off the graph
    # and out of anything that prints it. "<credential>|<target>" carries the
    # second coordinate some providers need (a WhatsApp phone id, a webhook URL).
    raw = str(ch.config or "");
    if not raw { return ["", ""]; }
    resolved = str(resolve_credential(raw));
    if "|" in resolved {
        bits = resolved.split("|", 1);
        return [bits[0].strip(), bits[1].strip()];
    }
    return [resolved, ""];
}

def message_send(channel: str, peer: str, text: str, thread_id: str = "") -> dict[str, any] {
    # Outbound send. This used to write a Message node and stop — the graph said
    # "sent" and nothing left the machine. Now it goes over the channel's actual
    # transport, and the record says which of those two things happened.
    soul = awaken();
    ch = _get_channel(soul, channel);
    creds = channel_credentials(ch);
    if (not str(peer or "").strip()) and (str(ch.kind) == "whatsapp") and (not str(creds[1])) {
        # A WhatsApp agent can only talk to the person who created it, at the
        # user:<id> WhatsApp puts on their messages, which nobody can type
        # in. So an empty peer means "them": the sender of the latest inbound.
        peer = _last_inbound_peer(ch);
        if not peer {
            return {"ok": False, "error": "message your agent from WhatsApp first; Sigil learns where to reply from your message"};
        }
    }
    m = _record(ch, "out", peer, text, thread_id);
    sent = deliver(ch.kind, str(creds[0]), peer, text, thread_id, str(creds[1]));
    out = {"ok": True, "channel": channel, "peer": peer, "text": text,
           "mid": m.mid, "thread_id": thread_id, "delivered": bool(sent["ok"])};
    if not sent["ok"] { out["delivery_error"] = str(sent["error"]); }
    if sent.get("note") { out["note"] = str(sent["note"]); }
    return out;
}

def _last_inbound_peer(ch: Channel) -> str {
    best = "";
    best_ts = -1.0;
    for m in [ch -->[?:Message]] {
        if (str(m.direction) == "in") and m.peer and (float(m.ts or 0) >= best_ts) {
            best = str(m.peer);
            best_ts = float(m.ts or 0);
        }
    }
    return best;
}

def react(channel: str, mid: str, emoji: str) -> str {
    # Apply an emoji reaction to a prior message (by its stable mid).
    soul = awaken();
    for c in _channels(soul) {
        if c.name == channel {
            for m in [c -->[?:Message]] {
                if m.mid == mid { m.reactions = m.reactions + [emoji]; return "reacted " + emoji + " on " + mid; }
            }
        }
    }
    return "no message " + mid + " on channel " + channel;
}

def edit(channel: str, mid: str, text: str) -> str {
    # Edit a prior message's text in place (marks it edited).
    soul = awaken();
    for c in _channels(soul) {
        if c.name == channel {
            for m in [c -->[?:Message]] {
                if m.mid == mid { m.text = text; m.edited = True; return "edited " + mid; }
            }
        }
    }
    return "no message " + mid + " on channel " + channel;
}

def channel_history(channel: str, n: int = 20) -> list[any] {
    soul = awaken();
    for c in _channels(soul) {
        if c.name == channel {
            msgs = [{"mid": m.mid, "dir": m.direction, "peer": m.peer, "text": m.text[:200],
                     "thread": m.thread_id, "reactions": m.reactions, "edited": m.edited, "ts": m.ts}
                    for m in [c -->[?:Message]]];
            return msgs[-n:];
        }
    }
    return [];
}

# ---------------------------------------------------------------------------
# Webhook endpoint — the ready-made inbound surface every channel adapter POSTs
# to. A Discord bot / Telegram webhook / Slack Events app forwards each message
# here as {channel, peer, text[, thread_id]}; the agent's reply comes back in the
# body so the adapter can deliver it on the originating thread.
#   POST /walker/api_inbound   {"channel":"tg","peer":"123","text":"hi"}
# ---------------------------------------------------------------------------
walker:pub api_inbound {
    has channel: str = "webhook";
    has peer: str = "anon";
    has text: str = "";
    has thread_id: str = "";
    can run with Root entry {
        report report_for("inbound", {"channel": self.channel, "peer": self.peer,
                                      "text": self.text, "thread_id": self.thread_id});
    }
}
