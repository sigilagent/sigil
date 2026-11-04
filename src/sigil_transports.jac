"""Channel transports — the wire under channels.jac.

`channels.jac` models the contract: a Channel node, an inbound loop, a Message
record. Until now nothing carried a byte. `message_send` wrote a Message to the
graph and stopped, every provider guide pointed at an endpoint that was never
served, and a cron job with a delivery target delivered to nobody.

This module is the wire, and only the wire: HTTP in, HTTP out, no graph. That
separation is what lets `channels.jac` import it without a cycle, and it makes
the fiddly half — each provider's idea of a message — testable without a token.

Two directions per provider:

  deliver()           the agent's reply, out to the provider
  normalize_inbound() the provider's payload, in to {peer, text, thread_id}

Telegram and WhatsApp also support long polling (`poll_telegram`,
`poll_whatsapp_agent`), the transports that need no public URL, no tunnel and no
extra dependency, so they work the moment you paste a token. WhatsApp's is the
Agent Platform (api.whatsapp.com/agent/v1): an agent a person creates in their
own WhatsApp app (Settings → Agents), whose API key is the whole credential. It
can only talk to the person who created it, which is what a personal agent is.
A WhatsApp channel whose config carries a phone-number id is the older Cloud
API instead, and that one pushes to a webhook.
"""

import json;
import from urllib.request { Request, urlopen }
import from urllib.parse { urlencode }

glob TELEGRAM_API: str = "https://api.telegram.org/bot";
glob SLACK_API: str = "https://slack.com/api/";
glob DISCORD_API: str = "https://discord.com/api/v10/";
glob GRAPH_API: str = "https://graph.facebook.com/v20.0/";
glob WA_AGENT_API: str = "https://api.whatsapp.com/agent/v1/";

# Providers whose inbound arrives by us asking (poll) rather than them pushing.
glob POLLING_KINDS: list[str] = ["telegram", "whatsapp"];
# Providers that push to a URL we have to be listening on.
glob WEBHOOK_KINDS: list[str] = ["slack", "webhook", "discord"];

def supports_polling(kind: str, target: str = "") -> bool {
    # WhatsApp polls on the Agent Platform. A config carrying a phone-number id
    # (`target`) is the Cloud API, which pushes to a webhook instead.
    k = str(kind or "").lower();
    if (k == "whatsapp") and target { return False; }
    return k in POLLING_KINDS;
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def http_json(url: str, payload: any, headers: dict[str, any], timeout: int = 30) -> dict[str, any] {
    # One request, one dict back. Never raises: a provider being down is a
    # delivery failure to report, not a reason to take a bridge process with it.
    body = None;
    hdrs = dict(headers or {});
    if payload is not None {
        body = json.dumps(payload).encode("utf-8");
        hdrs["Content-Type"] = "application/json";
    }
    raw = "";
    try {
        req = Request(url, data=body, headers=hdrs, method=("POST" if body else "GET"));
        resp = urlopen(req, timeout=timeout);
        raw = str(resp.read().decode("utf-8", errors="replace"));
        resp.close();
    } except Exception as e {
        return {"ok": False, "error": str(e)[:300], "body": {}};
    }
    parsed: any = {};
    try {
        parsed = json.loads(raw or "{}");
    } except Exception as ex {
        return {"ok": True, "error": "", "body": {"raw": raw[:2000]}};
    }
    shaped: dict[str, any] = dict(parsed) if isinstance(parsed, dict) else {"items": parsed};
    return {"ok": True, "error": "", "body": shaped};
}

# ---------------------------------------------------------------------------
# Outbound
# ---------------------------------------------------------------------------
def deliver(kind: str, token: str, peer: str, text: str,
            thread_id: str = "", target: str = "") -> dict[str, any] {
    # `target` is the provider's second coordinate where one is needed — a
    # WhatsApp phone-number id, or the full URL for a plain webhook.
    k = str(kind or "").lower().strip();
    msg = str(text or "");
    if not msg { return {"ok": False, "error": "nothing to send"}; }
    if k == "telegram" {
        if not token { return {"ok": False, "error": "no telegram bot token"}; }
        body = {"chat_id": peer, "text": msg[:4096]};
        if thread_id { body["reply_to_message_id"] = thread_id; }
        r = http_json(TELEGRAM_API + token + "/sendMessage", body, {});
        return _provider_ok(r, "ok");
    }
    if k == "slack" {
        if not token { return {"ok": False, "error": "no slack bot token"}; }
        body = {"channel": peer, "text": msg};
        if thread_id { body["thread_ts"] = thread_id; }
        r = http_json(SLACK_API + "chat.postMessage", body,
                      {"Authorization": "Bearer " + token});
        return _provider_ok(r, "ok");
    }
    if k == "discord" {
        if not token { return {"ok": False, "error": "no discord bot token"}; }
        r = http_json(DISCORD_API + "channels/" + str(peer) + "/messages",
                      {"content": msg[:2000]}, {"Authorization": "Bot " + token});
        return _provider_ok(r, "");
    }
    if k == "whatsapp" {
        if not token { return {"ok": False, "error": "no whatsapp token"}; }
        if not target {
            # The Agent Platform addresses a person as "user:<id>", taken from
            # an inbound message, and only the agent's creator. It rejects a
            # bare phone number, so refuse it here rather than spend a request.
            if not str(peer).startswith("user:") {
                return {"ok": False, "error": "a WhatsApp agent replies to a user:<id> from an inbound message, and only to the person who created it"};
            }
            r = http_json(WA_AGENT_API + "messages",
                          {"messaging_product": "whatsapp", "to": str(peer),
                           "type": "text", "text": {"body": msg[:4096]}},
                          {"Authorization": "Bearer " + token});
            return _provider_ok(r, "");
        }
        r = http_json(GRAPH_API + str(target) + "/messages",
                      {"messaging_product": "whatsapp", "to": peer,
                       "type": "text", "text": {"body": msg}},
                      {"Authorization": "Bearer " + token});
        return _provider_ok(r, "");
    }
    if k == "webhook" {
        url = target or token;   # a plain webhook's "credential" IS its URL
        if not url { return {"ok": False, "error": "no webhook url configured"}; }
        r = http_json(url, {"peer": peer, "text": msg, "thread_id": thread_id}, {});
        return _provider_ok(r, "");
    }
    # cli and anything unrecognised: the Message on the graph IS the delivery
    return {"ok": True, "note": "no transport for kind '" + k + "' — recorded only"};
}

def _provider_ok(r: dict[str, any], ok_key: str) -> dict[str, any] {
    # Providers answer 200 and then tell you it failed in the body. Slack and
    # Telegram both do it; treating HTTP 200 as success is how a silent
    # non-delivery looks like a delivery.
    if not r["ok"] { return {"ok": False, "error": str(r["error"])}; }
    body = dict(r.get("body") or {});
    if ok_key and (ok_key in body) and (not body[ok_key]) {
        return {"ok": False, "error": str(body.get("description") or body.get("error") or body)[:200]};
    }
    return {"ok": True};
}

# ---------------------------------------------------------------------------
# Inbound normalization — every provider's payload, one shape
# ---------------------------------------------------------------------------
def normalize_inbound(kind: str, body: dict[str, any]) -> dict[str, any] {
    # Returns {"peer","text","thread_id"} for a real message, {} for anything
    # else (an edit, a bot echo, a delivery receipt), or {"challenge": "..."} for
    # a handshake the caller must echo back verbatim.
    k = str(kind or "").lower().strip();
    b = dict(body or {});
    if k == "telegram" {
        msg = dict(b.get("message") or b.get("edited_message") or {});
        chat = dict(msg.get("chat") or {});
        text = str(msg.get("text") or "");
        if (not text) or (not chat.get("id")) { return {}; }
        return {"peer": str(chat["id"]), "text": text, "thread_id": str(msg.get("message_id") or "")};
    }
    if k == "slack" {
        # url_verification is Slack's "prove you own this endpoint" handshake
        if b.get("challenge") { return {"challenge": str(b["challenge"])}; }
        ev = dict(b.get("event") or {});
        text = str(ev.get("text") or "");
        # a bot's own message arrives like any other; replying to it is a loop
        if ev.get("bot_id") or (str(ev.get("subtype") or "") == "bot_message") { return {}; }
        if (not text) or (not ev.get("channel")) { return {}; }
        return {"peer": str(ev["channel"]), "text": text,
                "thread_id": str(ev.get("thread_ts") or ev.get("ts") or "")};
    }
    if k == "whatsapp" {
        got = whatsapp_messages(b);
        if not got { return {}; }
        one = dict(got[0]);
        return {"peer": str(one["peer"]), "text": str(one["text"]), "thread_id": str(one["thread_id"])};
    }
    # the plain contract: {channel, peer, text[, thread_id]}
    text = str(b.get("text") or "");
    if not text { return {}; }
    return {"peer": str(b.get("peer") or "anon"), "text": text,
            "thread_id": str(b.get("thread_id") or "")};
}

def whatsapp_messages(body: dict[str, any]) -> list[any] {
    # Every text message in a WhatsApp envelope, as {peer, text, thread_id, ts}.
    # The Cloud API webhook and the Agent Platform's /updates share the shape
    # entry[].changes[].value.messages[]; receipts ride in value.statuses.
    out: list[any] = [];
    try {
        for wh_entry in list(dict(body or {}).get("entry") or []) {
            for change in list(dict(wh_entry).get("changes") or []) {
                value = dict(dict(change).get("value") or {});
                for raw in list(value.get("messages") or []) {
                    msg = dict(raw);
                    text = str(dict(msg.get("text") or {}).get("body") or "");
                    if (not text) or (not msg.get("from")) { continue; }
                    ts = 0;
                    try { ts = int(str(msg.get("timestamp") or "0")); } except Exception as e { ts = 0; }
                    out.append({"peer": str(msg["from"]), "text": text,
                                "thread_id": str(msg.get("id") or ""), "ts": ts});
                }
            }
        }
    } except Exception as ex {
        return out;
    }
    return out;
}

def acknowledge(kind: str, token: str, target: str, thread_id: str) -> None {
    # Tell the person their message landed while the agent thinks, which takes
    # a while. WhatsApp agents: mark it read and show "typing…" (lasts ~25s).
    # Best effort: a failed receipt must never stop the reply.
    if (str(kind or "").lower() == "whatsapp") and token and (not target) and thread_id {
        http_json(WA_AGENT_API + "statuses",
                  {"messaging_product": "whatsapp", "status": "read", "message_id": thread_id,
                   "typing_indicator": {"type": "text"}},
                  {"Authorization": "Bearer " + token}, 10);
    }
    return None;
}

# ---------------------------------------------------------------------------
# WhatsApp Agent Platform long polling
# ---------------------------------------------------------------------------
def poll_whatsapp_agent(token: str, offset: int, timeout: int = 25, min_ts: int = 0) -> dict[str, any] {
    # Returns {"ok", "messages": [{peer,text,thread_id,ts}], "offset": next, "error"}.
    # Pass `next_offset` back unchanged. An offset of 0 replays the 30-day
    # backlog, so a first-ever poll passes `min_ts` to skip what predates the
    # bridge rather than answer a month of old messages. A 204 (nothing before
    # the timeout) carries no next_offset: keep polling at the same one.
    if not token { return {"ok": False, "messages": [], "offset": offset, "error": "no token"}; }
    qs = urlencode({"offset": (offset if offset > 0 else 0), "limit": 100, "timeout": timeout});
    r = http_json(WA_AGENT_API + "updates?" + qs, None, {"Authorization": "Bearer " + token}, timeout + 10);
    if not r["ok"] { return {"ok": False, "messages": [], "offset": offset, "error": str(r["error"])}; }
    body = dict(r.get("body") or {});
    nxt = offset;
    if body.get("next_offset") is not None {
        try { nxt = int(body["next_offset"]); } except Exception as e { nxt = offset; }
    }
    msgs = [m for m in whatsapp_messages(body) if int(m["ts"]) >= min_ts];
    return {"ok": True, "messages": msgs, "offset": nxt, "error": ""};
}

# ---------------------------------------------------------------------------
# Telegram long polling — inbound with no public URL and no tunnel
# ---------------------------------------------------------------------------
def poll_telegram(token: str, offset: int, timeout: int = 25) -> dict[str, any] {
    # Returns {"ok", "messages": [{peer,text,thread_id}], "offset": next, "error"}.
    # The long poll holds the connection open until something arrives, so this is
    # near-instant delivery without a webhook — hence the generous read timeout.
    if not token { return {"ok": False, "messages": [], "offset": offset, "error": "no token"}; }
    qs = urlencode({"timeout": timeout, "offset": offset});
    r = http_json(TELEGRAM_API + token + "/getUpdates?" + qs, None, {}, timeout + 10);
    if not r["ok"] { return {"ok": False, "messages": [], "offset": offset, "error": str(r["error"])}; }
    body = dict(r.get("body") or {});
    if not body.get("ok") {
        return {"ok": False, "messages": [], "offset": offset,
                "error": str(body.get("description") or body)[:200]};
    }
    msgs: list[any] = [];
    nxt = offset;
    for upd in list(body.get("result") or []) {
        u = dict(upd);
        uid = int(u.get("update_id") or 0);
        if uid >= nxt { nxt = uid + 1; }   # ack: never replay a handled update
        one = normalize_inbound("telegram", u);
        if one.get("text") { msgs.append(one); }
    }
    return {"ok": True, "messages": msgs, "offset": nxt, "error": ""};
}
