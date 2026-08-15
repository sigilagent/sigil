# Models

Sigil uses four model **tiers**, each configured on the graph and rebound on every run:

| Tier | Role | Key |
|---|---|---|
| `chat` | user-facing conversation + sub-agents | `chat_model` (falls back to `frontier`) |
| `frontier` | compiles new skills | `frontier_model` |
| `small` | executes compiled skills | `small_model` |
| `router` | routes a task to a skill | `router_model` (falls back to `small`) |

The division of labor: the strong model is what you talk to. Chat is the user-facing
surface and has no compiled procedure to lean on, so `chat` (and `frontier`, which
authors skills) should be a strong model. The cheap model (`small`) is reserved for
*executing* an already-compiled skill — a structured procedure it just follows — and
for routing. That's the whole thesis: pay the strong model to think and to build harnesses;
let the cheap model ride them.

Set one with `configure <tier>_model <name>`, `sigil models set <tier> <name>`, or
`/model <tier> <name>` in chat.

## Model names

Model names are litellm strings (via byLLM), so every provider litellm supports works:

| Provider | Example name | Auth |
|---|---|---|
| OpenAI | `gpt-4o`, `gpt-4o-mini` | `OPENAI_API_KEY` |
| Anthropic | `claude-sonnet-4-6` | `ANTHROPIC_API_KEY` |
| Google | `gemini/gemini-2.0-flash` | `GOOGLE_API_KEY` |
| Ollama (local) | `ollama_chat/qwen3:8b` | none — local daemon |
| Claude Code CLI | `claude-cc/opus` | none — your Claude Code login |

The frontier tier needs its provider key; the small/chat tiers can be fully local.
A weaker chat model tends to over-reach for tools — if chat behaves oddly, try a
stronger `chat_model`.

## No key at all: your Claude Code CLI

`--claude` puts every tier on the Claude Code CLI you already have installed, using
your own subscription instead of a provider key:

```bash
sigil --claude compile ./SKILL.md
```

Full details, costs and limits: [claude-code](claude-code.md).

## Aliases and fallbacks

```bash
sigil models list                          # tiers, aliases, fallback chains
sigil models alias fast gpt-4o-mini        # friendly name -> model
sigil models fallback chat gpt-4o-mini,ollama_chat/qwen3:8b   # failover chain
```

A tier with a fallback chain is bound to a byLLM `ModelPool` (`strategy="fallback"`) that
fails over primary → fallbacks.

## Web search providers

Open-web search (`web_search`) is not an LLM tier. Sigil tries three routes, in order:

1. **Brave** — `BRAVE_API_KEY` (free tier at brave.com/search/api)
2. **Firecrawl** — `FIRECRAWL_API_KEY`
3. **Claude Code's own WebSearch** — no key, but only in claude mode (`sigil --claude …`)

A direct search API is faster and cheaper than a model turn, which is why the keyed
providers come first. The third route exists so that claude mode needs no second signup:
the machine already has a search-capable agent you are paying for. See
[claude-code](claude-code.md#web-search-without-a-key).

With none of the three, `web_search` returns setup guidance; `web_fetch` still works on
any public URL, including keyless JSON APIs like GitHub's.
