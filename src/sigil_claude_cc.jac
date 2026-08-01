"""Claude Code as a byLLM model — `by llm()` answered by the local `claude` CLI.

byLLM routes every `by llm()` point through ``litellm.completion`` /
``acompletion``, and litellm lets you own a provider prefix outright
(``litellm.custom_provider_map``). That is the whole seam: register a handler
under the ``claude-cc`` prefix and any Sigil tier named ``claude-cc/<alias>``
is answered by a headless ``claude -p`` run — the user's own Claude Code
subscription, no ANTHROPIC_API_KEY, no proxy, no second auth.

    SIGIL_FRONTIER=claude-cc/opus  SIGIL_SMALL=claude-cc/haiku  sigil chat

Text in, text out is enough for *every* byLLM shape, including typed returns
and tool use, because byLLM already carries both over plain prose when a model
declares no native tool support: ``inject_schema_hint`` appends the output JSON
schema to the prompt and ``mt_run.parse_response`` parses it back, and
``inject_tool_hint`` renders the tool list into the system prompt with a
``<tool_call>{...}</tool_call>`` protocol that ``recover_tool_calls`` reads back
out of the reply. So `sigil.model_for` binds these tiers with
``config={"native_tools": False}`` and this handler never has to synthesize an
OpenAI tool-call envelope.

Cost note: a ``claude -p`` run always ships Claude Code's own ~16k-token tool
preamble, whatever flags you pass. Every call here is therefore ~16k cached
input tokens heavier than the same call made against the Anthropic API. The
prompt below is a *fixed* string and the transcript goes on stdin precisely so
that preamble stays byte-identical between calls and is served from the prompt
cache.

Like ``sigil_observe``, this is pure Python-runtime manipulation — subclassing a
third-party base class and mutating module globals — so the body lives in one
``::py::`` block; ``install`` / ``is_claude_cc`` stay ordinary module symbols
importable from Jac (``import from .sigil_claude_cc { install }``).
"""

::py::
import asyncio
import json
import os
import subprocess
import tempfile
import time
import uuid

PROVIDER = "claude-cc"

_INSTALLED = False


class ClaudeCCError(RuntimeError):
    """A `claude -p` run failed — bad exit, unparseable stdout, or empty reply."""


# The call runs as a one-off custom agent with `tools: []`. That is the load-
# bearing detail: a default `claude -p` still has Read/Bash/Task, and when byLLM
# hands it a tool list the model reaches for ITS tools instead of emitting the
# <tool_call> text byLLM parses — the run then dies on error_max_turns. An empty
# `tools` array yields a session with no tools at all, so prose is the only move
# it has. It also drops ~7k tokens of tool schemas off every call.
#
# The definition is a FIXED string: Claude Code's preamble is cached by prefix,
# so varying it per call would pay the cache-write price every time. byLLM's own
# system message rides in the stdin transcript instead.
_AGENT = {
    "sigil-slot": {
        "description": "Answers one typed LLM slot in a Jac program.",
        "tools": [],
        "prompt": (
            "You are the model behind a program's typed LLM slot. The message is "
            "a rendered prompt from that program, as a [ROLE] transcript. Follow "
            "its instructions and its output format exactly. Reply with the "
            "answer only: no preamble, no commentary, no code fences unless the "
            "prompt asks for them. Answer from the message alone."
        ),
    }
}

_FLAGS = [
    "-p",
    "--output-format", "json",
    "--agents", json.dumps(_AGENT, sort_keys=True),
    "--agent", "sigil-slot",
    "--strict-mcp-config",       # ignore the user's MCP servers
    "--disable-slash-commands",  # ignore the user's skills
    "--no-session-persistence",  # a byllm point is not a conversation
    "--max-turns", "1",          # one completion, never an agent loop
]

_ROLES = {
    "system": "SYSTEM",
    "user": "USER",
    "assistant": "ASSISTANT",
    "tool": "TOOL RESULT",
}

_STOP_REASONS = {
    "end_turn": "stop",
    "stop_sequence": "stop",
    "max_tokens": "length",
    "tool_use": "tool_calls",
}


def is_claude_cc(model_name: str) -> bool:
    """True for a model string this provider owns (`claude-cc/...`)."""
    return str(model_name or "").startswith(PROVIDER + "/")


def _bin() -> str:
    return os.environ.get("SIGIL_CLAUDE_BIN", "claude")


def _cwd() -> str:
    # Run outside the project: a `claude -p` in the repo would pull CLAUDE.md and
    # the memory directory into the very preamble we are keeping stable.
    return os.environ.get("SIGIL_CLAUDE_CC_CWD") or tempfile.gettempdir()


def _env_seconds(name: str):
    """Seconds from `name`, or None for no limit. Unset / 0 / junk all mean None."""
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return None
    try:
        v = float(raw)
    except ValueError:
        return None
    return v if v > 0 else None


def _timeout():
    """How long one slot call may take. None — no limit — is the default.

    It used to default to 600s, and that demonstrably killed legitimate work: one
    spec-loop call on a document-sized SKILL.md ran past ten minutes, was killed
    with everything it had produced thrown away, and then retried into the same
    wall twice more. Unlike a shell job there is no partial output to salvage
    here, so a deadline buys nothing at all — it only decides whether the work is
    lost. Same trade `ws_exec` stopped making.

    Set SIGIL_CLAUDE_CC_TIMEOUT for an unattended deployment (cron, a server)
    where a genuinely hung CLI would otherwise block forever with nobody at the
    keyboard to interrupt it.
    """
    return _env_seconds("SIGIL_CLAUDE_CC_TIMEOUT")


def _agent_timeout():
    # An agent session is dozens of turns with tool calls in between — even more
    # obviously not something to put a stopwatch on. `--max-turns` is the real
    # bound on it; SIGIL_CLAUDE_AGENT_TIMEOUT adds a wall-clock one if you want it.
    return _env_seconds("SIGIL_CLAUDE_AGENT_TIMEOUT")


def _timed_out(kind: str, secs, var: str) -> "ClaudeCCError":
    return ClaudeCCError("claude %s timed out after %.0fs (%s)" % (kind, secs or 0, var))


def _config_path() -> str:
    d = os.environ.get("CLAUDE_CONFIG_DIR")
    return os.path.join(d, ".claude.json") if d else os.path.expanduser("~/.claude.json")


def auth_status() -> dict:
    """Which account a `claude-cc` call would bill, before spending one.

    Claude Code asks once about an ANTHROPIC_API_KEY it finds in the environment
    and records the answer in ~/.claude.json. Returns
    {"mode": "subscription"|"api-key"|"none"|"unknown", "account": str}.
    """
    try:
        with open(_config_path()) as f:
            cfg = json.load(f)
    except Exception:
        # No readable config is not proof of anything — say so rather than guess.
        return {"mode": "unknown", "account": ""}
    account = str(((cfg.get("oauthAccount") or {}).get("emailAddress")) or "")
    key = os.environ.get("ANTHROPIC_API_KEY") or ""
    approved = (cfg.get("customApiKeyResponses") or {}).get("approved") or []
    if key and (key[-20:] in approved) and _allow_api_key():
        return {"mode": "api-key", "account": ""}
    if account:
        return {"mode": "subscription", "account": account}
    return {"mode": "none", "account": ""}


def _allow_api_key() -> bool:
    return bool(os.environ.get("SIGIL_CLAUDE_ALLOW_API_KEY"))


def _env() -> dict:
    # `--claude` means "runs on your Claude subscription". Claude Code would
    # otherwise prefer an ANTHROPIC_API_KEY the user once approved, silently
    # turning that promise into console billing — so the child does not get the
    # variable at all unless SIGIL_CLAUDE_ALLOW_API_KEY says the user wants it.
    # The caller's own environment is never modified.
    env = dict(os.environ)
    if not _allow_api_key():
        env.pop("ANTHROPIC_API_KEY", None)
        env.pop("ANTHROPIC_AUTH_TOKEN", None)
    return env


def _alias(model: str) -> str:
    """`claude-cc/opus` -> `opus`. litellm may already have stripped the prefix."""
    name = str(model or "")
    if name.startswith(PROVIDER + "/"):
        name = name[len(PROVIDER) + 1:]
    return "" if name in ("", "default") else name


def _text(content) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for p in content:
            if not isinstance(p, dict):
                parts.append(str(p))
            elif p.get("type") == "text":
                parts.append(str(p.get("text", "")))
            elif p.get("type") in ("image_url", "image", "video_url"):
                parts.append("[non-text content omitted: claude-cc is text-only]")
        return "\n".join(x for x in parts if x)
    return str(content)


def _tool_calls_text(msg: dict) -> str:
    # Echo an assistant turn's tool calls back in the same <tool_call> form byLLM
    # asked for, so a ReAct transcript reads consistently across turns.
    out = []
    for t in msg.get("tool_calls") or []:
        fn = (t.get("function") if isinstance(t, dict) else getattr(t, "function", None)) or {}
        get = (lambda k: fn.get(k) if isinstance(fn, dict) else getattr(fn, k, None))
        name = str(get("name") or "")
        args = str(get("arguments") or "{}")
        out.append('<tool_call>{"name": %s, "arguments": %s}</tool_call>' % (json.dumps(name), args))
    return "\n".join(out)


def _render(messages: list) -> str:
    """Flatten OpenAI-shaped messages into one [ROLE]-tagged transcript."""
    blocks = []
    for raw in messages or []:
        msg = raw if isinstance(raw, dict) else {
            "role": getattr(raw, "role", "user"),
            "content": getattr(raw, "content", str(raw)),
            "tool_calls": getattr(raw, "tool_calls", None),
        }
        body = _text(msg.get("content"))
        calls = _tool_calls_text(msg)
        if calls:
            body = (body + "\n" + calls).strip()
        if not body:
            continue
        role = str(msg.get("role", "user"))
        blocks.append("[%s]\n%s" % (_ROLES.get(role, role.upper()), body))
    return "\n\n".join(blocks)


def _argv(model: str) -> list:
    argv = [_bin()] + list(_FLAGS)
    alias = _alias(model)
    if alias:
        argv += ["--model", alias]
    return argv


# ---------------------------------------------------------------------------
# Watching the model think.
#
# A compile is dozens of these calls and used to show nothing at all while they
# ran: a spinner, then minutes of silence, then a verdict. But the words being
# written ARE the artifact being built, so there is no reason to hide them.
#
# `claude -p --output-format stream-json --include-partial-messages` emits one
# NDJSON line per delta and then the SAME final `result` object the non-streaming
# form returns — so `_parse` and `_response` are untouched by this and their
# contract is exactly what it was. The only new thing is that deltas go past a
# sink on the way. No sink (the default) drains and discards them.
_SINK = None            # callback(kind, text) — kind is "text" | "thinking"


def set_stream_sink(fn) -> None:
    """Route every delta to `fn(kind, text)`. None turns it back off."""
    global _SINK
    _SINK = fn


def _emit(kind: str, text: str) -> None:
    if _SINK is None or not text:
        return
    try:
        _SINK(kind, text)
    except Exception:
        # A broken renderer must never take down the compile it is describing.
        pass


def _stream_flags() -> list:
    # --verbose is REQUIRED by the CLI alongside stream-json under -p;
    # --include-partial-messages is what turns whole messages into deltas.
    return ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]


def _feed(event: dict):
    """Handle one NDJSON line. Returns the final `result` object when it arrives."""
    kind = str(event.get("type") or "")
    if kind == "result":
        return event
    if kind != "stream_event":
        return None
    inner = event.get("event") or {}
    if str(inner.get("type") or "") != "content_block_delta":
        return None
    delta = inner.get("delta") or {}
    dtype = str(delta.get("type") or "")
    if dtype == "text_delta":
        _emit("text", str(delta.get("text") or ""))
    elif dtype == "thinking_delta":
        _emit("thinking", str(delta.get("thinking") or ""))
    return None


def _prompt_file(prompt: str):
    """The prompt on a temp file, handed to the child as its stdin.

    Not a pipe: a rendered AG-IR prompt runs well past the 64KB pipe buffer, and
    a parent busy reading stdout cannot also be feeding stdin, so the two would
    deadlock on exactly the big compiles this is meant to show. A file has no
    buffer to fill.
    """
    fh = tempfile.NamedTemporaryFile("w+", suffix=".prompt", delete=False)
    fh.write(prompt)
    fh.flush()
    fh.seek(0)
    return fh


# Failures the CLI will keep producing until a human does something. byLLM retries
# an APIConnectionError three times, so a billing or login problem used to print
# three full JSON dumps and three tracebacks for one actionable sentence. Matching
# on the CLI's own wording, keyed to what the user has to do about it.
_TERMINAL_ERRORS = [
    ("credit balance is too low",
     "the Anthropic account backing the `claude` CLI is out of credit"),
    ("please run /login",
     "the `claude` CLI is not logged in — run `claude` once and sign in"),
    ("oauth token has expired",
     "the `claude` CLI login has expired — run `claude` once to sign in again"),
    ("invalid api key",
     "the API key the `claude` CLI is using was rejected"),
    ("invalid bearer token",
     "the credential the `claude` CLI is using was rejected"),
]


def _billing_advice() -> str:
    # Which account this drains is the user's own earlier decision, not something
    # Sigil sets: Claude Code asks once about an ANTHROPIC_API_KEY it finds in the
    # environment and records the answer in ~/.claude.json. Approved -> the CLI
    # bills that key; rejected or unanswered -> the subscription login, and the
    # variable is inert. Point at the answer rather than guess which one it is.
    return (
        " Which account that is depends on Claude Code's own API-key decision — "
        "check `jq '.customApiKeyResponses' ~/.claude.json`. Or move the tier "
        "elsewhere with `sigil models set <tier> <model>`."
    )


def _raise_cli_error(data: dict, code: int) -> None:
    reason = str(data.get("result") or data.get("subtype") or "").strip()
    low = reason.casefold()
    for (needle, human) in _TERMINAL_ERRORS:
        if needle in low:
            msg = "claude-cc: " + human + "." + (_billing_advice() if "credit" in needle else "")
            try:
                from litellm.exceptions import AuthenticationError
            except Exception:
                raise ClaudeCCError(msg)
            # Raised as an auth error on purpose: byLLM retries connection errors
            # and does NOT retry this, so the user gets one clear line.
            raise AuthenticationError(message=msg, llm_provider=PROVIDER, model=PROVIDER)
    status = data.get("api_error_status") or ("exit %d" % code)
    raise ClaudeCCError("claude-cc: the CLI failed (%s): %s" % (status, reason[:400] or "no reason given"))


def _parse(stdout: str, stderr: str, code: int) -> dict:
    # `claude -p --output-format json` reports failures INSIDE the json (is_error)
    # and also exits nonzero. The json carries the human-readable reason; the exit
    # code carries nothing. So parse first and only fall back to a raw dump when
    # there is genuinely no json to read — dumping stdout on a nonzero exit is what
    # buried "Credit balance is too low" inside 600 characters of usage counters.
    text = (stdout or "").strip()
    data = None
    if text.startswith("{"):
        try:
            data = json.loads(text)
        except Exception:
            data = None
    if data is None:
        detail = (stderr or text or "").strip()[:400]
        if code != 0:
            raise ClaudeCCError("claude-cc: the CLI exited %d: %s" % (code, detail or "no output"))
        raise ClaudeCCError("claude-cc: unparseable CLI output: %s" % (detail or "empty"))
    if data.get("is_error") or code != 0:
        _raise_cli_error(data, code)
    return data


def _response(model: str, data: dict):
    from litellm.types.utils import Choices, Message, ModelResponse, Usage

    text = data.get("result") or ""
    usage = data.get("usage") or {}
    num = (lambda k: int(usage.get(k) or 0))
    # Claude Code reports fresh/cached input separately; byLLM (and sigil_observe)
    # want one prompt_tokens total, with the cache split kept alongside.
    prompt_tokens = num("input_tokens") + num("cache_read_input_tokens") + num("cache_creation_input_tokens")
    completion_tokens = num("output_tokens")
    resp = ModelResponse(
        id="claude-cc-%s" % (data.get("session_id") or uuid.uuid4().hex),
        created=int(time.time()),
        model="%s/%s" % (PROVIDER, _alias(model) or "default"),
        object="chat.completion",
        choices=[
            Choices(
                finish_reason=_STOP_REASONS.get(str(data.get("stop_reason") or ""), "stop"),
                index=0,
                message=Message(content=text, role="assistant"),
            )
        ],
        usage=Usage(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens,
            cache_read_input_tokens=num("cache_read_input_tokens"),
            cache_creation_input_tokens=num("cache_creation_input_tokens"),
        ),
    )
    # litellm has no cost map for a custom provider; hand it the CLI's own figure
    # so `litellm.completion_cost` (and therefore sigil_observe) reports real money.
    try:
        resp._hidden_params = {"response_cost": data.get("total_cost_usd")}
    except Exception:
        pass
    return resp


def _drain(proc, deadline):
    """Read NDJSON lines until the process ends, emitting deltas as they arrive."""
    result = None
    for line in proc.stdout:
        text = line.strip()
        if text:
            try:
                event = json.loads(text)
            except Exception:
                continue          # a non-JSON line is noise, not a reason to fail
            got = _feed(event)
            if got is not None:
                result = got
        if deadline is not None and time.monotonic() > deadline:
            proc.kill()
            raise _timed_out("", deadline, "SIGIL_CLAUDE_CC_TIMEOUT")
    return result


def _call(model: str, messages: list):
    prompt = _render(messages)
    secs = _timeout()
    deadline = (time.monotonic() + secs) if secs else None
    fh = _prompt_file(prompt)
    proc = None
    try:
        try:
            proc = subprocess.Popen(
                _argv(model) + _stream_flags(),
                stdin=fh,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=_cwd(),
                env=_env(),
            )
        except FileNotFoundError:
            raise ClaudeCCError(
                "`%s` not found on PATH — install Claude Code or set SIGIL_CLAUDE_BIN" % _bin()
            )
        result = _drain(proc, deadline)
        proc.wait()
        err = proc.stderr.read() or ""
    finally:
        fh.close()
        try:
            os.unlink(fh.name)
        except Exception:
            pass
    # `_parse` still sees exactly what it always saw: the result object as JSON
    # text, the stderr, and the exit code.
    out = json.dumps(result) if result is not None else ""
    return _response(model, _parse(out, err, proc.returncode))


async def _adrain(proc):
    result = None
    while True:
        raw = await proc.stdout.readline()
        if not raw:
            break
        text = raw.decode(errors="replace").strip()
        if not text:
            continue
        try:
            event = json.loads(text)
        except Exception:
            continue
        got = _feed(event)
        if got is not None:
            result = got
    return result


async def _acall(model: str, messages: list):
    prompt = _render(messages)
    fh = _prompt_file(prompt)
    proc = None
    try:
        try:
            proc = await asyncio.create_subprocess_exec(
                *(_argv(model) + _stream_flags()),
                stdin=fh,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=_cwd(),
                env=_env(),
            )
        except FileNotFoundError:
            raise ClaudeCCError(
                "`%s` not found on PATH — install Claude Code or set SIGIL_CLAUDE_BIN" % _bin()
            )
        secs = _timeout()
        try:
            result = await asyncio.wait_for(_adrain(proc), timeout=secs)
        except asyncio.TimeoutError:
            proc.kill()
            raise _timed_out("", secs, "SIGIL_CLAUDE_CC_TIMEOUT")
        err = (await proc.stderr.read()).decode(errors="replace")
        await proc.wait()
    finally:
        fh.close()
        try:
            os.unlink(fh.name)
        except Exception:
            pass
    out = json.dumps(result) if result is not None else ""
    return _response(model, _parse(out, err, proc.returncode))


def _chunk(resp) -> dict:
    """The whole reply as one streaming chunk.

    `claude -p` can stream (`--output-format stream-json`), but a byLLM slot
    consumes the full text either way; the one place this shows is chat mode,
    where the reply lands in a single burst instead of token by token.
    """
    usage = resp.usage
    return {
        "text": resp.choices[0].message.content or "",
        "tool_use": None,
        "is_finished": True,
        "finish_reason": resp.choices[0].finish_reason or "stop",
        "index": 0,
        "usage": {
            "prompt_tokens": usage.prompt_tokens,
            "completion_tokens": usage.completion_tokens,
            "total_tokens": usage.total_tokens,
        },
    }


# ---------------------------------------------------------------------------
# The other direction: a FULL Claude Code session, with tools and a workspace.
#
# A byLLM slot above is deliberately toolless and one-shot. This is the opposite
# and exists for one job: escalation, when a bounded slot loop has already failed
# and the thing that would actually fix it is an agent that can read the file, run
# the oracle, and iterate. See compiler/ai/repair.jac.
# ---------------------------------------------------------------------------

_AGENT_TOOLS = ["Read", "Write", "Edit", "Glob", "Grep", "Bash"]

# The session's own identity, not just the task in the message. A repair agent
# told "change only what the diagnostic requires" and an authoring agent told to
# write an artifact from scratch want different standing instructions, so the
# caller picks one; the default is repair.
FIXER = (
    "sigil-fixer",
    "Repairs a Sigil compiler artifact until its gate passes.",
    "You are a repair agent inside Sigil's compiler. Work only in the current "
    "directory. Read the instructions in the message, fix the named file in "
    "place, and verify with the command you are given until it passes. Change "
    "only what the diagnostic requires.",
)

AUTHOR = (
    "sigil-author",
    "Authors a Sigil compiler artifact and verifies it against the compile oracle.",
    "You are the front-end of Sigil's compiler. Work only in the current "
    "directory. Read the instructions in the message, author the named file, and "
    "verify it with the command you are given until it passes. Faithfulness to "
    "the source beats elegance: never add, drop or re-modalize an obligation.",
)


def agent_run(
    prompt: str,
    cwd: str,
    tools: list = None,
    model: str = "",
    max_turns: int = 40,
    timeout: float = 0.0,
    persona: tuple = FIXER,
) -> dict:
    """Run a tool-using Claude Code agent in `cwd`. Returns its result JSON.

    The session is confined to `cwd` (a scratch workspace the caller owns), with
    the user's MCP servers and skills off, so it cannot reach into the project.
    """
    allowed = list(tools if tools is not None else _AGENT_TOOLS)
    (agent_name, agent_desc, agent_prompt) = persona
    spec = {agent_name: {"description": agent_desc, "tools": allowed, "prompt": agent_prompt}}
    argv = [
        _bin(),
        "-p",
        "--output-format", "json",
        "--agents", json.dumps(spec, sort_keys=True),
        "--agent", agent_name,
        "--allowedTools", " ".join(allowed),
        "--permission-mode", "acceptEdits",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--max-turns", str(max_turns),
    ]
    alias = _alias(model)
    if alias:
        argv += ["--model", alias]
    secs = timeout if timeout else _agent_timeout()
    try:
        proc = subprocess.run(
            argv,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=secs,
            cwd=cwd,
            env=_env(),
        )
    except FileNotFoundError:
        raise ClaudeCCError("`%s` not found on PATH — install Claude Code" % _bin())
    except subprocess.TimeoutExpired:
        raise _timed_out("agent", secs, "SIGIL_CLAUDE_AGENT_TIMEOUT")
    # An agent run that burns its turns is a normal outcome here, not an error:
    # the caller re-gates the artifact and decides. Only a hard failure raises.
    if proc.returncode != 0 and not proc.stdout.strip().startswith("{"):
        raise ClaudeCCError("claude agent exited %d: %s" % (proc.returncode, (proc.stderr or "")[:400]))
    try:
        return json.loads(proc.stdout)
    except Exception as e:
        raise ClaudeCCError("claude agent produced unparseable output (%s)" % e)


# ---------------------------------------------------------------------------
# Web search on the subscription.
#
# `web_search` otherwise needs a Brave or Firecrawl key, because keyless engines
# serve bot challenges rather than results. But in claude mode the machine already
# has a search-capable agent that the user is already paying for: Claude Code ships
# a WebSearch tool. So the same seam that answers byLLM slots answers searches —
# one subscription, still no second key.
#
# This is the one place a `claude -p` run is given a tool on purpose. The slot
# agent above is deliberately toolless; this one has exactly WebSearch and a
# JSON-only reply contract, and nothing else it could reach for.
_SEARCH_AGENT = {
    "sigil-search": {
        "description": "Runs one web search and returns the results as JSON.",
        "tools": ["WebSearch"],
        "prompt": (
            "You are a search backend, not an assistant. Run WebSearch on the "
            "message as the query, then reply with ONLY a JSON array of at most "
            "8 objects, each exactly {\"title\": string, \"url\": string, "
            "\"desc\": string}. No prose, no explanation, no code fences. If the "
            "search returns nothing usable, reply with []."
        ),
    }
}


def _search_timeout() -> float:
    try:
        return float(os.environ.get("SIGIL_CLAUDE_SEARCH_TIMEOUT", "180"))
    except ValueError:
        return 180.0


def available() -> bool:
    """True if a `claude` CLI is on PATH to run against."""
    import shutil
    return shutil.which(_bin()) is not None


def _json_array(text: str) -> list:
    # The contract asks for a bare array; models still fence it or add a sentence.
    # Take the outermost [...] rather than trusting the whole reply to parse.
    s = (text or "").strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[-1]
        if s.rstrip().endswith("```"):
            s = s.rstrip()[:-3]
    lo, hi = s.find("["), s.rfind("]")
    if lo < 0 or hi <= lo:
        return []
    try:
        out = json.loads(s[lo:hi + 1])
    except Exception:
        return []
    return out if isinstance(out, list) else []


def web_search(query: str, limit: int = 6) -> list:
    """Search the web through the local Claude Code CLI's WebSearch tool.

    Returns [{"title", "url", "desc"}]; raises ClaudeCCError if the CLI fails.
    """
    argv = [
        _bin(),
        "-p",
        "--output-format", "json",
        "--agents", json.dumps(_SEARCH_AGENT, sort_keys=True),
        "--agent", "sigil-search",
        "--allowedTools", "WebSearch",
        "--permission-mode", "acceptEdits",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        # more than one: the agent needs a turn to search and a turn to answer,
        # and a broad query can take a couple of WebSearch calls to satisfy.
        "--max-turns", "6",
    ]
    alias = os.environ.get("SIGIL_CLAUDE_SEARCH_MODEL", "haiku")
    if alias:
        argv += ["--model", alias]
    try:
        proc = subprocess.run(
            argv, input=query, capture_output=True, text=True,
            timeout=_search_timeout(), cwd=_cwd(), env=_env(),
        )
    except FileNotFoundError:
        raise ClaudeCCError("`%s` not found on PATH — install Claude Code" % _bin())
    except subprocess.TimeoutExpired:
        raise _timed_out("web search", _search_timeout(), "SIGIL_CLAUDE_SEARCH_TIMEOUT")
    data = _parse(proc.stdout, proc.stderr, proc.returncode)
    out = []
    for r in _json_array(str(data.get("result") or ""))[:max(1, int(limit))]:
        if not isinstance(r, dict):
            continue
        url = str(r.get("url") or "").strip()
        if not url:
            continue
        out.append({
            "title": str(r.get("title") or "").strip(),
            "url": url,
            "desc": str(r.get("desc") or r.get("description") or "").strip(),
        })
    return out


def install() -> bool:
    """Register the `claude-cc` provider with litellm. Idempotent."""
    global _INSTALLED
    if _INSTALLED:
        return True
    try:
        import litellm
        from litellm import CustomLLM
        from litellm.utils import custom_llm_setup
    except Exception:
        return False

    # Defined here, not at module scope, to keep the litellm import lazy — Sigil
    # only pays for it when a tier actually names claude-cc.
    class ClaudeCCHandler(CustomLLM):
        def completion(self, *args, **kwargs):
            return _call(kwargs.get("model", ""), kwargs.get("messages") or [])

        async def acompletion(self, *args, **kwargs):
            return await _acall(kwargs.get("model", ""), kwargs.get("messages") or [])

        def streaming(self, *args, **kwargs):
            yield _chunk(_call(kwargs.get("model", ""), kwargs.get("messages") or []))

        async def astreaming(self, *args, **kwargs):
            yield _chunk(await _acall(kwargs.get("model", ""), kwargs.get("messages") or []))

    existing = [x for x in (litellm.custom_provider_map or []) if x.get("provider") != PROVIDER]
    litellm.custom_provider_map = existing + [
        {"provider": PROVIDER, "custom_handler": ClaudeCCHandler()}
    ]
    custom_llm_setup()  # publishes PROVIDER into provider_list / _custom_providers
    _INSTALLED = True
    return True
::py::
