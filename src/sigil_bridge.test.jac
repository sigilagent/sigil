# Tests for sigil_bridge — annex of sigil_bridge.jac.
# No provider is contacted and no bridge is started: what is asserted is the
# bookkeeping that decides whether a message gets answered twice.

import os;
import from .channels { channel_add, channel_remove }

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
