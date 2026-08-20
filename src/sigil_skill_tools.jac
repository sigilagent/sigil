"""Compiled skills as first-class tools — the inward mirror of `sigil_mcp_serve`.

`sigil_mcp_serve` turns each compiled skill into a tool in *someone else's*
harness (Claude Code, OpenHands). This module points the same idea inward: each
compiled skill becomes one byLLM tool on Sigil's OWN agents, named
`skill_<signature>` and described by the skill's `intent`, so the chat agent and
its sub-agents reach for a compiled procedure the way they reach for `ws_read` —
because the tool list said it exists, not because someone typed "run the
csv-clean skill".

That is the whole point of the delivery change measured in the SkillsBench pilot:
a skill offered as a *tool* gets used; the same skill offered as a *shelf entry
plus a generic runner* mostly does not. `use_skill(signature, task)` still exists
for an explicit call, but it is no longer the only door.

The tool list is rebuilt on every model call (byLLM re-evaluates `tools=` per
invocation), so a skill compiled mid-session is callable on the very next turn —
no restart, no re-registration.

TWO GATES stand in front of every skill tool, and both are the operator's:

  1. POLICY (`tool_allow` / `tool_deny` / `tool_profile` on the Soul). A denied
     skill is not filtered at call time — it is never put in the tool list at
     all, so the model cannot ask for what it may not have.
  2. APPROVAL (`approvals.check_exec`, the same gate `ws_exec` consults, keyed
     `skill:<signature>`). A compiled skill writes files and shells out; letting
     the model start one unprompted is exactly the kind of side effect the exec
     gate exists for. The first autonomous call asks the operator inline
     (`allow-always` on a yes, so nobody is asked twice); headless, it queues in
     `sigil approvals pending` and the model gets an honest BLOCKED string.

The gate lives at the TOOL boundary, not in `run_task` — an operator typing
`sigil solve …` has already given their permission, and re-asking them for it
would be theatre.
"""

import json;
import os;
import re;
import tempfile;
import threading;
import time;
import from jaclang.byllm.lib { Tool }
import from .sigil_core { library, tool_allowed }
import from .approvals { check_exec, allowlist_add }
import from .sigil_workspace { _trace, ask_approval }
import from .sigil_runtime { commit_now }
import from .agent { run_task }

# ---------------------------------------------------------------------------
# Naming + description — one skill, one tool
# ---------------------------------------------------------------------------
def tool_name(signature: str) -> str {
    # The same shape `sigil_mcp_serve` publishes outward, so a skill answers to
    # one name whichever side of the harness is calling it.
    safe = re.sub(r"[^0-9A-Za-z_]", "_", str(signature or "skill"));
    return ("skill_" + safe)[:64];
}

def describe(row: dict) -> str {
    # The description IS the trigger — this is what the model routes on, so it
    # leads with what the skill is for and closes with whether it has ever
    # worked. A skill with a track record is a safer reach than one without.
    sig = str(row.get("signature", ""));
    intent = str(row.get("intent", "") or "").strip().replace(chr(10), " ");
    runs = int(row.get("runs", 0) or 0);
    ok = int(row.get("successes", 0) or 0);
    head = intent if intent else ("Run the compiled '" + sig + "' skill.");
    rec = (" [compiled skill '" + sig + "' v" + str(row.get("version", 1)) + "; "
           + (str(ok) + "/" + str(runs) + " runs succeeded" if runs else "not yet run") + "]");
    return (head + rec
            + " Runs the COMPILED procedure end to end — its steps are executed by the"
            + " harness, not re-derived by you — and returns its report. Prefer this over"
            + " doing the same work by hand with the file/shell tools.");
}

def gated_library() -> list {
    # The skills this agent may see, policy applied. Deny wins, then allow-list —
    # the shared rule from `tool_allowed`, keyed on the tool name so the operator
    # writes `configure tool_deny skill_clean_csv` and means it everywhere.
    out: list = [];
    for e in library() {
        if tool_allowed(tool_name(str(e.get("signature", "")))) { out.append(e); }
    }
    return out;
}

# ---------------------------------------------------------------------------
# The approval gate
# ---------------------------------------------------------------------------
def gate(signature: str, task: str) -> str {
    # "" = go. Anything else is the refusal string the model gets back — a
    # sentence it can act on, never an exception through byLLM's tool runtime.
    subject = "skill:" + str(signature);
    g = check_exec(subject);
    dec = str(g["decision"]);
    if dec == "allow" { return ""; }
    if dec == "deny" {
        _trace("skill", signature + " (denied)", False);
        return ("DENIED by policy: the skill '" + signature + "' may not be run ("
                + str(g["reason"]) + "). Nothing was run.");
    }
    # approval-pending: ask whoever is at the prompt. A yes allowlists the skill
    # (not the run) — the operator answered "you may use this procedure", the
    # same allow-always ws_exec grants a command it approves.
    if ask_approval(subject + ("  " + str(task)[:80] if task else "")) {
        allowlist_add(subject);
        return "";
    }
    _trace("skill", signature + " (needs approval)", False);
    return ("BLOCKED: running the compiled skill '" + signature + "' needs operator "
            + "approval. It is queued — the operator can allow it with "
            + "`sigil approvals approve \"skill:" + signature + "\" allow-always`. Nothing was run.");
}

# ---------------------------------------------------------------------------
# The runner — one place every skill invocation goes through
# ---------------------------------------------------------------------------
def _tail_progress(path: str, flag: dict) -> None {
    # The compiled module appends one JSON line per node entry to $AGIR_PROGRESS;
    # turn those into live `skill ▸ <node>` trace lines while the run is going,
    # so a multi-minute procedure is visible instead of a frozen spinner.
    seen = 0;
    while True {
        try {
            with open(path, "r") as f { lines = f.read().splitlines(); }
            for ln in lines[seen:] {
                try { _trace("skill", chr(0x25B8) + " " + str(json.loads(ln).get("node", ""))); }
                except Exception as e2 {}
            }
            seen = len(lines);
        } except Exception as e {}
        if flag.get("done") { break; }   # after a final drain above
        time.sleep(0.4);
    }
}

glob _RUN_LOCK: threading.Lock = threading.Lock();   # see run_skill

def run_skill(signature: str, task: str = "") -> str {
    # Run an already-compiled skill IN THIS PROCESS on THIS graph, gated, with
    # the node path streamed live. Never raises: every failure is a sentence.
    #
    # Serialized process-wide by _RUN_LOCK. Sub-agents fan out on a thread pool
    # (src/sigil_subagents.jac), and a skill run is the first sub-agent tool that
    # WRITES the agent graph — run counts, an Attempt node, an eval verdict on
    # the shared Registry hub, then a commit. Two of those interleaving would race
    # on the same anchors and then race again at the commit, where the loser's
    # whole changeset is discarded (`commit_now`). The work inside is a subprocess
    # that takes minutes, so queueing costs wall-clock — and a silently-lost run
    # record costs the library's memory of what works, which is worse. Sub-agents
    # doing anything else still overlap; only skill runs line up.
    sig = str(signature).strip();
    lib = gated_library();
    known = [str(e["signature"]) for e in lib];
    if sig not in known {
        _trace("skill", sig + " (not compiled)", False);
        if not known { return "no compiled skills yet — sigil_compile a SKILL.md, or learn_skill for new work. Nothing was run."; }
        return "no compiled skill '" + sig + "'. Compiled: " + ", ".join(known) + ". Nothing was run.";
    }
    t: str = str(task).strip();
    if not t {
        for e in lib { if str(e["signature"]) == sig { t = str(e.get("intent") or sig); } }
    }
    blocked = gate(sig, t);
    if blocked { return blocked; }
    _RUN_LOCK.acquire();
    try { return _run_locked(sig, t); }
    finally { _RUN_LOCK.release(); }
}

def _run_locked(sig: str, t: str) -> str {
    _trace("skill", sig + "  <-  " + t[:120]);
    ppath = os.path.join(tempfile.mkdtemp(prefix="sigil_skill_"), "agir.progress");
    prev = os.environ.get("AGIR_PROGRESS");
    os.environ["AGIR_PROGRESS"] = ppath;
    flag: dict = {"done": False};
    th = threading.Thread(target=_tail_progress, args=(ppath, flag), daemon=True);
    th.start();
    r: dict = {};
    try {
        r = run_task(t, sig);
    } finally {
        flag["done"] = True;
        try { th.join(2.0); } except Exception as e {}
        if prev is None { os.environ.pop("AGIR_PROGRESS", None); }
        else { os.environ["AGIR_PROGRESS"] = prev; }
    }
    # A run mutates the graph in-process (run counts, Attempts, eval verdicts on
    # the Registry hub) — commit before those writes can age into a lost race.
    warn = commit_now("skill:" + sig);
    # the honest route story — route/HIT/eval/relearn — onto the trace, warts and all
    for ln in str(r.get("trace") or "").splitlines() {
        cl = str(ln).strip();
        if cl and (not cl.startswith("prompt-mode")) { _trace("skill", cl); }
    }
    out = "skill '" + str(r.get("signature") or sig) + "' finished.\n" + str(r.get("result") or "")[:6000];
    return (out + "\nWARNING: " + warn) if warn else out;
}

# ---------------------------------------------------------------------------
# The tools themselves
# ---------------------------------------------------------------------------
def _make_tool(signature: str, description: str) -> any {
    # One byLLM Tool per skill, minted fresh each turn. byLLM reads a tool's name
    # from `func.__name__`, its description from `_jac_semstr`, and its parameter
    # docs from `_jac_semstr_inner` — the same three things a `sem` block sets on
    # a static tool, set here on a closure instead.
    ::py::
    def _runner(task: str = "") -> str:
        return run_skill(signature, task)

    _runner.__name__ = tool_name(signature)
    _runner.__qualname__ = _runner.__name__
    _runner.__annotations__ = {"task": str, "return": str}
    _runner.__doc__ = description
    _runner._jac_semstr = description
    _runner._jac_semstr_inner = {
        "task": "The task to run this skill on, in plain language. "
                "Leave empty to run it on what it is for.",
    }
    ::py::
    fn: any = _runner;
    return Tool(func=fn);
}

def skill_tools() -> list {
    # THE tool list. Pass it straight into `by llm(tools=[...] + skill_tools())`:
    # byLLM re-evaluates call params per invocation, so this reflects the library
    # as it stands right now, policy already applied.
    out: list = [];
    for e in gated_library() {
        try { out.append(_make_tool(str(e.get("signature", "")), describe(e))); }
        except Exception as ex {}   # one malformed entry must not cost the whole belt
    }
    return out;
}

def skill_tool_index() -> list {
    # What the tool list contains, as plain data — for the REPL's `/skills`, the
    # CLI, and tests that should not have to introspect byLLM objects.
    return [{"tool": tool_name(str(e.get("signature", ""))), "signature": str(e.get("signature", "")),
             "intent": str(e.get("intent", "") or ""), "runs": int(e.get("runs", 0) or 0),
             "successes": int(e.get("successes", 0) or 0)} for e in gated_library()];
}

def skill_manifest(exclude: str = "") -> str {
    # The same shelf, JSON, for a run that happens in ANOTHER process: a compiled
    # artifact executes in an isolated `jac run` subprocess with no access to this
    # graph, so `sigil_runtime.execute_module` hands it this manifest through
    # SIGIL_SKILL_TOOLS and the artifact's prelude rebuilds the tools from it.
    # `exclude` drops the running skill itself — a procedure that can call itself
    # is a recursion waiting to happen.
    rows: list = [];
    for e in gated_library() {
        sig = str(e.get("signature", ""));
        if exclude and (sig == str(exclude)) { continue; }
        mod = str(e.get("module", "") or "");
        if not mod { continue; }          # nothing on disk to run
        # The MODULE STEM, not its path: the artifact runs with the crystallized
        # package on its path (sigil_runtime's driver convention), so a sibling is
        # `crystallized.<stem>` from in there — the same import its own driver used.
        stem = os.path.splitext(os.path.basename(mod))[0];
        rows.append({"name": tool_name(sig), "signature": sig,
                     "module": stem, "description": describe(e)});
    }
    return json.dumps(rows) if rows else "";
}
