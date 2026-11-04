"""Channel setup guidance — how to actually connect Discord / Telegram / WhatsApp /
Slack to Sigil.

Sigil's messaging contract is one webhook: an adapter forwards each inbound message
to `POST /walker/api_inbound` as {channel, peer, text}, and delivers the reply that
comes back. `channel_setup_guide(kind)` returns provider-specific, step-by-step
instructions (where to get the token, which env var to set, how to point the webhook
or run the bridge). `channel_bootstrap(name, kind, token_env)` does the graph side in
one call: registers the Channel node and a SecretRef for its token, then hands back
the guide + the exact endpoint URL to wire up. This is exposed from the CLI
(`channel setup`/`channel connect`), from chat (the `connect_channel` tool), and from
the REPL (`/channels`, `/channel <kind>`). `connect` alone means model providers.
"""

import os;
import from .sigil_core { awaken, Soul }
import from .channels { channel_add, channel_list }
import from .sigil_secrets { secret_add }

# kind -> {token_env, delivery, summary, link, get_token[], wire[]}
#   summary  one line for the console's channel list: what connecting costs you
#   link     [label, url] of the page where the token is made
glob CHANNEL_GUIDES: dict[str, any] = {
    "telegram": {
        "token_env": "TELEGRAM_BOT_TOKEN",
        "delivery": "long-poll",
        "summary": "Paste a bot token and it works. No public URL needed.",
        "link": ["Open BotFather", "https://t.me/BotFather"],
        "get_token": [
            "Message @BotFather in Telegram and send /newbot; pick a name and a username.",
            "BotFather replies with an HTTP API token like 123456:ABC-DEF…. Copy it."
        ],
        "wire": [
            "Nothing to wire. While the daemon runs, Sigil long-polls Telegram with the token, so no public URL or tunnel is needed.",
            "Do not set a Telegram webhook for this bot: Telegram refuses long polls while one is set. If one exists, clear it:",
            "  curl 'https://api.telegram.org/bot<token>/deleteWebhook'"
        ]
    },
    "discord": {
        "token_env": "DISCORD_BOT_TOKEN",
        "delivery": "gateway-bridge",
        "summary": "Sigil sends replies. Receiving needs a small gateway bridge.",
        "link": ["Open the Developer Portal", "https://discord.com/developers/applications"],
        "get_token": [
            "In the Developer Portal, choose New Application.",
            "Bot tab → Reset Token → copy the bot token.",
            "On the same tab, turn on MESSAGE CONTENT INTENT (Privileged Gateway Intents).",
            "OAuth2 → URL Generator: scope bot, permissions Send Messages and Read Message History. Open the URL to invite the bot to your server."
        ],
        "wire": [
            "Discord bots receive over a gateway websocket, not a webhook, so run a small bridge:",
            "  a ~30-line discord.py client whose on_message POSTs {channel:'discord', peer:<channel_id>, text:<content>}",
            "  to <PUBLIC_URL>/walker/api_inbound and sends the reply back with channel.send().",
            "Sigil ships the contract; the bridge is the only per-provider glue."
        ]
    },
    "whatsapp": {
        "token_env": "WHATSAPP_TOKEN",
        "delivery": "long-poll",
        "summary": "Create an agent in WhatsApp and paste its API key. No public URL needed.",
        "link": ["About WhatsApp agents", "https://faq.whatsapp.com/1050934623978152"],
        "get_token": [
            "In WhatsApp on your phone: Settings → Agents → Create an agent. Give it a name and a photo.",
            "Open the agent's chat → Chat info → API key, and copy it.",
            "The agent can only talk to you, its creator. WhatsApp says agent chats are not end-to-end encrypted."
        ],
        "wire": [
            "Nothing to wire. While the daemon runs, Sigil long-polls api.whatsapp.com/agent/v1/updates with the key, so no public URL or tunnel is needed.",
            "Message the agent from your phone to start. Sigil marks it read, shows typing while it thinks, and replies in the same chat.",
            "Uninstalling WhatsApp or resetting the key invalidates it; paste the new one here."
        ]
    },
    "slack": {
        "token_env": "SLACK_BOT_TOKEN",
        "delivery": "webhook",
        "summary": "Events API. Needs a public URL for incoming messages.",
        "link": ["Open Slack apps", "https://api.slack.com/apps"],
        "get_token": [
            "Create New App → From scratch, and pick your workspace.",
            "OAuth & Permissions: add the bot scopes chat:write, app_mentions:read and im:history, then Install to Workspace.",
            "Copy the Bot User OAuth Token (it starts with xoxb-)."
        ],
        "wire": [
            "The channel's bridge listens on 127.0.0.1:8390. Give it a public URL with a tunnel, e.g. ngrok http 8390.",
            "Event Subscriptions → Request URL: the tunnel URL (Sigil answers Slack's challenge itself);",
            "subscribe to message.im and app_mention. Replies go out with chat.postMessage."
        ]
    }
};

def channel_kinds() -> list[any] {
    return sorted(list(CHANNEL_GUIDES.keys()));
}

def channel_setup_guide(kind: str) -> str {
    k = (kind or "").lower().strip();
    if k not in CHANNEL_GUIDES {
        return "Unknown channel '" + kind + "'. Supported: " + ", ".join(channel_kinds()) + ".";
    }
    g = dict(CHANNEL_GUIDES[k]);
    lines: list = [];
    lines.append("Connect " + k.capitalize() + " to Sigil");
    lines.append("(" + str(g["delivery"]) + " delivery · token env " + str(g["token_env"]) + ")");
    lines.append("");
    lines.append("1) Get the credentials" + ((" (" + str(g["link"][1]) + ")") if ("link" in g) else ""));
    for s in list(g["get_token"]) { lines.append("   • " + str(s)); }
    lines.append("");
    lines.append("2) Register the channel on the graph");
    lines.append("   channel connect " + k + " " + k + "        # creates the Channel node + a token SecretRef");
    lines.append("");
    lines.append("3) Wire the transport");
    for s in list(g["wire"]) { lines.append("   • " + str(s)); }
    lines.append("");
    lines.append("Sigil's inbound webhook: POST <PUBLIC_URL>/walker/api_inbound  {channel, peer, text}");
    lines.append("Expose it with `sigil serve` (add a tunnel like ngrok for a public URL).");
    return "\n".join(lines);
}

def channel_bootstrap(name: str, kind: str, token_env: str = "") -> dict[str, any] {
    # Do the graph side of connecting a channel in one call: register the Channel
    # node and a SecretRef for its token, then return the provider guide + endpoint.
    k = (kind or "").lower().strip();
    known = k in CHANNEL_GUIDES;
    env = token_env if token_env else (str(CHANNEL_GUIDES[k]["token_env"]) if known else (name.upper() + "_TOKEN"));
    soul = awaken();
    channel_add(name, k if known else kind, "secret:" + name + "_token", "per-peer");
    secret_add(name + "_token", env);
    return {
        "name": name, "kind": (k if known else kind), "token_env": env,
        "endpoint": "/walker/api_inbound",
        "token_set": bool(os.getenv(env)),
        "guide": channel_setup_guide(k) if known else ("Registered custom channel '" + name + "'. Have your adapter POST {channel:'" + name + "', peer, text} to /walker/api_inbound.")
    };
}

def channels_overview() -> dict[str, any] {
    # What's supported vs what's already configured — for the REPL /channels view.
    configured = channel_list();
    return {"supported": channel_kinds(), "configured": configured};
}
