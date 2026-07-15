# Configuration

All configuration lives on the `Soul` node on the graph — no files. Change it with
`configure <key> <value>` (CLI or the `cfg_*` chat tools), or interactively with
`sigil config`. Every change persists on the graph and takes effect on the next turn.

Current values are shown by `sigil soul` (or `/soul` in chat).

## Keys

| Key | Values | What it does |
|---|---|---|
| `name` | text | The agent's name. |
| `persona` | text | Voice/character the agent speaks with. |
| `chat_model` | model name | The model that powers **chat mode** and sub-agents. Falls back to `small_model`. |
| `frontier_model` | model name | Expensive model that **crystallizes** new skills. |
| `small_model` | model name | Cheap model that **executes** crystallized skills. |
| `router_model` | model name | Model that routes a task to a skill. Falls back to `small_model`. |
| `workspace` | path | The sandboxed directory the file tools are jailed to. Default `~/.sigil/workspace`. |
| `sandbox_mode` | `jail` \| `docker` \| `off` | How `ws_exec` is contained. See [workspace-and-sandbox](workspace-and-sandbox.md). |
| `prompt_mode` | `full` \| `minimal` \| `none` | How much context (ethos + memory) wraps the crystallizer/run. |
| `auto_eval` | on/off | Grounded-eval valve: judge each skill run and relearn if it fails. |
| `eval_threshold` | 0–100 | A run scoring below this auto-triggers a relearn + retry. |
| `recall_mode` | `lexical` \| `vector` \| `hybrid` | How semantic memory is retrieved. See [memory-and-skills](memory-and-skills.md). |
| `embed_model` | model name | Embedding model (litellm name) for vector/hybrid recall. |
| `add_ethos` | text | Append an operating principle to the ethos. |
| `add_channel` | name | Register a channel name on the soul. |
| `tool_allow` | csv | If non-empty, only these tools (+groups/profile) are permitted. |
| `tool_deny` | csv | Denied tools (deny wins over allow); `*` denies all. |
| `tool_profile` | group name | Active profile — a tool group whose tools join the allow-list. |

## Examples

```bash
sigil configure chat_model gpt-4o-mini
sigil configure small_model ollama_chat/qwen3:8b
sigil configure sandbox_mode docker
sigil configure workspace ~/projects/sigil-ws
sigil config                       # interactive editor for the common keys
```

In chat, the agent can change its own model, persona, or prompt mode when asked
(via the `cfg_set_model` / `cfg_set_persona` / `cfg_set_prompt_mode` tools).

## Model tiers

`chat` (talk to it) · `frontier` (build skills) · `small` (run skills) · `router`
(route tasks). Manage names, aliases, and fallback chains with `sigil models …` — see
[models](models.md).
