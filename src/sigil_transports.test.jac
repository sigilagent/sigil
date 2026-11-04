# Tests for sigil_transports — annex of sigil_transports.jac.
# No network: what is asserted is the message shaping, which is where every
# provider disagrees and where a mistake is silent (a reply sent to the wrong
# thread, a bot answering itself, an outage read as a delivery).

test "telegram: a chat message becomes peer, text and a thread to reply on" {
    upd = {
        "update_id": 42,
        "message": {"message_id": 7, "chat": {"id": 12345}, "text": "hello there"}
    };
    m = normalize_inbound("telegram", upd);
    assert m["peer"] == "12345";
    assert m["text"] == "hello there";
    assert m["thread_id"] == "7";
}

test "telegram: non-text updates are not messages" {
    assert normalize_inbound("telegram", {"update_id": 1}) == {};
    assert normalize_inbound("telegram", {"message": {"chat": {"id": 1}}}) == {};
    # a sticker or a photo has no text — nothing to answer, and no crash
    assert normalize_inbound("telegram", {"message": {"chat": {"id": 1}, "sticker": {}}}) == {};
}

test "slack: the url_verification handshake is echoed, not treated as a message" {
    m = normalize_inbound("slack", {"type": "url_verification", "challenge": "abc123"});
    assert m["challenge"] == "abc123";
    assert "text" not in m;
}

test "slack: the bot's own messages are ignored so it cannot answer itself" {
    echo = {"event": {"channel": "C1", "text": "hi", "bot_id": "B1", "ts": "1.0"}};
    assert normalize_inbound("slack", echo) == {};
    sub = {"event": {"channel": "C1", "text": "hi", "subtype": "bot_message", "ts": "1.0"}};
    assert normalize_inbound("slack", sub) == {};
}

test "slack: a threaded reply keeps the thread, a top-level one starts from its ts" {
    threaded = {"event": {"channel": "C1", "text": "yes", "ts": "2.0", "thread_ts": "1.0"}};
    assert normalize_inbound("slack", threaded)["thread_id"] == "1.0";
    top = {"event": {"channel": "C1", "text": "yes", "ts": "2.0"}};
    assert normalize_inbound("slack", top)["thread_id"] == "2.0";
}

test "whatsapp: the message is dug out of the nested envelope" {
    body = {"entry": [{"changes": [{"value": {"messages": [
        {"from": "15551234", "id": "wamid.1", "text": {"body": "hi"}}
    ]}}]}]};
    m = normalize_inbound("whatsapp", body);
    assert m["peer"] == "15551234";
    assert m["text"] == "hi";
    # a status callback has the same envelope shape and no messages at all
    assert normalize_inbound("whatsapp", {"entry": [{"changes": [{"value": {"statuses": []}}]}]}) == {};
    assert normalize_inbound("whatsapp", {}) == {};
}

test "the plain webhook contract is {channel, peer, text}" {
    m = normalize_inbound("webhook", {"channel": "ops", "peer": "u1", "text": "ping"});
    assert m["peer"] == "u1";
    assert m["text"] == "ping";
    assert normalize_inbound("webhook", {"peer": "u1"}) == {};
}

test "delivery refuses what it cannot send instead of reporting success" {
    assert not deliver("telegram", "", "1", "hi")["ok"], "no token is not a delivery";
    assert not deliver("telegram", "tok", "1", "")["ok"], "an empty message is not a delivery";
    # a WhatsApp agent addresses user:<id> from an inbound message, never a bare number
    assert not deliver("whatsapp", "tok", "15551234", "hi")["ok"], "a bare number is not an agent recipient";
    assert not deliver("webhook", "", "1", "hi")["ok"];
}

test "a channel with no wire is recorded, and says so" {
    r = deliver("cli", "", "me", "hi");
    assert r["ok"];
    assert "recorded only" in str(r["note"]);
}

test "a provider that answers 200 and ok:false is a failure, not a success" {
    # Both Telegram and Slack report errors this way. Reading HTTP 200 as
    # delivered is how a message that never arrived looks like one that did.
    assert not _provider_ok({"ok": True, "error": "",
                             "body": {"ok": False, "description": "chat not found"}}, "ok")["ok"];
    assert _provider_ok({"ok": True, "error": "", "body": {"ok": True}}, "ok")["ok"];
    assert not _provider_ok({"ok": False, "error": "timed out", "body": {}}, "ok")["ok"];
    # Discord answers with the created message and no `ok` key at all
    assert _provider_ok({"ok": True, "error": "", "body": {"id": "999"}}, "")["ok"];
}

test "only telegram polls; everything else waits to be pushed" {
    assert supports_polling("telegram");
    assert supports_polling("whatsapp"), "the Agent Platform long-polls";
    assert not supports_polling("whatsapp", "15551234"), "a phone-number id is the Cloud API webhook";
    assert not supports_polling("slack");
    assert not supports_polling("webhook");
    assert not supports_polling("");
}

test "whatsapp agent platform: every text message in /updates, with its timestamp" {
    body = {"object": "whatsapp_agent_platform", "next_offset": 1288, "entry": [{"id": "1", "changes": [{
        "field": "messages", "value": {
            "messaging_product": "whatsapp",
            "contacts": [{"wa_id": "user:509", "profile": {"name": "Alex"}}],
            "messages": [
                {"from": "user:509", "id": "wamid.A", "timestamp": "1736844652", "type": "text", "text": {"body": "hello agent"}},
                {"from": "user:509", "id": "wamid.B", "timestamp": "1736844653", "type": "reaction", "reaction": {"message_id": "wamid.A", "emoji": "x"}},
                {"from": "user:509", "id": "wamid.C", "timestamp": "1736844660", "type": "text", "text": {"body": "and again"}}
            ],
            "statuses": [{"id": "wamid.Z", "status": "read", "recipient_id": "user:509", "timestamp": "1736844650"}]
        }}]}]};
    got = whatsapp_messages(body);
    assert len(got) == 2, str(got);
    assert got[0]["peer"] == "user:509" and got[0]["text"] == "hello agent";
    assert got[0]["thread_id"] == "wamid.A" and got[0]["ts"] == 1736844652;
    assert got[1]["text"] == "and again";
    # the webhook path still sees the first message
    assert normalize_inbound("whatsapp", body)["thread_id"] == "wamid.A";
    assert whatsapp_messages({}) == [];
}
