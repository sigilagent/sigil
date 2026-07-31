"""Sigil as an MCP server — every compiled skill becomes a Claude Code tool.

The mirror of `sigil_mcp.jac`. That module *consumes* MCP servers so the compiler
can bind their tools into the skills it builds; this one *serves*, so the skills
it built become tools in someone else's harness:

    claude mcp add sigil -- sigil mcp-serve

Claude Code then sees one tool per compiled skill, named by its signature and
described by its intent. The description is the trigger — the same mechanism a
subagent uses — so Claude reaches for `csv-clean` when a task looks like a
csv-clean task, and the compiled harness (not the model) guarantees the steps.
Two extra tools cover the rest of the loop: `sigil_solve` routes a task the
agent's own way (compiling a new skill on a miss), and `sigil_library` lists
what exists.

Wire protocol is JSON-RPC 2.0 over stdio, hand-rolled here rather than pulled
from the MCP SDK: it is ~100 lines, it adds no dependency to a project that
deliberately keeps them few, and — the deciding reason — it lets us own stdout.
An MCP server's stdout carries the protocol and NOTHING else, while Sigil's run
path legitimately prints progress. So the real stdout is dup'd for the protocol
and `sys.stdout` is repointed at stderr before any skill runs.

Pure Python-runtime work (fd surgery, a dispatch loop), so the body is one
``::py::`` block; `serve_stdio` is an ordinary module symbol and main.jac passes
Sigil's own callables into it.
"""

::py::
import json
import os
import re
import sys
import traceback

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "sigil"

_JSONRPC_METHOD_NOT_FOUND = -32601
_JSONRPC_INTERNAL_ERROR = -32603


def _tool_name(signature: str) -> str:
    """A compiled signature as a legal MCP tool name (`[A-Za-z0-9_-]{1,64}`)."""
    safe = re.sub(r"[^0-9A-Za-z_-]", "_", str(signature or "skill"))
    return ("skill_" + safe)[:64]


def _describe(skill: dict) -> str:
    sig = str(skill.get("signature", ""))
    intent = str(skill.get("intent", "") or "").strip()
    runs = int(skill.get("runs", 0) or 0)
    ok = int(skill.get("successes", 0) or 0)
    head = intent if intent else ("Runs the compiled '%s' skill." % sig)
    # The record matters to the caller's routing decision: a skill with a real
    # track record is a safer reach than one that has never run.
    stats = (" [compiled skill '%s', v%s; %d/%d runs succeeded]"
             % (sig, skill.get("version", 1), ok, runs)) if runs else (
             " [compiled skill '%s', v%s; not yet run]" % (sig, skill.get("version", 1)))
    return head + stats


def _tools(skills: list) -> list:
    task_schema = {
        "type": "object",
        "properties": {
            "task": {
                "type": "string",
                "description": "The task to run, in plain language.",
            }
        },
        "required": ["task"],
    }
    tools = [
        {
            "name": _tool_name(s.get("signature")),
            "description": _describe(s),
            "inputSchema": task_schema,
        }
        for s in skills
    ]
    tools.append({
        "name": "sigil_solve",
        "description": (
            "Route a task through Sigil: reuse a compiled skill if one fits, "
            "compile a new one if none does. Use when no specific skill tool "
            "above matches, or when you want Sigil to pick."
        ),
        "inputSchema": task_schema,
    })
    tools.append({
        "name": "sigil_library",
        "description": "List Sigil's compiled skills with their run statistics.",
        "inputSchema": {"type": "object", "properties": {}},
    })
    return tools


def _text_result(text: str, is_error: bool = False) -> dict:
    return {"content": [{"type": "text", "text": str(text)}], "isError": bool(is_error)}


def _call(name: str, args: dict, list_skills, run_skill, solve) -> dict:
    if name == "sigil_library":
        skills = list_skills()
        if not skills:
            return _text_result("No compiled skills yet.")
        lines = [
            "%s  v%s  %s  runs=%s ok=%s"
            % (s.get("signature"), s.get("version"), s.get("origin"),
               s.get("runs"), s.get("successes"))
            for s in skills
        ]
        return _text_result("\n".join(lines))

    task = str((args or {}).get("task", "")).strip()
    if not task:
        return _text_result("This tool needs a 'task' string.", is_error=True)

    if name == "sigil_solve":
        r = solve(task, "")
    else:
        by_tool = {_tool_name(s.get("signature")): str(s.get("signature")) for s in list_skills()}
        sig = by_tool.get(name)
        if sig is None:
            return _text_result("Unknown tool: %s" % name, is_error=True)
        # Pin the skill: the caller picked this tool, so honour it rather than
        # letting the router second-guess them.
        r = run_skill(task, sig)

    trace = str(r.get("trace", ""))
    body = str(r.get("result", ""))
    failed = "DONE ok" not in trace
    if trace:
        body = body + "\n\n---\ntrace: " + trace
    return _text_result(body, is_error=failed)


def _dispatch(msg: dict, list_skills, run_skill, solve) -> dict:
    method = str(msg.get("method", ""))
    if method == "initialize":
        want = str((msg.get("params") or {}).get("protocolVersion") or "")
        return {
            "protocolVersion": want or PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": _version()},
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": _tools(list_skills())}
    if method == "tools/call":
        params = msg.get("params") or {}
        return _call(str(params.get("name", "")), params.get("arguments") or {},
                     list_skills, run_skill, solve)
    raise LookupError("unknown method: %s" % method)


def _version() -> str:
    try:
        import tomllib
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(os.path.join(here, "jac.toml"), "rb") as f:
            return str(tomllib.load(f)["project"]["version"])
    except Exception:
        return "0"


def serve_stdio(list_skills, run_skill, solve) -> int:
    """Serve MCP over stdio until stdin closes. Returns an exit code.

    `list_skills() -> list[dict]`, `run_skill(task, signature) -> dict` and
    `solve(task, skill) -> dict` are Sigil's own functions, passed in from
    main.jac so this module stays free of graph imports.
    """
    # stdout is the wire. Take a private copy of it, then repoint sys.stdout at
    # stderr so that anything Sigil prints while running a skill is diagnostics,
    # not corruption of the protocol stream.
    wire = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    sys.stdout = sys.stderr

    def send(payload: dict) -> None:
        wire.write(json.dumps(payload) + "\n")
        wire.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue  # not our frame; a malformed line is not fatal
        mid = msg.get("id")
        try:
            result = _dispatch(msg, list_skills, run_skill, solve)
        except LookupError as e:
            if mid is not None:
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": _JSONRPC_METHOD_NOT_FOUND, "message": str(e)}})
            continue
        except Exception as e:
            print("sigil mcp-serve: %s\n%s" % (e, traceback.format_exc()), file=sys.stderr)
            if mid is not None:
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": _JSONRPC_INTERNAL_ERROR, "message": str(e)[:400]}})
            continue
        # A notification (no id) gets no reply, per JSON-RPC.
        if mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": result})
    return 0
::py::
