# Sigil reference

The reference the agent reads to answer questions about itself. Every file here is
plain markdown — browsable on GitHub, and loaded at runtime by Sigil's `read_docs`
tool, so what you read is exactly what the agent reads.

Ask Sigil in chat ("how does the sandbox work?", "what models can I use?", "how do I
schedule a job?") and it answers from these pages. Or read them directly:

| Topic | What it covers |
|---|---|
| [overview](overview.md) | What Sigil is and how a request flows through it |
| [skill-compilation](skill-compilation.md) | The compiler: SKILL.md → AG-IR → runnable agent, the gates, eject & replay |
| [configuration](configuration.md) | Every `configure` key and what it does |
| [chat-and-tools](chat-and-tools.md) | Chat mode and the full tool-belt |
| [workspace-and-sandbox](workspace-and-sandbox.md) | The sandboxed workspace, file jail, and exec gate |
| [automation-and-cron](automation-and-cron.md) | Scheduling work the agent runs later |
| [channels](channels.md) | Connecting Discord / Telegram / WhatsApp / Slack |
| [memory-and-skills](memory-and-skills.md) | Durable memory and the compiled-skill library |
| [models](models.md) | Model tiers, aliases, fallbacks, and providers |

From the CLI: `sigil docs` lists topics, `sigil docs <topic>` prints one. In the chat
REPL: `/docs` and `/docs <topic>`.
