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


def _timeout() -> float:
    try:
        return float(os.environ.get("SIGIL_CLAUDE_CC_TIMEOUT", "600"))
    except ValueError:
        return 600.0


def _agent_timeout() -> float:
    # A byLLM slot is one completion; an agent session is dozens of turns with
    # tool calls in between, so it gets its own, much larger budget. Sharing the
    # slot timeout silently kills long authoring runs mid-flight.
    try:
        return float(os.environ.get("SIGIL_CLAUDE_AGENT_TIMEOUT", "3600"))
    except ValueError:
        return 3600.0


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
    # Deliberately does NOT blame ANTHROPIC_API_KEY. Sigil invokes the CLI in its
    # normal (non---bare) mode, where it authenticates with the Claude Code login
    # and ignores that variable — verified by running `claude -p` with a junk key
    # and still getting a reply. The balance at issue is the one behind the login.
    return (
        " Check the account behind `claude` (run `claude` once to see its status); "
        "or point the tier at another provider with `sigil models set <tier> <model>`."
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


def _call(model: str, messages: list):
    prompt = _render(messages)
    try:
        proc = subprocess.run(
            _argv(model),
            input=prompt,
            capture_output=True,
            text=True,
            timeout=_timeout(),
            cwd=_cwd(),
        )
    except FileNotFoundError:
        raise ClaudeCCError(
            "`%s` not found on PATH — install Claude Code or set SIGIL_CLAUDE_BIN" % _bin()
        )
    except subprocess.TimeoutExpired:
        raise ClaudeCCError("claude timed out after %.0fs (SIGIL_CLAUDE_CC_TIMEOUT)" % _timeout())
    return _response(model, _parse(proc.stdout, proc.stderr, proc.returncode))


async def _acall(model: str, messages: list):
    prompt = _render(messages)
    try:
        proc = await asyncio.create_subprocess_exec(
            *_argv(model),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=_cwd(),
        )
    except FileNotFoundError:
        raise ClaudeCCError(
            "`%s` not found on PATH — install Claude Code or set SIGIL_CLAUDE_BIN" % _bin()
        )
    try:
        out, err = await asyncio.wait_for(proc.communicate(prompt.encode()), timeout=_timeout())
    except asyncio.TimeoutError:
        proc.kill()
        raise ClaudeCCError("claude timed out after %.0fs (SIGIL_CLAUDE_CC_TIMEOUT)" % _timeout())
    return _response(model, _parse(out.decode(errors="replace"), err.decode(errors="replace"), proc.returncode))


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
    try:
        proc = subprocess.run(
            argv,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=(timeout or _agent_timeout()),
            cwd=cwd,
        )
    except FileNotFoundError:
        raise ClaudeCCError("`%s` not found on PATH — install Claude Code" % _bin())
    except subprocess.TimeoutExpired:
        raise ClaudeCCError(
            "claude agent timed out after %.0fs (SIGIL_CLAUDE_AGENT_TIMEOUT)"
            % (timeout or _agent_timeout())
        )
    # An agent run that burns its turns is a normal outcome here, not an error:
    # the caller re-gates the artifact and decides. Only a hard failure raises.
    if proc.returncode != 0 and not proc.stdout.strip().startswith("{"):
        raise ClaudeCCError("claude agent exited %d: %s" % (proc.returncode, (proc.stderr or "")[:400]))
    try:
        return json.loads(proc.stdout)
    except Exception as e:
        raise ClaudeCCError("claude agent produced unparseable output (%s)" % e)


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
