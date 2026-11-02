# Connections

A connection is how Sigil reaches a model. Every model tier is a model name
(`chatgpt-plan/<model>`, `claude-cc/opus`, `ollama_chat/qwen3:8b`, `openai/gpt-5`), and
a name only works when a connection stands behind it.

Sigil cannot compile, chat or route without one, so **setup requires a
connection**. `sigil setup` does not finish until the frontier tier has a working
route.

```bash
sigil setup              # connect a model (required), pick the tiers, set a persona
sigil connect <route>    # connect one route directly
sigil connections        # what is connected, and whether each tier can run
sigil disconnect <route> # sign out, or forget a key Sigil saved
```

## The routes

| Route | `sigil connect …` | How it connects | Who pays |
|---|---|---|---|
| ChatGPT | `chatgpt` | Sign in with your browser | Your ChatGPT plan |
| Claude Code | `claude-code` | The `claude` CLI's own sign-in | Your Claude subscription |
| OpenRouter | `openrouter` | Sign in with your browser; Sigil gets its own key | Your OpenRouter credits |
| Ollama | `ollama [model]` | A local Ollama; `ollama signin` adds its `:cloud` models | Nobody locally; your Ollama plan for `:cloud` |
| Ollama Cloud API | `ollama-cloud` | Paste an ollama.com API key; no local Ollama needed | Your Ollama plan |
| OpenAI, Anthropic, Gemini, Z.ai | `openai` · `anthropic` · `gemini` · `zai` | Paste an API key | That provider's API billing |

The first three need no API key.

### ChatGPT: sign in, and your plan pays

```bash
sigil connect chatgpt
```

Sigil opens a ChatGPT sign-in in your browser. The first time, ChatGPT asks you
to approve **Sigil** and its use of your plan. Then the browser returns to Sigil
on a one-time loopback address (`http://127.0.0.1:<port>/auth/callback`), and the
connection is made.

This is OpenAI's Sign in with ChatGPT for open-source, locally hosted apps
([reference](https://developers.openai.com/siwc/token-sharing-open-source)).
Sigil registers itself during that first sign-in, so there is no client secret
and no partner key. Each model call is one request to the public Responses API
(`api.openai.com/v1/responses`), counted against your ChatGPT plan:

- **Usage and limits** are managed in ChatGPT, at
  [Settings → Usage](https://chatgpt.com/settings/usage). You can cap how much of
  your plan Sigil may use. On Plus, the five-hour limit is shared with every other
  app that uses your plan.
- **Models** are the ones your account lists. Sigil fetches that list when you
  sign in. `chatgpt-plan/default` means the first one, and `sigil connections` shows
  them all.
- **No CLI in the loop.** A call is a direct API request, so there is no
  per-call preamble or process start like the Claude Code route has. That makes
  ChatGPT a reasonable small tier as well as a frontier.
- **Signing out** (`sigil disconnect chatgpt`) revokes the session at OpenAI and
  deletes the tokens. It keeps the registration, so the next sign-in is one
  click. To use a different ChatGPT account, run `sigil connect chatgpt --new`.
  To remove Sigil from your account entirely, disconnect it in ChatGPT's
  settings.

Plan usage accepts only part of the Responses API: requests must use
`store: false` and `stream: true`, and cannot set sampling or output-budget
fields. Sigil binds these tiers the way it binds Claude Code tiers: tools and
output schemas travel as prose in the prompt (`native_tools = false`). Every
compiled slot works this way, and each request stays within what plan usage
accepts.

Set `SIGIL_CHATGPT_EFFORT` (`low`, `medium` or `high`) to pass a reasoning effort
with every call.

### Claude Code: your Claude subscription

```bash
sigil connect claude-code        # runs `claude auth login` if the CLI is not signed in
```

Each call is a headless `claude -p` run on your own subscription. Sigil does not
hold this login: it belongs to the `claude` CLI, so `sigil disconnect` leaves it
alone (`claude auth logout` signs it out everywhere). Costs, limits, and the
`--claude` flag that puts every tier on it for one run:
[claude-code](claude-code.md).

Every call carries Claude Code's own ~9k-token preamble, so this route fits the
frontier tier (compiling) much better than the small tier. Connecting it suggests
`claude-cc/opus` for the frontier and chat tiers and leaves the small tier on
something cheaper.

### OpenRouter: one sign-in, many models

```bash
sigil connect openrouter
```

The browser opens OpenRouter's sign-in, you approve the key, and Sigil saves it
as `OPENROUTER_API_KEY` in the secrets file. Model names are
`openrouter/<vendor>/<model>`. Setup suggests `openrouter/openrouter/auto`,
OpenRouter's own router. Pin a specific model with `sigil models set`.

### Ollama: on this machine

```bash
sigil connect ollama             # status, and offers to pull qwen3:8b
sigil connect ollama qwen3:14b   # pull a specific model
```

Sigil finds Ollama at `127.0.0.1:11434` (or `$OLLAMA_HOST`) and offers every
model you have pulled. For the small tier, setup picks a model of at least 7B
parameters, since smaller ones struggle to follow a compiled procedure.

**Ollama's cloud models, through your local Ollama.** Sign the local Ollama in to
ollama.com, and models with a `:cloud` tag run on Ollama's servers through the
same local API:

```bash
sigil connect ollama signin            # runs `ollama signin`, which prints a link
sigil connect ollama glm-5.3:cloud     # make it show up in Ollama's model list
```

The tier name is the ordinary local one (`ollama_chat/glm-5.3:cloud`). A `:cloud`
model needs no download, so Sigil does not require it to be pulled before a tier
can use it. When one is present, setup prefers it for the frontier tier, since it
is far stronger than anything that fits on a laptop.

### Ollama Cloud API: no local Ollama

```bash
sigil connect ollama-cloud             # paste a key from ollama.com/settings/keys
```

For a machine without Ollama installed, such as a server or CI. Tier names are
`ollama-cloud/<model>`, using the names on ollama.com's model list (`glm-5.3`,
`gpt-oss:120b`; no `:cloud` suffix). Setup suggests `ollama-cloud/glm-5.3` for the
frontier and `ollama-cloud/gpt-oss:20b` for the small tier. The key is kept as
`OLLAMA_API_KEY` in the secrets file.

Sigil gives the `https://ollama.com` base to these tiers only. It deliberately
does not set `OLLAMA_API_BASE`, because litellm applies that variable to every
Ollama call and would send your local tiers to the cloud as well.

### API keys

```bash
sigil connect openai             # prompts for the key, hidden; then tests it
sigil connect anthropic sk-ant-… # or pass it inline
```

The key goes into `$SIGIL_HOME/secrets.env` (0600, readable by you alone) and
never onto the graph. A key exported in your shell always wins over the file.
The Observatory's Keys & secrets page manages the same file.

## Tiers, from what is connected

After you connect, setup suggests a model for each tier:

| Tier | Prefers, in order |
|---|---|
| `frontier`, `chat` | ChatGPT, Claude Code, Anthropic, OpenAI, OpenRouter, Gemini, Z.ai, Ollama |
| `small`, `router` | Ollama (≥7B), ChatGPT, OpenAI, Anthropic, Gemini, OpenRouter, Z.ai, Claude Code |

Subscriptions come first for the frontier, because compiling is rare and
judgment-heavy. Local and cheap routes come first for the small tier, which runs
every compiled skill. Accept the suggestion, edit any tier, or change one later
with `sigil models set <tier> <name>`. `sigil connect <route>` on its own also
offers to point the tiers at the route you just connected.

## The first-run gate

`chat`, `compile`, `solve`, `relearn` and `eval` check first that the frontier
and chat tiers have a live route. On a terminal, when they do not, the command
goes through setup first. Piped or scripted, it prints one warning and carries
on, so CI and other automation still run. `--claude` runs skip the gate, because
`--claude` checks the Claude Code login itself.

`SIGIL_REQUIRE_CONNECTION=0` turns the gate off.

The check makes no model calls. It looks at the credentials on disk, the
environment, and the local Ollama port.

## In chat

Chat uses the same word for the same thing:

| Command | What it does |
|---|---|
| `/connect` | What is connected, and whether each tier can run |
| `/connect <provider>` | The same flow as `sigil connect <provider>`: a browser sign-in, or a key asked for without echo. The full-screen chat hands the terminal over while it runs, then returns |
| `/connections` | The status table on its own |
| `/channel <kind>` | Setup steps for a messaging channel (Discord, Telegram, WhatsApp, Slack). `/connect discord` still answers, and points here |

Or ask in plain words ("connect my ChatGPT", "which models are set up?"). The agent has
`model_connections`, `connect_model` and `use_model_provider`. `connect_model` opens a
browser sign-in on this machine for ChatGPT and OpenRouter. It never takes an API key:
anything typed into chat is sent to the model and kept in the transcript, so for a key
provider it tells you to run `/connect <provider>`. In the Observatory's chat or a
channel conversation, it points to the Model providers page instead, because those
conversations run in a process that ends before a browser sign-in could finish.

## In the Observatory

**Model providers**, under Connect in the sidebar beside Channels and MCP & tools
(the same page as Settings → Model providers), lists every route with its status, and
a row for each tier showing whether it can run:

- **Continue with ChatGPT** and **Sign in to OpenRouter** open the sign-in in a
  new tab. The page waits until you finish, then offers to point the tiers at
  the new connection.
- **Add key** saves and tests a key in one step.
- **Use for tiers** points the tiers at a connected route.
- **Claude Code** and **Ollama** show the one command to run in a terminal, and a
  **Check again** button.

While nothing is connected, every page shows a banner linking there.

The browser sign-ins return to a loopback address on the machine running Sigil,
so they work when the Observatory and your browser are on the same machine. For
a remote Sigil, connect from its terminal instead.

## Where credentials live

| What | Where |
|---|---|
| ChatGPT sign-in | `$SIGIL_HOME/auth/chatgpt.json` (0600) |
| This machine's ChatGPT host id | `$SIGIL_HOME/auth/host_id`: an opaque `urn:uuid:…`, not a credential |
| OpenRouter and API keys | `$SIGIL_HOME/secrets.env` (0600) |
| Claude Code | the `claude` CLI's own config; Sigil only reads which account it is |

None of them is ever written to the graph or to `jac.toml`. The ChatGPT access
token lasts an hour and is refreshed automatically. The CLI, the daemon and every
compiled-skill run share the one file, and they refresh under a lock: refresh
tokens rotate, and two processes racing to use the same one would sign you out.

## Ejected runnables

`sigil compile -e agent.jac` produces a standalone file with no Sigil imports, so
there is no Sigil code in it to sign in with ChatGPT or drive Claude Code. Give an
ejected program a normal provider name (`SIGIL_MODEL=openai/gpt-5`,
`ollama_chat/…`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Sigil needs a model connection first` | Finish `sigil setup`, or `sigil connect <route>` |
| No browser opened | Open the link Sigil prints, on the same machine. Over SSH, connect a route that needs no browser, or forward the port it prints |
| `the sign-in was declined in the browser` | Run `sigil connect chatgpt` again and approve Sigil |
| `signed in, but plan use was not allowed` | Run `sigil connect chatgpt` again and allow Sigil to use your plan |
| `your ChatGPT plan's usage limit for Sigil is reached` | Wait, or raise Sigil's limit at chatgpt.com/settings/usage |
| `the ChatGPT sign-in has expired` | `sigil connect chatgpt`: one click, since the registration is kept |
| `that model is not offered to this ChatGPT account` | `sigil connections` lists the account's models |
| `Ollama has not pulled …` | `sigil connect ollama <model>` |
| A `:cloud` model fails with an auth error | The local Ollama is not signed in: `sigil connect ollama signin` |
| A tier shows ✗ in `sigil connections` | The reason is on the same line. `sigil setup` re-suggests tiers from what is connected |

## Environment

| Variable | Default | What it does |
|---|---|---|
| `SIGIL_REQUIRE_CONNECTION` | on | `0` turns off the first-run gate |
| `SIGIL_CHATGPT_EFFORT` | unset | reasoning effort sent with every ChatGPT call |
| `OLLAMA_HOST` | `127.0.0.1:11434` | where Sigil looks for Ollama |
| `OLLAMA_API_KEY` | unset | the Ollama Cloud API key (`sigil connect ollama-cloud` saves it) |
| `SIGIL_CLAUDE_BIN` | `claude` | the Claude Code binary |

## See also

- [models](models.md): the tiers, aliases and fallback chains
- [claude-code](claude-code.md): the Claude Code route in depth, and serving skills back to it
