"""The chat-mode agent — one conversational ReAct loop with the full tool-belt.

This is what makes Sigil *fully usable from chat alone*. A single byLLM agent holds
a running conversation and can, in one turn, chain any of its tools: read/write/edit
files and run shell on the real host, search & fetch the web, schedule its own cron
jobs, remember & recall facts, compile a SKILL.md or a reusable skill, call MCP tools,
send messages on channels, and fan work out to parallel sub-agents.

Shell work is never killed on a timer — `ws_exec` reports the output so far and the
model chooses whether to keep watching, which is why the brief below spends a
paragraph on that decision.

Continuity comes from `conversation=CHAT_HISTORY` (byLLM appends each turn in place).
The per-turn `context` argument re-injects persona, principles, workspace state and
freshly-recalled memory, so the standing brief stays current without a restart.
"""

import json;
import os;
import subprocess;
import time;
import tempfile;
import threading;
import from jaclang.byllm.lib { Model }
import from .sigil_core {
    bind_chat_model, describe_soul, teach, recollect,
    cfg_set_model, cfg_set_persona, cfg_set_prompt_mode
}
import from .agent { run_task }
import from .sigil_daemon { scheduler_running }
import from .sigil_runtime { _jac_bin, entry_script, project_root, commit_now }
import from .sigil_cron { local_tz }
import from .channels { message_send }
import from .sigil_channels_setup { channel_setup_guide, channel_bootstrap, channel_kinds }
import from .sigil_docs { list_docs, read_doc }
import from .sigil_mcp { dispatch }
import from .sigil_workspace {
    ws_read, ws_write, ws_edit, ws_list, ws_tree, ws_grep, ws_exec, ws_watch, ws_kill, ws_jobs,
    sigil_compile, web_fetch, web_search, workspace_info, ws_root, _trace, drain_trace
}
import from .sigil_subagents { spawn_subagent, spawn_parallel }
import from .sigil_skill_tools { run_skill, skill_tools, skill_tool_index, _tail_progress }
import from .sigil_errors { friendly_llm_error, log_error }

glob chat_llm: any = Model(model_name="gpt-4o-mini");
glob CHAT_HISTORY: list = [];
glob CHAT_INFO: dict = {};   # the soul, injected into every turn via byLLM incl_info (mutated in place)
glob _TOKEN_SINK: any = None; # callback(token) — the REPL renders streamed tokens live (None = collect silently)

def set_token_sink(fn: any) -> None { _TOKEN_SINK = fn; }

# ---------------------------------------------------------------------------
# Bridge tools — thin wrappers over the graph-native subsystems, each with a
# `sem` so the model knows exactly when to reach for it.
# ---------------------------------------------------------------------------
# Every cron op runs in a FRESH `jac run` subprocess, never in this long-lived
# chat process. Chat's graph writes only reach the store as one optimistic
# commit at exit; with the daemon committing every 30s, that commit loses the
# version race (WriteConflict) and the whole session's writes are thrown away.
# A job "scheduled" in-process was invisible to every tick while chat ran, then
# gone for good when chat closed. A subprocess reads the store fresh, commits
# alone, and is visible to the next tick — the same isolation tick_isolated
# uses, pointed the other way. Reads go through it too, so run counts are the
# daemon's real numbers, not this process's frozen copy.
def _cron_cli(args: list, timeout_s: int = 300) -> str {
    argv = [_jac_bin(), "run", entry_script(), "--", "cron"] + [str(a) for a in args];
    try {
        p = subprocess.run(argv, cwd=project_root(), capture_output=True,
                           text=True, timeout=timeout_s);
    } except subprocess.TimeoutExpired as e {
        return "cron command timed out after " + str(timeout_s) + "s";
    } except Exception as ex {
        return "cron command failed: " + str(ex)[:200];
    }
    if p.returncode != 0 {
        err = str(p.stderr or "").strip() or str(p.stdout or "").strip();
        return "cron command failed: " + err[-400:];
    }
    keep = [ln for ln in str(p.stdout or "").splitlines()
            if ln.strip() and (not ln.startswith(("INFO - ", "WARNING - ")))];
    return "\n".join(keep) if keep else "(no output)";
}

sem schedule_task = """Schedule work to run later or on a repeat — the agent's cron.
`kind`='at' (one-shot) with spec a relative time ('30m','2h','1d'), ISO timestamp, or
epoch-ms; 'every' with spec = interval in SECONDS; 'cron' with spec a 5-field cron
expression on the host's LOCAL wall clock. `task` is the natural-language instruction
to run when it fires.""";
sem schedule_task.name = "A short unique name for the job.";
sem schedule_task.kind = "One of: at | every | cron.";
sem schedule_task.spec = "The schedule: relative/ISO/epoch for 'at', seconds for 'every', cron-expression (local time) for 'cron'.";
sem schedule_task.task = "The instruction to execute when the job fires.";
def schedule_task(name: str, kind: str, spec: str, task: str) -> str {
    _trace("schedule", name + " [" + kind + " " + spec + "]");
    out = _cron_cli(["add", name, kind, spec, task, local_tz()]);
    if not scheduler_running() {
        # The model has to be able to say this out loud. Answering "scheduled!"
        # while nothing ticks is how a job sat at runs=0 for a week.
        out += "\nWARNING: no scheduler is running, so this job will NOT fire yet — "
               + "the user needs to start one with `sigil daemon start`.";
    }
    return out;
}

sem list_scheduled = """List the currently scheduled cron jobs (name, kind, schedule,
next fire time, run counts) and whether a scheduler is actually running. If it is not,
say so — a job with runs=0 and no scheduler has not failed, it has never been tried.""";
def list_scheduled() -> str {
    out = _cron_cli(["list"]);
    if scheduler_running() { out += "\nscheduler: running"; }
    else { out += "\nscheduler: NOT RUNNING — nothing will fire until `sigil daemon start` is run"; }
    return out;
}

sem run_scheduled_now = """Run a scheduled job RIGHT NOW, once, without waiting for its
next fire and without changing its schedule. Use this when the user wants to test a job
or wants its result immediately.""";
sem run_scheduled_now.name = "The job name to run now.";
def run_scheduled_now(name: str) -> str {
    _trace("run-job", name);
    # The fired task solves in the subprocess and can legitimately take minutes.
    return _cron_cli(["run", name], timeout_s=1800);
}

sem cancel_scheduled = "Cancel (remove) a scheduled cron job by name.";
sem cancel_scheduled.name = "The job name to cancel.";
def cancel_scheduled(name: str) -> str { _trace("unschedule", name); return _cron_cli(["rm", name]); }

sem remember_fact = "Store a durable fact in long-term memory to recall in future conversations.";
sem remember_fact.fact = "The fact to remember.";
def remember_fact(fact: str) -> str {
    _trace("remember", fact);
    # teach() now runs its read-mutate-commit as a serialized critical section
    # and commits before it returns, so the fact is durable the moment this
    # does — no separate commit_now, and no window for a daemon tick to
    # discard it. A failed write comes back as the tool's RESULT so the model
    # can say so, rather than breaking the turn.
    try { return teach(fact, "fact"); }
    except Exception as e { return "could not remember that: " + str(e)[:200]; }
}

sem recall_memory = "Search long-term memory for facts relevant to a query.";
sem recall_memory.query = "What to search memory for.";
def recall_memory(query: str) -> str {
    ms = recollect(query, 6);
    if not ms { return "(nothing relevant in memory)"; }
    return "\n".join(["(" + str(m["kind"]) + ") " + str(m["content"]) for m in ms]);
}

sem learn_skill = """Author a NEW reusable skill from a DESCRIPTION, when no skill
document exists: the frontier model writes a typed procedure for the class of task, runs
it, and persists it so future requests of the same kind are handled cheaply. Use this only
when the user wants a durable, repeatable procedure and there is nothing written down yet
— for a one-off, just do the work with the other tools. If a SKILL.md already exists (in
the workspace, or in a repo you can fetch), use sigil_compile on that file instead: it
compiles what was actually written rather than inventing a fresh procedure from a
paraphrase.""";
sem learn_skill.task = "A representative task describing the class of work to author a skill for.";
def learn_skill(task: str = "") -> str {
    # Defaulted on purpose. A required arg the model omits raises TypeError inside
    # byLLM's tool runtime, which logs a raw traceback line over the live spinner —
    # the user sees a Python signature error instead of an answer. Missing input is
    # a normal model mistake, so it gets a normal answer it can act on.
    if not str(task).strip() {
        _trace("learn", "(no task given)", False);
        return "learn_skill needs a `task`: one representative task describing the "
               + "class of work to compile. Nothing was compiled.";
    }
    _trace("learn", task);
    r = run_task(task, "");
    warn = commit_now("learn_skill");
    out = "skill '" + str(r["signature"]) + "': " + str(r["result"])[:600];
    return (out + "\nWARNING: " + warn) if warn else out;
}

sem list_skills = "List the compiled skills you can call — the tool name for each, its run stats, and what it is for.";
def list_skills() -> str {
    # The GATED list, matching the tools actually on the belt. Listing a skill the
    # policy denies would only teach the model to reach for a door that is locked.
    rows = skill_tool_index();
    if not rows { return "(no compiled skills yet)"; }
    out: list = [];
    for e in rows {
        line = str(e["tool"]) + "  runs=" + str(e["runs"]) + " ok=" + str(e["successes"]);
        it = str(e.get("intent") or "").strip().replace(chr(10), " ")[:140];
        # the intent is the WHEN-and-WHAT of the skill — without it the model had
        # to read compiled source (or shell out) to learn what it already owned.
        if it { line += "  — " + it; }
        out.append(line);
    }
    return "\n".join(out);
}

# ---------------------------------------------------------------------------
# use_skill — the NAMED door to an already-compiled skill. Every compiled skill
# is also its own tool now (`skill_<signature>`, minted by sigil_skill_tools and
# appended to the belt below), which is how the model reaches one WITHOUT being
# told to; this tool stays for the case where a signature is already in hand —
# the user named it, or list_skills just printed it.
#
# Both doors run through `run_skill`: same policy filter, same approval gate,
# same live node trace, same in-process graph. Neither is ws_exec("sigil solve …"),
# which would boot a SECOND sigil process against the same database.
# ---------------------------------------------------------------------------
sem use_skill = """Run an ALREADY-COMPILED skill from this agent's library on a task, BY
NAME. Every compiled skill also appears in your tool list as its own `skill_…` tool with
a description of what it is for — reach for THAT when you are picking a skill for a task.
Use this one when you already have the exact signature in hand (the user named it, or
list_skills printed it). It runs in this process on this graph, streams each step live,
and returns the skill's report. NEVER run `sigil solve` through ws_exec — that boots a
second copy of this agent against the same database. A run may take minutes (it fetches,
generates, verifies); that is normal — wait for it.""";
sem use_skill.signature = "The compiled skill's signature exactly as listed (e.g. 'hackernews_relevant_posts').";
sem use_skill.task = "The task to run it on. Empty = run the skill on its own intent.";
def use_skill(signature: str, task: str = "") -> str {
    return run_skill(signature, task);
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
or settings. Topics: overview, configuration, chat-and-tools, workspace-and-tools,
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
from chat. By default you work on the REAL machine — the same filesystem and the same
installed tools the operator has — with a full tool-belt. Your standing context reports a
`sandbox` setting: `off` means exactly that; `jail`/`docker` means the file tools are
confined to the workspace and paths outside it will be refused.

FIRST decide whether the message even needs a tool. Greetings, questions about you,
explanations, opinions, and anything you can answer in words → just REPLY as text, with
NO tool call. Never run a shell command (echo/printf/…) to print or "say" a message —
speaking is not a task. Only reach for a tool when the request needs a real side effect:
touching files, running code, fetching live data, scheduling, remembering, delegating.
When it does need action, do it (don't just describe it) and don't ask permission for
reversible steps.

Guidance:
- Files: ws_list (one level) / ws_tree (survey a whole directory) / ws_grep (find text
  across files) / ws_read (read a file; page big ones with offset/limit) / ws_write /
  ws_edit. Relative paths resolve in the workspace; absolute paths work anywhere on the
  host unless the sandbox is on. ws_tree and ws_grep are read-only and need no approval —
  use them freely.
- Shell: ws_exec only for real program work (running/building/cloning/driving another
  CLI), never to echo text. It is approval-gated, so don't send trivial commands through
  it — if one is blocked, say so. NOTHING IS EVER KILLED ON A TIMER: ws_exec waits
  `wait_seconds` (default 30) and then reports the output so far. If it says STILL
  RUNNING, the command is still going — read that output and decide like a person would:
  ws_watch("<job>") to keep watching (pass a bigger wait_seconds for slow work), get on
  with something else and check back, or ws_kill("<job>") if it's clearly stuck or wrong.
  ws_jobs() lists what's still running. Never claim a long command failed just because it
  hasn't finished.
- Skills. Every COMPILED skill is one of your own tools, named `skill_<signature>`, with
  a description saying what it is for. Treat them like any other tool: when a request
  matches one, CALL IT — don't re-do the work by hand with files and shell, and don't ask
  whether a skill exists. A compiled skill executes its steps in a harness, so it is more
  reliable at its own job than you are improvising the same procedure. If a skill tool
  returns BLOCKED or DENIED, the operator has gated it — say so plainly and stop, don't
  reimplement it to get around the gate. use_skill(signature, task) is the same runner
  by name, for when you already have the signature. NEVER run `sigil solve` (or any
  `sigil …`) through ws_exec — that boots a SECOND copy of this agent against the same
  database. If the skill is WRITTEN DOWN but not compiled (a SKILL.md), compile that
  document with sigil_compile: never `sigil compile` through ws_exec, and never
  learn_skill. When it lives in a repo, fetch it first — for GitHub use the raw URL, e.g.
  web_fetch("https://raw.githubusercontent.com/<org>/<repo>/main/<path>/SKILL.md") —
  ws_write it into the workspace, then sigil_compile that path. It runs in this process
  on this graph, takes several minutes with no time limit, and streams each stage. It
  becomes a tool of yours the moment it compiles. Only when NOTHING is written down do
  you use learn_skill, which authors a fresh procedure from a description.
- Analyzing a codebase/repo: SURVEY FIRST with ws_tree, LOCATE with ws_grep, then READ
  SEVERAL representative files (page large ones — a partial read shows "lines X-Y of N",
  so keep reading rather than concluding from the first page). Never judge a codebase from
  the README or one file alone. For a repo-scale survey, fan out with spawn_parallel (one
  sub-agent per subsystem). Give a BALANCED, evidence-based take — cite files/lines, note
  concerns as well as strengths, and don't flatter. When asked for a document or report,
  WRITE it to the workspace with ws_write (and say where), don't just print it.
- Web: web_search covers the open web (it needs a provider key — if it reports one is
  missing, say so). web_fetch reads a specific URL, INCLUDING keyless JSON APIs — for
  "new PRs/issues in a repo" fetch GitHub's API directly, e.g.
  web_fetch("https://api.github.com/repos/<org>/<repo>/pulls?state=open"), no key needed.
- Recurring or future work: use schedule_task (cron). "every morning", "in 2 hours",
  "on a cron" all map to it. Use list_scheduled / cancel_scheduled to manage jobs, and
  run_scheduled_now to fire one immediately. Scheduled jobs only fire while a scheduler
  process is running; list_scheduled tells you whether one is. If it is not, a job at
  runs=0 has not failed — it has never been tried, and the fix is for the user to run
  `sigil daemon start`. Say that plainly instead of speculating about timers.
- Memory: remember_fact for durable facts the user will want later; recall_memory to
  look them up.
- Independent sub-tasks: use spawn_parallel to run them at once; spawn_subagent for one.
- Reusable procedures: learn_skill only when the user wants a durable, repeatable skill.
- External tools: mcp_call for connected MCP servers.
- About YOURSELF: when the user asks how Sigil works, what a config key/tool does, or
  about the workspace/sandbox/cron/channels/memory/models, call read_docs (or doc_index)
  and answer from the reference — don't guess. For the user's CURRENT settings, use what
  you already know from your standing context (persona, workspace, sandbox) rather than
  the docs.

Reply in concise GitHub-flavored markdown. Report what you actually did, including
paths and command results. If a tool fails, say what failed and what you'll try next.""";
sem chat_agent.message = "The user's latest message.";
def chat_agent(message: str) -> str by chat_llm(
    # + skill_tools(): ONE TOOL PER COMPILED SKILL, rebuilt on every turn (byLLM
    # re-evaluates call params per invocation). A skill compiled two messages ago
    # is callable now, described by its own intent, and the operator's tool policy
    # decided whether it is in this list at all.
    tools=[
        ws_read, ws_write, ws_edit, ws_list, ws_tree, ws_grep,
        ws_exec, ws_watch, ws_kill, ws_jobs, web_fetch, web_search,
        schedule_task, list_scheduled, cancel_scheduled, run_scheduled_now,
        remember_fact, recall_memory, sigil_compile, learn_skill, list_skills, use_skill,
        mcp_call, send_message, connect_channel, setup_channel,
        cfg_set_model, cfg_set_persona, cfg_set_prompt_mode,
        doc_index, read_docs, spawn_subagent, spawn_parallel
    ] + skill_tools(),
    conversation=CHAT_HISTORY,
    incl_info=CHAT_INFO,
    max_react_iterations=14,
    stream=True
);

# ---------------------------------------------------------------------------
# Driver — inject the soul via incl_info, rebind the model, run one turn.
# ---------------------------------------------------------------------------
def _refresh_info(message: str) -> None {
    # Rebuild CHAT_INFO IN PLACE (never reassign the glob) so byLLM's incl_info
    # sees the current soul every turn — persona, principles, workspace, memory.
    s = describe_soul();
    wi = workspace_info();
    # The skill SHELF, not a count. `compiled_skills: 4` told the model something
    # existed and nothing about what — so it went reading compiled source and
    # shelling out `sigil solve` to discover what it already owned. Each entry
    # now leads with the TOOL NAME it answers to, so the shelf and the tool list
    # are visibly the same shelf: the model sees `skill_clean_csv` here and finds
    # `skill_clean_csv` among its tools. Policy-denied skills are absent from
    # both — what it cannot call, it is not told about.
    shelf: list = [];
    for e in skill_tool_index()[:12] {
        it = str(e.get("intent") or "").strip().replace(chr(10), " ")[:140];
        shelf.append(str(e["tool"]) + ((" — " + it) if it else "")
                     + "  (runs=" + str(e["runs"]) + ")");
    }
    info: dict = {
        "agent_name": str(s["name"]),
        "persona": str(s["persona"]) if s["persona"] else "a pragmatic, autonomous operator",
        "principles": [str(e) for e in list(s["ethos"])],
        "workspace": str(wi["root"]),
        "sandbox": str(wi["sandbox"]),
        "running_shell_jobs": int(wi["running"]),
        "compiled_skills": (shelf if shelf else "none compiled yet")
    };
    mems = recollect(message, 4);
    if mems { info["relevant_memory"] = [str(m["content"]) for m in mems]; }
    CHAT_INFO.clear();
    CHAT_INFO.update(info);
}

def chat_turn(message: str) -> dict {
    # One conversational turn. Rebinds the chat model from the graph (so
    # `configure chat_model` applies live), injects the soul via incl_info, runs the
    # ReAct agent, and STREAMS the reply token-by-token: chat_agent is `stream=True`,
    # so it returns a generator; we emit each token to the token sink (the REPL renders
    # it live) while accumulating the full reply for history + the return value.
    chat_llm = bind_chat_model();
    _refresh_info(message);
    drain_trace();   # clear any stale trace
    reply = "";
    interrupted = False;
    try {
        for tok in chat_agent(message) {
            piece = str(tok);
            reply += piece;
            if _TOKEN_SINK is not None { try { _TOKEN_SINK(piece); } except Exception as e {} }
        }
    } except KeyboardInterrupt {
        # ^C mid-turn means "stop this answer", not "kill sigil". KeyboardInterrupt
        # is a BaseException, so the clause below never sees it — uncaught it would
        # unwind the whole REPL. Keep whatever streamed and flag the turn.
        interrupted = True;
    } except Exception as e {
        # The turn died mid-call (bad model name, dead key, no network…). The
        # error log gets which turn and the full traceback — byLLM's own
        # retry-by-retry copy is already there, entry re-points loguru at the
        # file — and the chat gets ONE sentence that names the fix.
        mname = "";
        try { mname = str(getattr(chat_llm, "model_name", "") or ""); } except Exception {}
        log_error("chat turn failed (model=" + (mname or "?") + "): " + message[:200], e);
        note = "⚠ " + friendly_llm_error(e, mname, "chat");
        reply = note if not reply else (reply + "\n\n" + note);
    }
    # keep history bounded (last ~16 turns)
    if len(CHAT_HISTORY) > 32 { CHAT_HISTORY = CHAT_HISTORY[-32:]; }
    return {"reply": str(reply), "trace": drain_trace(), "interrupted": interrupted};
}

def chat_reset() -> str {
    CHAT_HISTORY = [];
    return "conversation reset";
}
