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
the REPL (`/channels`, `/connect`).
"""

import os;
import from .sigil { awaken, Soul }
import from .channels { channel_add, channel_list }
import from .sigil_secrets { secret_add }

# kind -> {token_env, get_token[], wire[], scope, note}
glob CHANNEL_GUIDES: dict = {
    "telegram": {
        "token_env": "TELEGRAM_BOT_TOKEN",
        "delivery": "webhook",
        "get_token": [
            "Open Telegram and message @BotFather → /newbot; pick a name + username.",
            "BotFather replies with an HTTP API token like 123456:ABC-DEF… — copy it."
        ],
        "wire": [
            "export TELEGRAM_BOT_TOKEN=<token>  (or: secret add tg_token TELEGRAM_BOT_TOKEN)",
            "Point Telegram at Sigil's webhook (Telegram pushes updates for you):",
            "  curl 'https://api.telegram.org/bot<token>/setWebhook?url=<PUBLIC_URL>/walker/api_inbound'",
            "A tiny transform maps Telegram's update JSON → {channel:'telegram', peer:<chat_id>, text:<message.text>}.",
            "Replies come back in the api_inbound response; send them with the sendMessage API."
        ]
    },
    "discord": {
        "token_env": "DISCORD_BOT_TOKEN",
        "delivery": "gateway-bridge",
        "get_token": [
            "Go to https://discord.com/developers/applications → New Application.",
            "Bot tab → Reset Token → copy the bot token.",
            "Enable the MESSAGE CONTENT INTENT (Bot → Privileged Gateway Intents).",
            "OAuth2 → URL Generator → scopes: bot; perms: Send Messages, Read Message History → invite it to your server."
        ],
        "wire": [
            "export DISCORD_BOT_TOKEN=<token>  (or: secret add discord_token DISCORD_BOT_TOKEN)",
            "Discord bots receive over a gateway websocket, not a webhook — run the lightweight bridge:",
            "  a ~30-line discord.py client that on_message POSTs {channel:'discord', peer:<channel_id>, text:<content>}",
            "  to <PUBLIC_URL>/walker/api_inbound, then sends the reply back with channel.send().",
            "Sigil ships the contract; the bridge is the only per-provider glue."
        ]
    },
    "whatsapp": {
        "token_env": "WHATSAPP_TOKEN",
        "delivery": "webhook",
        "get_token": [
            "Create a Meta app at https://developers.facebook.com → add the WhatsApp product.",
            "Copy the temporary (or a System User permanent) access token and the Phone Number ID.",
            "Alternatively use Twilio's WhatsApp API for a simpler token + sandbox number."
        ],
        "wire": [
            "export WHATSAPP_TOKEN=<token>  WHATSAPP_PHONE_ID=<id>  (or store via secret add).",
            "In the Meta app → WhatsApp → Configuration, set the Callback URL to <PUBLIC_URL>/walker/api_inbound",
            "and a Verify Token; subscribe to the 'messages' field.",
            "Map the webhook payload → {channel:'whatsapp', peer:<from-number>, text:<text.body>};",
            "send the reply with a POST to graph.facebook.com/<phone_id>/messages."
        ]
    },
    "slack": {
        "token_env": "SLACK_BOT_TOKEN",
        "delivery": "webhook",
        "get_token": [
            "Create an app at https://api.slack.com/apps → From scratch.",
            "OAuth & Permissions → add bot scopes chat:write, app_mentions:read, im:history → Install → copy the xoxb- token.",
            "Copy the Signing Secret (Basic Information) to verify requests."
        ],
        "wire": [
            "export SLACK_BOT_TOKEN=<xoxb-…>  SLACK_SIGNING_SECRET=<secret>  (or via secret add).",
            "Event Subscriptions → Request URL: <PUBLIC_URL>/walker/api_inbound; subscribe to message.im / app_mention.",
            "Map the event → {channel:'slack', peer:<channel>, text:<event.text>};",
            "post the reply with chat.postMessage."
        ]
    }
};

def channel_kinds() -> list {
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
    lines.append("1) Get the credentials");
    for s in list(g["get_token"]) { lines.append("   • " + str(s)); }
    lines.append("");
    lines.append("2) Register the channel on the graph");
    lines.append("   channel connect " + k + " " + k + "        # creates the Channel node + a token SecretRef");
    lines.append("");
    lines.append("3) Wire the transport");
    for s in list(g["wire"]) { lines.append("   • " + str(s)); }
    lines.append("");
    lines.append("Sigil's inbound webhook: POST <PUBLIC_URL>/walker/api_inbound  {channel, peer, text}");
    lines.append("Expose it with `jac start observatory.jac` (add a tunnel like ngrok for a public URL).");
    return "\n".join(lines);
}

def channel_bootstrap(name: str, kind: str, token_env: str = "") -> dict {
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

def channels_overview() -> dict {
    # What's supported vs what's already configured — for the REPL /channels view.
    configured = channel_list();
    return {"supported": channel_kinds(), "configured": configured};
}
