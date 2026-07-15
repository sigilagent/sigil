# Tests for sigil_channels_setup — annex (`jac test sigil_channels_setup.jac`).
# Guidance content + the one-call graph bootstrap. No model, no network.

import from .sigil_secrets { secret_list }

test "supported kinds cover the majors" {
    ks = channel_kinds();
    for k in ["discord", "telegram", "whatsapp", "slack"] { assert k in ks, k; }
}

test "setup guide: known kinds carry token env + endpoint; unknown is handled" {
    g = channel_setup_guide("telegram");
    assert "TELEGRAM_BOT_TOKEN" in g and "api_inbound" in g, g;
    d = channel_setup_guide("discord");
    assert "DISCORD_BOT_TOKEN" in d and "MESSAGE CONTENT INTENT" in d, d;
    assert "Unknown channel" in channel_setup_guide("nope");
}

test "bootstrap registers the channel node + a token SecretRef" {
    r = channel_bootstrap("tg", "telegram", "");
    assert r["kind"] == "telegram";
    assert r["token_env"] == "TELEGRAM_BOT_TOKEN";
    assert r["endpoint"] == "/walker/api_inbound";
    # a SecretRef named <name>_token now exists, mapped to the env var (value never stored)
    names = [str(s["name"]) for s in secret_list()];
    assert "tg_token" in names, str(names);
}
