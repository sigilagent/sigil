"""Sub-agents — parallel focused workers, fanned out with Jac's `flow`/`wait`.

The chat agent delegates independent sub-tasks to sub-agents that run
*concurrently*: each is a `SubAgent` walker `spawn`ed on `root` inside a `flow`
expression (launched on the thread pool), joined with `wait`. Because LLM/tool
calls are I/O-bound, N sub-agents finish in ~1× wall-clock, not N×.

A sub-agent is itself a small ReAct loop over the sandboxed workspace tools
(read/write/edit/list/exec/web) — but deliberately WITHOUT the spawn or cron
tools, so sub-agents cannot recurse or schedule. They do real work (files, shell,
web) and return a short text result the parent synthesizes. They never mutate the
persistent agent graph, so running many at once is safe.
"""

import from jaclang.byllm.lib { Model }
import from .sigil { bind_chat_model }
import from .sigil_workspace {
    ws_read, ws_write, ws_edit, ws_list, ws_exec, web_fetch, web_search, _trace
}

glob sub_llm: any = Model(model_name="gpt-4o-mini");
glob _SUB_PINNED: bool = False;   # when set, don't rebind from the graph (tests / embedders pin a model)

def pin_sub_llm(m: any) -> None {
    global sub_llm, _SUB_PINNED;
    sub_llm = m;
    _SUB_PINNED = True;
}

def _ensure_sub_llm() -> None {
    global sub_llm;
    if not _SUB_PINNED { sub_llm = bind_chat_model(); }
}

sem subagent_run = """You are a focused sub-agent. Complete the single TASK using
the workspace tools, then return a SHORT (1-3 sentence) result stating exactly what
you did and where any output landed. Do the work — don't ask questions.""";
sem subagent_run.task = "The one self-contained sub-task to complete.";
def subagent_run(task: str) -> str by sub_llm(
    tools=[ws_read, ws_write, ws_edit, ws_list, ws_exec, web_fetch, web_search],
    max_react_iterations=8
);

walker SubAgent {
    has task: str;
    has result: str = "";
    has ok: bool = True;
    can run with Root entry {
        try {
            self.result = subagent_run(self.task);
        } except Exception as e {
            self.result = "sub-agent error: " + str(e)[:200];
            self.ok = False;
        }
    }
}

def spawn_subagents(tasks: list[str]) -> str {
    # Fan out one SubAgent per task, CONCURRENTLY (flow launches, wait joins).
    if not tasks { return "no sub-tasks given"; }
    _ensure_sub_llm();
    _trace("subagents", str(len(tasks)) + " parallel worker(s)");
    futures = [flow (root spawn SubAgent(task=t)) for t in tasks];   # all launch now
    walkers = [wait f for f in futures];                            # then join
    parts: list = [];
    i = 1;
    for w in walkers {
        parts.append("[sub-agent " + str(i) + "] " + ("ok" if w.ok else "FAILED") + ": " + str(w.result));
        i += 1;
    }
    return "\n".join(parts);
}

sem spawn_subagent = """Delegate ONE self-contained sub-task to a focused sub-agent
that runs it end-to-end with its own workspace tools and returns a short result.
Use this to offload a chunk of work while you keep planning.""";
sem spawn_subagent.task = "A single, self-contained sub-task the sub-agent should complete on its own.";
def spawn_subagent(task: str) -> str {
    return spawn_subagents([task]);
}

sem spawn_parallel = """Run several INDEPENDENT sub-tasks in PARALLEL, one sub-agent
each, and get all their results together. Use this when sub-tasks don't depend on
each other (e.g. research three topics at once, or process several files) — they
finish in roughly the time of the slowest one, not the sum.""";
sem spawn_parallel.tasks = "A list of independent sub-tasks; each runs in its own parallel sub-agent.";
def spawn_parallel(tasks: list[str]) -> str {
    return spawn_subagents(tasks);
}
