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

Telegram additionally supports long polling (`poll_telegram`), which is the one
transport that needs no public URL, no tunnel and no extra dependency — so it is
the one that works the moment you paste a token.
"""

import json;
import from urllib.request { Request, urlopen }
import from urllib.parse { urlencode }

glob TELEGRAM_API: str = "https://api.telegram.org/bot";
glob SLACK_API: str = "https://slack.com/api/";
glob DISCORD_API: str = "https://discord.com/api/v10/";
glob GRAPH_API: str = "https://graph.facebook.com/v20.0/";

# Providers whose inbound arrives by us asking (poll) rather than them pushing.
glob POLLING_KINDS: list[str] = ["telegram"];
# Providers that push to a URL we have to be listening on.
glob WEBHOOK_KINDS: list[str] = ["slack", "whatsapp", "webhook", "discord"];

def supports_polling(kind: str) -> bool {
    return str(kind or "").lower() in POLLING_KINDS;
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
def http_json(url: str, payload: any, headers: dict, timeout: int = 30) -> dict {
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
    shaped: dict = dict(parsed) if isinstance(parsed, dict) else {"items": parsed};
    return {"ok": True, "error": "", "body": shaped};
}

# ---------------------------------------------------------------------------
# Outbound
# ---------------------------------------------------------------------------
def deliver(kind: str, token: str, peer: str, text: str,
            thread_id: str = "", target: str = "") -> dict {
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
        if not target { return {"ok": False, "error": "whatsapp needs a phone-number id"}; }
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

def _provider_ok(r: dict, ok_key: str) -> dict {
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
def normalize_inbound(kind: str, body: dict) -> dict {
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
        try {
            entry = list(b.get("entry") or [])[0];
            change = list(dict(entry).get("changes") or [])[0];
            value = dict(dict(change).get("value") or {});
            msg = dict(list(value.get("messages") or [])[0]);
        } except Exception as e {
            return {};
        }
        text = str(dict(msg.get("text") or {}).get("body") or "");
        if (not text) or (not msg.get("from")) { return {}; }
        return {"peer": str(msg["from"]), "text": text, "thread_id": str(msg.get("id") or "")};
    }
    # the plain contract: {channel, peer, text[, thread_id]}
    text = str(b.get("text") or "");
    if not text { return {}; }
    return {"peer": str(b.get("peer") or "anon"), "text": text,
            "thread_id": str(b.get("thread_id") or "")};
}

# ---------------------------------------------------------------------------
# Telegram long polling — inbound with no public URL and no tunnel
# ---------------------------------------------------------------------------
def poll_telegram(token: str, offset: int, timeout: int = 25) -> dict {
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
    msgs: list = [];
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
