"""The chat-mode agent — one conversational ReAct loop with the full tool-belt.

This is what makes Sigil *fully usable from chat alone*. A single byLLM agent holds
a running conversation and can, in one turn, chain any of its tools: read/write/edit
files and run shell in the sandboxed workspace, search & fetch the web, schedule its
own cron jobs, remember & recall facts, crystallize a reusable skill, call MCP tools,
send messages on channels, and fan work out to parallel sub-agents.

Continuity comes from `conversation=CHAT_HISTORY` (byLLM appends each turn in place).
The per-turn `context` argument re-injects persona, principles, workspace state and
freshly-recalled memory, so the standing brief stays current without a restart.
"""

import json;
import from jaclang.byllm.lib { Model }
import from .sigil {
    bind_chat_model, describe_soul, teach, recollect, library,
    cfg_set_model, cfg_set_persona, cfg_set_prompt_mode
}
import from .agent { run_task }
import from .cron { cron_add, cron_list, cron_remove }
import from .channels { message_send }
import from .sigil_channels_setup { channel_setup_guide, channel_bootstrap, channel_kinds }
import from .sigil_docs { list_docs, read_doc }
import from .sigil_mcp { dispatch }
import from .sigil_workspace {
    ws_read, ws_write, ws_edit, ws_list, ws_exec, web_fetch, web_search,
    workspace_info, ws_root, _trace, drain_trace
}
import from .sigil_subagents { spawn_subagent, spawn_parallel }

glob chat_llm: any = Model(model_name="gpt-4o-mini");
glob CHAT_HISTORY: list = [];
glob CHAT_INFO: dict = {};   # the soul, injected into every turn via byLLM incl_info (mutated in place)

# ---------------------------------------------------------------------------
# Bridge tools — thin wrappers over the graph-native subsystems, each with a
# `sem` so the model knows exactly when to reach for it.
# ---------------------------------------------------------------------------
sem schedule_task = """Schedule work to run later or on a repeat — the agent's cron.
`kind`='at' (one-shot) with spec a relative time ('30m','2h','1d'), ISO timestamp, or
epoch-ms; 'every' with spec = interval in SECONDS; 'cron' with spec a 5-field cron
expression. `task` is the natural-language instruction to run when it fires.""";
sem schedule_task.name = "A short unique name for the job.";
sem schedule_task.kind = "One of: at | every | cron.";
sem schedule_task.spec = "The schedule: relative/ISO/epoch for 'at', seconds for 'every', cron-expression for 'cron'.";
sem schedule_task.task = "The instruction to execute when the job fires.";
def schedule_task(name: str, kind: str, spec: str, task: str) -> str {
    _trace("schedule", name + " [" + kind + " " + spec + "]");
    r = cron_add(name, kind, spec, task, "UTC", "", False);
    return "scheduled '" + str(r["name"]) + "' [" + str(r["kind"]) + "] next_run_ms=" + str(r["next_run_ms"]);
}

sem list_scheduled = "List the currently scheduled cron jobs (name, kind, schedule, run counts).";
def list_scheduled() -> str {
    js = cron_list();
    if not js { return "(no scheduled jobs)"; }
    out: list = [];
    for j in js { out.append(str(j["name"]) + "  [" + str(j["kind"]) + " " + str(j["spec"]) + "]  " + ("on" if j["enabled"] else "off") + "  runs=" + str(j["runs"]) + "  " + str(j["task"])); }
    return "\n".join(out);
}

sem cancel_scheduled = "Cancel (remove) a scheduled cron job by name.";
sem cancel_scheduled.name = "The job name to cancel.";
def cancel_scheduled(name: str) -> str { _trace("unschedule", name); return cron_remove(name); }

sem remember_fact = "Store a durable fact in long-term memory to recall in future conversations.";
sem remember_fact.fact = "The fact to remember.";
def remember_fact(fact: str) -> str { _trace("remember", fact); return teach(fact, "fact"); }

sem recall_memory = "Search long-term memory for facts relevant to a query.";
sem recall_memory.query = "What to search memory for.";
def recall_memory(query: str) -> str {
    ms = recollect(query, 6);
    if not ms { return "(nothing relevant in memory)"; }
    return "\n".join(["(" + str(m["kind"]) + ") " + str(m["content"]) for m in ms]);
}

sem learn_skill = """Crystallize a REUSABLE skill for a class of task: the frontier
model authors a typed procedure, runs it, and persists it so future requests of the
same kind are handled cheaply. Use this only when the user wants a durable, repeatable
procedure — for a one-off, just do the work with the other tools.""";
sem learn_skill.task = "A representative task describing the class of work to crystallize into a skill.";
def learn_skill(task: str) -> str {
    _trace("learn", task);
    r = run_task(task, "");
    return "skill '" + str(r["signature"]) + "': " + str(r["result"])[:600];
}

sem list_skills = "List the crystallized (learned) skills with their run stats.";
def list_skills() -> str {
    lib = library();
    if not lib { return "(no crystallized skills yet)"; }
    return "\n".join([str(e["signature"]) + " v" + str(e["version"]) + " [" + str(e["origin"]) + "] runs=" + str(e["runs"]) + " ok=" + str(e["successes"]) for e in lib]);
}

sem mcp_call = """Invoke a tool exposed by a registered MCP server (external tools the
operator connected). Pass the tool name and its arguments as a JSON object string,
e.g. '{"query": "weather", "days": 3}' (use '{}' for no arguments).""";
sem mcp_call.name = "The MCP tool name.";
sem mcp_call.args_json = "The tool's arguments as a JSON object string (name->value); '{}' if none.";
def mcp_call(name: str, args_json: str) -> str {
    _trace("mcp", name);
    args: dict = {};
    try { args = dict(json.loads(args_json)) if args_json.strip() else {}; }
    except Exception as e { return "bad args_json (must be a JSON object): " + str(e)[:120]; }
    res = dispatch(name, [args]);
    if res is None { return "no registered MCP tool named '" + name + "'"; }
    if not res.get("ok", False) { return "mcp error: " + str(res.get("error", "")); }
    return str(res.get("text", ""));
}

sem connect_channel = """Explain how to connect a messaging channel (discord, telegram,
whatsapp, slack) to Sigil — where to get the token, which env var to set, and how to
wire the webhook. Use this whenever the user asks how to hook Sigil up to a chat app.""";
sem connect_channel.kind = "The channel to connect: discord | telegram | whatsapp | slack.";
def connect_channel(kind: str) -> str {
    _trace("connect", kind);
    return channel_setup_guide(kind);
}

sem setup_channel = """Actually register a channel on the graph in one step: creates the
Channel node and a SecretRef for its API token, and returns the remaining wiring steps.
Use after the user has a token and wants it configured.""";
sem setup_channel.name = "A short name for this channel instance (e.g. 'tg', 'discord').";
sem setup_channel.kind = "The channel kind: discord | telegram | whatsapp | slack.";
def setup_channel(name: str, kind: str) -> str {
    _trace("setup_channel", name + " [" + kind + "]");
    r = channel_bootstrap(name, kind, "");
    return "registered channel '" + str(r["name"]) + "' (token env " + str(r["token_env"]) + ", set=" + str(r["token_set"]) + ")\n\n" + str(r["guide"]);
}

sem doc_index = "List Sigil's own reference topics (its documentation about how Sigil works). Call this to see what self-documentation is available.";
def doc_index() -> str { _trace("docs", "index"); return list_docs(); }

sem read_docs = """Read one of Sigil's reference docs to answer a question about how SIGIL
ITSELF works — its configuration keys, tools, the sandbox, cron, channels, memory, skills,
or models. Prefer this over guessing when the user asks about the agent's own capabilities
or settings. Topics: overview, configuration, chat-and-tools, workspace-and-sandbox,
automation-and-cron, channels, memory-and-skills, models (fuzzy match is fine).""";
sem read_docs.topic = "The reference topic to read (e.g. 'sandbox', 'configuration', 'models').";
def read_docs(topic: str) -> str { _trace("docs", topic); return read_doc(topic); }

sem send_message = "Send a message to a peer on a configured channel (e.g. deliver a result out-of-band).";
sem send_message.channel = "The channel name.";
sem send_message.peer = "The recipient/peer id on that channel.";
sem send_message.text = "The message body.";
def send_message(channel: str, peer: str, text: str) -> str {
    _trace("message", channel + " -> " + peer);
    r = message_send(channel, peer, text);
    return "sent to " + str(r["peer"]) + " on " + str(r["channel"]) + " (mid=" + str(r["mid"]) + ")";
}

# ---------------------------------------------------------------------------
# The agent. Its `sem` is the operating brief (system prompt); tools + conversation
# do the rest. Kept concise so a small model can follow it.
# ---------------------------------------------------------------------------
sem chat_agent = """You are Sigil, a capable, autonomous assistant that operates entirely
from chat. You have a SANDBOXED workspace and a full tool-belt.

FIRST decide whether the message even needs a tool. Greetings, questions about you,
explanations, opinions, and anything you can answer in words → just REPLY as text, with
NO tool call. Never run a shell command (echo/printf/…) to print or "say" a message —
speaking is not a task. Only reach for a tool when the request needs a real side effect:
touching files, running code, fetching live data, scheduling, remembering, delegating.
When it does need action, do it (don't just describe it) and don't ask permission for
reversible steps.

Guidance:
- Files & shell: use ws_read/ws_write/ws_edit/ws_list and ws_exec — only for real file or
  program work, never to echo text. Everything is jailed to the workspace; shell is
  approval-gated, so don't send trivial commands through it — if a command is blocked, say so.
- Web: web_search covers the open web (it needs a provider key — if it reports one is
  missing, say so). web_fetch reads a specific URL, INCLUDING keyless JSON APIs — for
  "new PRs/issues in a repo" fetch GitHub's API directly, e.g.
  web_fetch("https://api.github.com/repos/<org>/<repo>/pulls?state=open"), no key needed.
- Recurring or future work: use schedule_task (cron). "every morning", "in 2 hours",
  "on a cron" all map to it. Use list_scheduled / cancel_scheduled to manage jobs.
- Memory: remember_fact for durable facts the user will want later; recall_memory to
  look them up.
- Independent sub-tasks: use spawn_parallel to run them at once; spawn_subagent for one.
- Reusable procedures: learn_skill only when the user wants a durable, repeatable skill.
- External tools: mcp_call for connected MCP servers.
- About YOURSELF: when the user asks how Sigil works, what a config key/tool does, or
  about the sandbox/cron/channels/memory/models, call read_docs (or doc_index) and answer
  from the reference — don't guess. For the user's CURRENT settings, use what you already
  know from your standing context (persona, workspace, sandbox mode) rather than the docs.

Reply in concise GitHub-flavored markdown. Report what you actually did, including
paths and command results. If a tool fails, say what failed and what you'll try next.""";
sem chat_agent.message = "The user's latest message.";
def chat_agent(message: str) -> str by chat_llm(
    tools=[
        ws_read, ws_write, ws_edit, ws_list, ws_exec, web_fetch, web_search,
        schedule_task, list_scheduled, cancel_scheduled,
        remember_fact, recall_memory, learn_skill, list_skills,
        mcp_call, send_message, connect_channel, setup_channel,
        cfg_set_model, cfg_set_persona, cfg_set_prompt_mode,
        doc_index, read_docs, spawn_subagent, spawn_parallel
    ],
    conversation=CHAT_HISTORY,
    incl_info=CHAT_INFO,
    max_react_iterations=14
);

# ---------------------------------------------------------------------------
# Driver — inject the soul via incl_info, rebind the model, run one turn.
# ---------------------------------------------------------------------------
def _refresh_info(message: str) -> None {
    # Rebuild CHAT_INFO IN PLACE (never reassign the glob) so byLLM's incl_info
    # sees the current soul every turn — persona, principles, workspace, memory.
    global CHAT_INFO;
    s = describe_soul();
    wi = workspace_info();
    info: dict = {
        "agent_name": str(s["name"]),
        "persona": str(s["persona"]) if s["persona"] else "a pragmatic, autonomous operator",
        "principles": [str(e) for e in list(s["ethos"])],
        "workspace": str(wi["root"]),
        "sandbox_mode": str(wi["sandbox_mode"]),
        "crystallized_skills": int(s["skills"])
    };
    mems = recollect(message, 4);
    if mems { info["relevant_memory"] = [str(m["content"]) for m in mems]; }
    CHAT_INFO.clear();
    CHAT_INFO.update(info);
}

def chat_turn(message: str) -> dict {
    # One conversational turn. Rebinds the chat model from the graph (so
    # `configure chat_model` applies live), injects the soul via incl_info,
    # runs the ReAct agent, and returns the reply plus the tool trace.
    global chat_llm, CHAT_HISTORY;
    chat_llm = bind_chat_model();
    _refresh_info(message);
    drain_trace();   # clear any stale trace
    try {
        reply = chat_agent(message);
    } except Exception as e {
        reply = "⚠ agent error: " + str(e)[:300];
    }
    # keep history bounded (last ~16 turns)
    if len(CHAT_HISTORY) > 32 { CHAT_HISTORY = CHAT_HISTORY[-32:]; }
    return {"reply": str(reply), "trace": drain_trace()};
}

def chat_reset() -> str {
    global CHAT_HISTORY;
    CHAT_HISTORY = [];
    return "conversation reset";
}
