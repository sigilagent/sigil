# Tests for sigil_bridge — annex of sigil_bridge.jac.
# No provider is contacted and no bridge is started: what is asserted is the
# bookkeeping that decides whether a message gets answered twice.

import os;
import from .channels { channel_add, channel_remove, message_send, _get_channel, _record, inbound, surface_hint }

test "the long-poll cursor survives a restart" {
    # Without a persisted cursor, a restarted bridge re-fetches updates Telegram
    # still considers unacknowledged and answers the same message again.
    chan = "_t_offset_channel";
    write_offset(chan, 0);
    assert read_offset(chan) == 0;
    write_offset(chan, 918273);
    assert read_offset(chan) == 918273;
    try { os.remove(offset_path(chan)); } except Exception as e { }
    assert read_offset(chan) == 0, "a missing cursor starts from the beginning, not from junk";
}

test "each channel's bridge gets its own pidfile and cursor" {
    assert bridge_pid_name("ops") == "bridge-ops";
    assert bridge_pid_name("ops") != bridge_pid_name("alerts");
    assert offset_path("ops") != offset_path("alerts");
    assert offset_path("ops").endswith("bridge-ops.offset");
}

test "a channel that does not exist is refused, not silently idled" {
    r = bridge_run("_t_no_such_channel_at_all");
    assert not r["ok"];
    assert "no such channel" in str(r["error"]);
}

test "channel_config splits credential from target and reports what is missing" {
    cfg = channel_config("_t_no_such_channel_at_all");
    assert not cfg["found"];

    channel_add("_t_cfg_probe", "webhook", "https://example.invalid/hook", "per-peer");
    got = channel_config("_t_cfg_probe");
    assert got["found"];
    assert got["kind"] == "webhook";
    assert str(got["token"]) == "https://example.invalid/hook";
    assert str(got["target"]) == "";
    channel_remove("_t_cfg_probe");

    # "<credential>|<target>" carries the second coordinate some providers need
    channel_add("_t_cfg_pair", "whatsapp", "TOKENVALUE|15551234", "per-peer");
    pair = channel_config("_t_cfg_pair");
    assert str(pair["token"]) == "TOKENVALUE";
    assert str(pair["target"]) == "15551234";
    channel_remove("_t_cfg_pair");
}

test "a disabled channel does not get a bridge" {
    channel_add("_t_disabled", "telegram", "sometoken", "per-peer");
    soul = awaken();
    for c in _channels(soul) { if c.name == "_t_disabled" { c.enabled = False; } }
    r = bridge_run("_t_disabled");
    assert not r["ok"];
    assert "disabled" in str(r["error"]);
    channel_remove("_t_disabled");
}

test "a polling channel with no credential is refused with the reason" {
    channel_add("_t_no_token", "telegram", "secret:_t_missing_env", "per-peer");
    r = bridge_run("_t_no_token");
    assert not r["ok"];
    assert "credential" in str(r["error"]);
    channel_remove("_t_no_token");
}

test "a WhatsApp agent send with no peer goes to whoever last wrote to it" {
    # An agent may only message its creator, at a user:<id> nobody can type in,
    # so an empty peer resolves to the sender of the latest inbound message.
    channel_add("_t_wa_agent", "whatsapp", "", "per-peer");
    r = message_send("_t_wa_agent", "", "hello");
    assert not r["ok"] and ("message the agent on whatsapp first" in str(r["error"])), str(r);
    ch = _get_channel(awaken(), "_t_wa_agent");
    _record(ch, "in", "user:7", "hi agent", "wamid.T");
    r2 = message_send("_t_wa_agent", "", "hello");
    assert r2["ok"] and (r2["peer"] == "user:7"), str(r2);
    channel_remove("_t_wa_agent");
}

test "any channel's send with no peer goes to whoever last wrote, so a skill can report back" {
    import from .channels { skill_channels_json }
    channel_add("_t_tg_back", "telegram", "", "per-peer");
    r = message_send("_t_tg_back", "", "done");
    assert not r["ok"] and ("message the agent on telegram first" in str(r["error"])), str(r);
    _record(_get_channel(awaken(), "_t_tg_back"), "in", "12345", "hi", "");
    r2 = message_send("_t_tg_back", "", "done");
    assert r2["ok"] and (r2["peer"] == "12345"), str(r2);
    assert "_t_tg_back" in skill_channels_json();
    channel_remove("_t_tg_back");
}

test "/new on a channel starts its conversation over without a model call" {
    import from .sigil_sessions { chat_history, chat_history_save }
    channel_add("_t_chat_new", "telegram", "", "per-peer");
    chat_history_save("_t_chat_new", "42", "per-peer", [{"role": "user", "content": "earlier"}]);
    r = inbound("_t_chat_new", "42", "/new", "");
    assert r["ok"] and ("new conversation" in str(r["reply"])), str(r);
    assert chat_history("_t_chat_new", "42", "per-peer") == [];
    channel_remove("_t_chat_new");
}

test "/help and /build are answered without a model call, and stay in the conversation" {
    import from .sigil_sessions { chat_history, chat_history_save }
    channel_add("_t_chat_cmd", "telegram", "", "per-peer");
    chat_history_save("_t_chat_cmd", "42", "per-peer", [{"role": "user", "content": "earlier"}]);
    r = inbound("_t_chat_cmd", "42", "/help", "");
    assert r["ok"] and ("/build" in str(r["reply"])), str(r);
    b = inbound("_t_chat_cmd", "42", "/build", "");
    assert "no drafted agent" in str(b["reply"]), str(b);
    h = chat_history("_t_chat_cmd", "42", "per-peer");
    assert [m["content"] for m in h][:3] == ["earlier", "/help", str(r["reply"])], str(h);
    channel_remove("_t_chat_cmd");
}

test "the model is told where its reply is read" {
    assert "WhatsApp" in surface_hint("whatsapp") and "no headings" in surface_hint("whatsapp");
    assert "Telegram" in surface_hint("telegram");
    assert "short" in surface_hint("webhook");
}
