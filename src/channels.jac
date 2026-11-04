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
import from .sigil_sessions { session_note, chat_history, chat_history_save }
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

def skill_channels_json() -> str {
    # The channels a compiled skill may message the user on (its `send_message`
    # builtin), as JSON [{name, kind}]: the enabled ones. "" when there are none
    # or SIGIL_SKILL_CHANNELS=0, and then the run is told it has nowhere to send.
    import os;
    import json;
    v = str(os.environ.get("SIGIL_SKILL_CHANNELS") or "").strip().lower();
    if v in ["0", "false", "no", "off"] { return ""; }
    rows = [{"name": str(c.name), "kind": str(c.kind)} for c in _channels(awaken()) if c.enabled];
    return json.dumps(rows) if rows else "";
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
    # The core loop: a message arrives on a channel -> the agent answers it ->
    # the reply is recorded as outbound (an adapter delivers it). The peer becomes
    # part of the routing key (per OpenClaw's dm_scope). The reply threads under
    # the inbound message so thread_id round-trips.
    #
    # Each channel conversation is an ongoing chat with the agent `sigil chat`
    # talks to, not a fresh task per message: a message is answered knowing what
    # was said before on this channel, and the agent reaches compiled skills as
    # its tools.
    #
    # A turn can run for minutes while other processes (the scheduler, the
    # console, a skill compile) commit to the graph, so this process's view goes
    # stale and saving the turn afterwards can be refused (WriteConflict). That
    # used to raise out of here and throw the finished reply away. Now the inbound
    # message is committed before the turn, the turn's records are saved after it
    # in one serialized write, and when that is refused a fresh process saves
    # them. The reply is returned whatever happens to the bookkeeping.
    import from .sigil_runtime { commit_now, graph_write }
    soul = awaken();
    ch = _get_channel(soul, channel);
    if not ch.enabled { return {"ok": False, "reply": "", "error": "channel disabled"}; }
    dm_scope = str(ch.dm_scope);
    kind = str(ch.kind);
    inm = _record(ch, "in", peer, text, thread_id);
    in_mid = str(inm.mid);
    fire_hooks("message_received", channel + ":" + peer + ": " + text);
    session_note(channel, peer, dm_scope, "user", text);   # transcript, scoped by dm_scope
    history = chat_history(channel, peer, dm_scope);
    commit_now("channel inbound " + channel);
    reply_thread = thread_id if thread_id else in_mid;
    new_history: any = None;
    interrupted = False;
    import from .sigil_channel_compile { channel_command, handle_command }
    cmd = channel_command(text);
    if cmd["cmd"] == "new" {
        new_history = [];
        reply = "Started a new conversation.";
    } elif cmd["cmd"] {
        # /build, /compile, /status, /help: answered here, without the model, and
        # kept in the conversation so the agent knows a compile is under way.
        import from .sigil_workspace { ws_root }
        reply = handle_command(channel, peer, cmd["cmd"], cmd["arg"], ws_root());
        new_history = list(history or []) + [{"role": "user", "content": str(text)},
                                             {"role": "assistant", "content": reply}];
    } else {
        import from .chat_agent { channel_chat_turn };
        res = channel_chat_turn(text, history, surface_hint(kind), channel, peer);
        new_history = list(res["history"]);
        reply = str(res["reply"]);
        interrupted = bool(res.get("interrupted"));
    }
    saved = record_turn(channel, peer, new_history, reply, reply_thread);
    if not saved["ok"] {
        saved = _record_turn_fresh(channel, peer, new_history, reply, reply_thread, str(saved["error"]));
    }
    return {"ok": True, "channel": channel, "peer": peer, "reply": reply,
            "signature": "chat", "in_mid": in_mid, "out_mid": str(saved.get("out_mid") or ""),
            "thread_id": reply_thread, "saved": bool(saved["ok"]), "interrupted": interrupted};
}

def record_turn(channel: str, peer: str, history: any, reply: str, thread_id: str) -> dict[str, any] {
    # The after-turn bookkeeping in one serialized write: the stored conversation,
    # the outbound Message and the transcript line. Reads the channel inside the
    # write, so a fresh process can run it too (the `channel_turn_record` API op).
    import from .sigil_runtime { graph_write }
    def _do() -> str {
        c = _get_channel(awaken(), channel);
        if history is not None { chat_history_save(channel, peer, str(c.dm_scope), list(history)); }
        m = _record(c, "out", peer, reply, thread_id);
        session_note(channel, peer, str(c.dm_scope), "assistant", reply);
        return str(m.mid);
    }
    r = graph_write(_do, "channel turn " + channel);
    return {"ok": bool(r["ok"]), "out_mid": str(r["data"] or ""), "error": str(r["error"])};
}

def _record_turn_fresh(channel: str, peer: str, history: any, reply: str, thread_id: str, why: str) -> dict[str, any] {
    import from .sigil_api { api_call, in_child }
    print("channel: saving the turn on " + channel + " failed in this process (" + why[:160] + "); retrying from a fresh one", flush=True);
    if in_child() { return {"ok": False, "out_mid": "", "error": why}; }
    r = api_call("channel_turn_record", {"channel": channel, "peer": peer, "history": history,
                                         "reply": reply, "thread_id": thread_id}, 300);
    d: any = r["data"] if r["ok"] else None;
    if isinstance(d, dict) and d.get("ok") { return {"ok": True, "out_mid": str(d.get("out_mid") or ""), "error": ""}; }
    err = str(d.get("error")) if isinstance(d, dict) else str(r["error"]);
    print("channel: the fresh save failed too: " + err[:200], flush=True);
    return {"ok": False, "out_mid": "", "error": err};
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
    if not str(peer or "").strip() {
        # An empty peer means "the user": the sender of the latest inbound. A
        # WhatsApp agent can only talk to the person who created it, at the
        # user:<id> WhatsApp puts on their messages, which nobody can type in;
        # a Telegram chat id or a Slack channel is just as unknown to a skill
        # that wants to report back, or to a scheduled job.
        peer = _last_inbound_peer(ch);
        if not peer {
            return {"ok": False, "error": "message the agent on " + str(ch.kind) + " first; Sigil learns where to reply from your message"};
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
