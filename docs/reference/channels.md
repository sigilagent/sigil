# Channels

Sigil can be reached over messaging channels. The contract is one webhook: an adapter
forwards each inbound message to `POST /walker/api_inbound` as `{channel, peer, text}`,
and delivers the reply that comes back. Expose it with `jac start observatory.jac` (add a
tunnel like ngrok for a public URL).

## Guided setup

Ask in chat ("how do I connect Discord?") — the agent uses `connect_channel` — or use the
CLI:

```bash
sigil channel setup <kind>              # step-by-step: token -> env var -> webhook wiring
sigil channel connect <name> <kind>     # register the Channel node + a token SecretRef
sigil channel list
```

Supported guides: **discord · telegram · whatsapp · slack**.

## How each connects

| Channel | Token env | Delivery |
|---|---|---|
| Telegram | `TELEGRAM_BOT_TOKEN` | webhook — `setWebhook` points Telegram at `/walker/api_inbound` |
| Discord | `DISCORD_BOT_TOKEN` | gateway bridge — a small bot client forwards messages to `/walker/api_inbound` (Discord receives over a websocket, not a webhook) |
| WhatsApp | `WHATSAPP_TOKEN` | webhook — Meta Cloud API (or Twilio) callback to `/walker/api_inbound` |
| Slack | `SLACK_BOT_TOKEN` | webhook — Events API request URL to `/walker/api_inbound` |

Each guide tells you exactly where to get the token, which env var to set (store it with
`sigil secret add`), and how to wire the transport. For the full steps run
`sigil channel setup <kind>`.

## Sessions and scope

A channel has a `dm_scope` — `main` (one shared transcript), `per-peer` (default; each
peer keeps its own), or `per-channel-peer`. Transcripts persist as `Session` nodes and
reset daily. Manage them with `sigil session list|show|reset`.

Messages support reactions, threads, and edits (`sigil channel react|edit|history`).
