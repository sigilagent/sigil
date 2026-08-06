# Channels

Sigil can be reached over messaging channels. A **bridge** carries one channel: it waits
for messages, hands each to the agent, and sends the reply back. The daemon supervises
bridges, so a channel stays connected with nothing open on screen.

```bash
sigil channel connect <name> <kind>     # register the channel + a token SecretRef
export TELEGRAM_BOT_TOKEN=…             # the credential itself never touches the graph
sigil daemon start                      # the daemon brings the bridge up and keeps it up
sigil channel list                      # …  connected
```

Run one in the foreground when you want to watch it: `sigil channel run <name>`.

## Guided setup

Ask in chat ("how do I connect Telegram?") — the agent uses `connect_channel` — or use the
CLI:

```bash
sigil channel setup <kind>              # step-by-step: token -> env var -> wiring
sigil channel connect <name> <kind>     # register the Channel node + a token SecretRef
sigil channel list
```

## How each connects

| Channel | Token env | Inbound | Outbound |
|---|---|---|---|
| Telegram | `TELEGRAM_BOT_TOKEN` | **long poll — no public URL, no tunnel** | `sendMessage` |
| Slack | `SLACK_BOT_TOKEN` | Events API → the bridge's listener (needs a public URL) | `chat.postMessage` |
| WhatsApp | `WHATSAPP_TOKEN` | Cloud API callback → the bridge's listener | Graph API |
| Discord | `DISCORD_BOT_TOKEN` | a gateway bridge posts to the listener (Discord pushes over a websocket) | REST `messages` |
| webhook | — | any POST of `{channel, peer, text}` | POST back to your URL |

**Telegram is the one that works immediately**: it polls, so there is nothing to expose
and nothing to tunnel. Paste the token, start the daemon, message the bot.

For the push providers the bridge listens on `127.0.0.1:8390` by default — loopback, so
put a tunnel or a reverse proxy in front rather than exposing the agent directly. Slack's
`url_verification` handshake is answered automatically, and Slack's 3-second retry rule
is respected: the bridge acknowledges immediately and answers when the agent is done.

A provider needing a second coordinate (a WhatsApp phone-number id, a webhook URL) takes
it in the channel config as `<credential>|<target>`.

## Sending

```bash
sigil channel send <channel> <peer> "<text>"
```

The result says which of two things happened — `delivered`, or `recorded but NOT
delivered` with the provider's reason. (Previously every send said "sent" and wrote a
node; nothing left the machine.)

Cron jobs deliver the same way: give a job a target of `<channel>` or `<channel>:<peer>`
and its result is sent there. See [automation-and-cron](automation-and-cron.md).

## Why a bridge doesn't answer the message itself

A long-lived process serves the graph it loaded at startup. A bridge that answered
in-process would reply out of a snapshot — a fact you taught an hour ago missing, a skill
compiled since invisible. Every message is handed to a fresh `sigil channel inbound`
subprocess, which reads the current graph; the bridge only moves bytes.

That costs one process start per message and buys an agent that knows what it learned
five minutes ago.

## Sessions and scope

A channel has a `dm_scope` — `main` (one shared transcript), `per-peer` (default; each
peer keeps its own), or `per-channel-peer`. Transcripts persist as `Session` nodes and
reset daily. Manage them with `sigil session list|show|reset`.

Messages support reactions, threads, and edits (`sigil channel react|edit|history`).

## Changing a channel's configuration

A bridge resolves its credentials once, at start. After changing a token or a channel's
kind, run `sigil daemon restart` so the bridge picks it up.
