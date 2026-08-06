"""The runtime half of the agent — everything that is NOT the compiler.

Sigil is two things wearing one name: a compiler that authors skills, and a
runtime that owns an identity and runs them. They lived in one module, and that
made the runtime impossible to ship on its own — bundling cron meant bundling the
whole AI front-end, because cron imports this hub and this hub imported
`transpile_ir`.

So the hub is split at its real seam. Here: the Soul and its graph, semantic
memory, model tiers, the MCP registry, the skill library, tool policy, config,
the views, and `run_compiled` — executing a procedure that already exists.
In `sigil.jac`: authoring one that does not.

Nothing in this file may import the compiler. That constraint is what makes
`sigil eject-agent` able to produce a runtime with no compiler in it, and there
is a test asserting it.
"""

import os;
import json;
import from .sigil_mcp { digest, tools_for }
import from .sigil_claude_cc { install as install_claude_cc, is_claude_cc }
import from jaclang.byllm.lib { Model, ModelPool }
import from .sigil_runtime {
    write_module, execute_module, default_contract, repo_root, agir_name, install_osp,
    skill_description
}
import from .sigil_cron { now_ms }
import from .views { VNode, VEdge, VGraph, VCall, VObs }

glob FRONTIER_NAME: str = os.getenv("SIGIL_FRONTIER", "gpt-5");
glob SMALL_NAME: str    = os.getenv("SIGIL_SMALL", "ollama_chat/qwen3:32b");
glob ROUTER_NAME: str   = os.getenv("SIGIL_ROUTER", os.getenv("SIGIL_SMALL", "ollama_chat/qwen3:32b"));

# A tier holds a single Model, or a ModelPool (fallback chain) once configured.
glob frontier: any = Model(model_name=FRONTIER_NAME);
glob small: any    = Model(model_name=SMALL_NAME);
glob router: any   = Model(model_name=ROUTER_NAME);

# `--claude` (or SIGIL_CLAUDE=1): every tier is answered by the local Claude Code
# CLI instead of a provider API — one subscription, no keys, and the whole LIFT
# front-end authored by Claude. Read at bind time, so flipping it before awaken()
# is enough. See sigil_claude_cc.
glob CLAUDE_TIERS: bool = bool(os.getenv("SIGIL_CLAUDE", ""));

glob WORKDIR: str  = repo_root();
glob CONTRACT: str = default_contract();
glob ETHOS: str    = "";   # the soul's operating principles, rebound from the graph at awaken()
glob PROMPT_MODE: str = "full";  # full | minimal | none — how much context wraps the compiler/run

# ---------------------------------------------------------------------------
# Cognition — the ONLY model calls in the system. Everything else is graph
# mechanics + deterministic compile/run.
# ---------------------------------------------------------------------------
sem classify = """Route a TASK against the agent's KNOWN compiled task-type
signatures. Return EXACTLY one of:
  - a signature from KNOWN, if the compiled procedure already covers this task;
  - 'MUTATE:<signature>' if a known type is close but must be extended to fit;
  - 'NONE' if no known type fits and a new procedure must be compiled.
Judge by the *class* of task, not surface wording.""";
def classify(task: str, known: list[str]) -> str by router();



# ---------------------------------------------------------------------------
# These archetypes moved here from `sigil.jac` when the hub was split, and a
# persisted anchor records the module it was written under. Without an alias,
# every existing graph would quarantine its Soul and its whole skill library on
# the next run and come back empty — the split would have silently destroyed
# every agent already in the world. `@archetype_alias` maps the old name to the
# new class; the graph loads unchanged.
# ---------------------------------------------------------------------------
@archetype_alias("src.sigil.Embodies")
edge Embodies {}       # root -> Soul       (the agent's identity/config, on the graph)
@archetype_alias("src.sigil.Knows")
edge Knows {}          # Soul -> Spec       (the compiler's contract, on the graph)
@archetype_alias("src.sigil.Provides")
edge Provides {}       # Soul -> McpServer  (registered external tool servers)
@archetype_alias("src.sigil.Remembers")
edge Remembers {}      # Soul -> Memory     (semantic memory)
@archetype_alias("src.sigil.Owns")
edge Owns {}           # Soul -> Registry
@archetype_alias("src.sigil.Anchored")
edge Anchored {}       # root -> Registry   (the skill library, hung off the persistent root)
@archetype_alias("src.sigil.Crystallized")
edge Crystallized {}   # Registry -> TaskGraph (legacy edge name — persisted on existing graphs)
@archetype_alias("src.sigil.Ran")
edge Ran {}            # TaskGraph -> Attempt
@archetype_alias("src.sigil.MutatedFrom")
edge MutatedFrom {}    # TaskGraph(new) -> TaskGraph(old)  (evolution lineage)

# --- Identity / config (OpenClaw's SOUL, but a node — not a SOUL.md) --------
@archetype_alias("src.sigil.Soul")
node Soul {
    has name: str = "sigil";
    has persona: str = "";        # voice / character
    has ethos: list[str] = [];    # operating principles, woven into compilation
    has frontier_model: str = ""; # cognition config — lives on the graph, not env
    has small_model: str = "";
    has router_model: str = "";
    has channels: list[str] = []; # where the agent is reachable (pure config, on the graph)
    has auto_eval: bool = True;   # grounded-eval valve: judge each HIT run, relearn if it fails
    has eval_threshold: int = 60; # a run scoring below this auto-triggers a relearn + retry
    has model_aliases: dict = {};    # friendly name -> model string (e.g. "fast" -> "gpt-4o-mini")
    has model_fallbacks: dict = {};  # tier ("frontier"|"small"|"router") -> comma-sep fallback models
    has prompt_mode: str = "full"; # system-prompt assembly: full (ethos+memory) | minimal (contract only) | none (bare task)
    has tool_allow: list[str] = [];   # tool policy: if non-empty, only these tools (+groups/profile) are permitted
    has tool_deny: list[str] = [];    # denied tools (deny wins over allow); "*" denies all
    has tool_groups: dict = {};       # group name -> comma-separated tool names
    has tool_profile: str = "";       # active profile = a group whose tools join the allow-list
    has recall_mode: str = "lexical";  # lexical | vector | hybrid — how semantic memory is retrieved
    has embed_model: str = "";         # embedding model (litellm name) for vector/hybrid recall
    has chat_model: str = "";          # user-facing chat-mode model tier; falls back to frontier_model (the strong one)
    has workspace: str = "";           # where the tools work by default — relative paths and shell jobs resolve here (default ~/.sigil/workspace)
    has sandbox: str = "off";          # containment for the file/shell tools: off (full host access, default) | jail | docker
    has verbose: bool = False;         # stream the model's raw output as it is generated (opt-in debugging view)
}

@archetype_alias("src.sigil.Spec")
node Spec {
    has kind: str = "agir-contract";
    has body: str = "";           # the compiler's contract text, seeded onto the graph
}

# --- External MCP servers the user registers (BYO tools), config on the graph
@archetype_alias("src.sigil.McpServer")
node McpServer {
    has name: str;
    has transport: str = "stdio"; # stdio | http | sse | streamable-http
    has command: str = "";        # stdio: executable
    has args: list[str] = [];
    has url: str = "";            # http/sse: endpoint
    has enabled: bool = True;
}

# --- Semantic memory: durable facts the agent carries across tasks ----------
@archetype_alias("src.sigil.Memory")
node Memory {
    has content: str;
    has kind: str = "fact";       # fact | preference | observation
    has salience: float = 1.0;
    has uses: int = 0;
    has embedding: list = [];      # cached embedding vector (populated lazily in vector recall mode)
}

@archetype_alias("src.sigil.Registry")
node Registry {
    has name: str = "sigil";
}

@archetype_alias("src.sigil.TaskGraph")
node TaskGraph {
    has signature: str;
    has intent: str;
    has agir: str;         # the frontier-authored AG-IR (the contract)
    has module: str;       # path to the lowered OSP on disk
    has version: int = 1;
    has origin: str = "frontier";   # 'frontier' | 'mutation' | 'relearn'
    has runs: int = 0;
    has successes: int = 0;
    has last_score: int = -1;       # last grounded-eval score (0-100); -1 = never evaluated
    has last_eval: str = "";        # last eval verdict (one-line reason)
}

@archetype_alias("src.sigil.Attempt")
node Attempt {
    has task: str;
    has ok: bool;
    has model: str;
    has summary: str = "";
    has at_ms: int = 0;    # epoch-ms of the run, for the task ledger (tasks list/show)
}

# ---------------------------------------------------------------------------
# Graph operations (deterministic — no model calls except the byLLM defs above).
# ---------------------------------------------------------------------------
def latest_by_sig(compiled_lib: list[TaskGraph]) -> list[TaskGraph] {
    # Keep only the highest-version TaskGraph per signature.
    best: dict = {};
    for c in compiled_lib {
        cur = best.get(c.signature);
        if (cur is None) or (c.version > cur.version) { best[c.signature] = c; }
    }
    out: list[TaskGraph] = [];
    for c in compiled_lib {
        if best.get(c.signature) is c { out.append(c); }
    }
    return out;
}

# ---------------------------------------------------------------------------
# Soul / config — everything lives on the graph. awaken() get-or-creates the
# Soul + seeds the contract onto the graph, then rebinds the cognition globals
# from graph config (so the model tiers, ethos, and contract are all graph state,
# not env or files). Mirrors how a compiled agent rebinds `llm` in run().
# ---------------------------------------------------------------------------
def model_for(name: str) -> Model {
    # A `claude-cc/...` tier is answered by the local Claude Code CLI instead of a
    # provider API: register the litellm handler on first use, and declare no
    # native tool support so byLLM carries the tool list and the output schema as
    # prose, which is all a `claude -p` reply can be. See sigil_claude_cc.
    if is_claude_cc(name) {
        install_claude_cc();
        return Model(model_name=name, config={"native_tools": False});
    }
    return Model(model_name=name);
}

def _resolve_alias(soul: Soul, name: str) -> str {
    return str(soul.model_aliases.get(name, name));
}

def use_claude_code(on: bool = True) {
    # Flip every tier onto Claude Code. Call BEFORE awaken() — that is where the
    # tiers bind. Also arms the compiler's escalation path: with Claude Code
    # already the compiler, a failed compile gets a tool-using session that can
    # run the oracle itself (compiler/ai/repair.jac reads this via env, so the
    # compiler keeps no back-edge to the runtime that imports it).
    CLAUDE_TIERS = on;
    os.environ["SIGIL_CLAUDE_REPAIR"] = "1" if on else "";
}

def verbose_mode() -> bool {
    # Show the model's output as it is generated. OFF by default: the stage
    # lines (spec loop / spine / flows / gates, with their one-line summaries)
    # are the compile's progress story; the raw token stream is a debugging
    # view. Opt in per run with SIGIL_VERBOSE=1 or persistently with
    # `configure verbose on`; `--quiet` overrides both, for a pipe.
    env = (os.getenv("SIGIL_VERBOSE") or "").strip().lower();
    if env { return env in ["1", "true", "yes", "on"]; }
    try { return bool(awaken().verbose); } except Exception as e { return False; }
}

def claude_mode() -> bool {
    # Is every tier currently answered by the local Claude Code CLI? Read by the
    # tool-belt, which routes web search onto the same subscription rather than
    # demanding a search-provider key the user never needed for anything else.
    return bool(CLAUDE_TIERS);
}

def _claude_tier_model(tier: str) -> str {
    # frontier/chat author and compile — the expensive, rare, judgment-heavy work.
    # small/router execute an already-compiled procedure and classify: cheap tier.
    if (tier == "frontier") or (tier == "chat") {
        return os.getenv("SIGIL_CLAUDE_FRONTIER", "claude-cc/opus");
    }
    return os.getenv("SIGIL_CLAUDE_SMALL", "claude-cc/haiku");
}

def _effective_tier(tier: str, name: str) -> str {
    # What the tier will actually bind to, after the claude-mode override.
    return _claude_tier_model(tier) if (CLAUDE_TIERS and not is_claude_cc(name)) else name;
}

def _bind_tier(soul: Soul, tier: str, tier_model: str) -> any {
    # Resolve the tier's model (through any alias) and, if the tier has a fallback
    # chain configured, return a byLLM ModelPool that fails over primary -> fallbacks.
    primary = _effective_tier(tier, _resolve_alias(soul, tier_model));
    fb = str(soul.model_fallbacks.get(tier, "")).strip();
    if not fb { return model_for(primary); }
    models: list = [model_for(primary)];
    for m in fb.split(",") {
        mm = _resolve_alias(soul, m.strip());
        if mm { models.append(model_for(mm)); }
    }
    return ModelPool(models=models, strategy="fallback");
}

def bind_chat_model() -> any {
    # The model that powers chat-mode + sub-agents. Chat is the user-facing surface and
    # has no compiled procedure to lean on, so it wants the STRONG model: the `chat`
    # tier falls back to `frontier` (not `small` — the small tier is for executing
    # already-compiled skills). Rebound from the graph so `configure chat_model` takes
    # effect next turn. Returns a Model, or a ModelPool when a fallback chain is set.
    soul = awaken();
    name = soul.chat_model if soul.chat_model else (soul.frontier_model if soul.frontier_model else "gpt-4o");
    return _bind_tier(soul, "chat", name);
}

def model_alias(name: str, target: str) -> str {
    soul = awaken();
    al = dict(soul.model_aliases);
    al[name] = target;
    soul.model_aliases = al;
    return "alias  " + name + " -> " + target;
}

def model_set_fallback(tier: str, csv: str) -> str {
    soul = awaken();
    fb = dict(soul.model_fallbacks);
    fb[tier] = csv;
    soul.model_fallbacks = fb;
    return tier + " fallbacks -> " + (csv if csv else "(none)");
}

def models_info() -> dict {
    soul = awaken();
    # In claude mode the graph's tier names are overridden at bind time, so report
    # what will actually run — not the config it shadows.
    return {
        "frontier": _effective_tier("frontier", soul.frontier_model),
        "small": _effective_tier("small", soul.small_model),
        "router": _effective_tier("router", soul.router_model if soul.router_model else soul.small_model),
        "aliases": dict(soul.model_aliases), "fallbacks": dict(soul.model_fallbacks)
    };
}

def awaken() -> Soul {
    found = [root -->[?:Soul]];
    if found {
        soul = found[0];
    } else {
        soul = Soul(
            name="sigil",
            persona="A pragmatic operator that compiles tasks into reliable, minimal procedures and runs them cheaply.",
            ethos=[
                "Prefer mechanized structure over prose.",
                "Never leave a step unembodied.",
                "Ground verification in the real artifact, not a proxy.",
                "Reuse a compiled procedure before authoring a new one."
            ],
            frontier_model=os.getenv("SIGIL_FRONTIER", "gpt-5"),
            small_model=os.getenv("SIGIL_SMALL", "ollama_chat/qwen3:32b"),
            router_model=os.getenv("SIGIL_ROUTER", ""),
            channels=["cli"]
        );
        root +>:Embodies:+> soul;
        reg = Registry();
        root +>:Anchored:+> reg;
        soul +>:Owns:+> reg;
        soul +>:Knows:+> Spec(kind="agir-contract", body=default_contract());
    }
    # rebind cognition from the graph
    frontier = _bind_tier(soul, "frontier", soul.frontier_model);
    small = _bind_tier(soul, "small", soul.small_model);
    # Not soul.small_model directly: this name is handed to the compiled module's
    # subprocess as SIGIL_MODEL, so it has to be the EFFECTIVE tier, or claude mode
    # would cover the compiler and leave execution on the graph's configured model.
    SMALL_NAME = _effective_tier("small", soul.small_model);
    router = _bind_tier(soul, "router", soul.router_model if soul.router_model else soul.small_model);
    PROMPT_MODE = soul.prompt_mode if soul.prompt_mode else "full";
    # ethos is woven into compilation only in full mode; minimal/none keep the
    # compiler to the structural contract (contract is always required for valid AG-IR).
    ETHOS = ("\n".join(["- " + e for e in soul.ethos])) if PROMPT_MODE == "full" else "";
    specs = [soul -->[?:Spec]];
    if specs { CONTRACT = specs[0].body; }
    _publish_tool_policy(soul);   # expose the tool policy to binding + run-time dispatch via env
    return soul;
}

# ---------------------------------------------------------------------------
# Semantic memory — durable facts the agent carries across tasks. recall() is
# deterministic (lexical overlap + salience), so retrieval needs no model.
# ---------------------------------------------------------------------------
def _tokens(s: str) -> set[str] {
    out: set[str] = set();
    for w in s.lower().replace(",", " ").replace(".", " ").split() {
        if len(w) > 2 { out.add(w); }
    }
    return out;
}

def remember(soul: Soul, content: str, kind: str) -> Memory {
    m = Memory(content=content, kind=kind);
    soul +>:Remembers:+> m;
    return m;
}

def _embed(text: str, model: str) -> list {
    # Embed via litellm (byLLM's backend) — works for any provider it supports
    # (openai text-embedding-3-*, ollama/nomic-embed-text, …). Non-raising.
    try {
        import litellm;
        r = litellm.embedding(model=model, input=[text]);
        return list(r["data"][0]["embedding"]);
    } except Exception as e { return []; }
}

def _cosine(a: list, b: list) -> float {
    if (not a) or (not b) or (len(a) != len(b)) { return 0.0; }
    import math;
    dot = 0.0; na = 0.0; nb = 0.0;
    for (x, y) in zip(a, b) {
        fx = float(x); fy = float(y);
        dot += fx * fy; na += fx * fx; nb += fy * fy;
    }
    if (na == 0.0) or (nb == 0.0) { return 0.0; }
    return dot / (math.sqrt(na) * math.sqrt(nb));
}

def recall(soul: Soul, query: str, k: int) -> list[Memory] {
    mode = soul.recall_mode if soul.recall_mode else "lexical";
    emodel = str(soul.embed_model);
    # tuple = (-score, seq, memory); seq is a strict tie-breaker so nodes never compare
    scored: list = [];
    seq = 0;

    if (mode in ["vector", "hybrid"]) and emodel {
        qv = _embed(query, emodel);
        if qv {   # embedding available -> semantic (optionally hybrid with lexical)
            q = _tokens(query);
            for m in [soul -->[?:Memory]] {
                if not m.embedding { m.embedding = _embed(m.content, emodel); }   # lazy, cached
                vscore = _cosine(qv, list(m.embedding));
                lscore = (len(q & _tokens(m.content)) * 0.05) if mode == "hybrid" else 0.0;
                total = (vscore * m.salience) + lscore;
                if total > 0.0 { scored.append((0.0 - total, seq, m)); seq += 1; }
            }
            scored.sort();
            picked: list[Memory] = [t[2] for t in scored[:k]];
            for m in picked { m.uses += 1; }
            return picked;
        }
    }

    # lexical (default, and the fallback when no embedding model / embedding fails)
    q = _tokens(query);
    for m in [soul -->[?:Memory]] {
        overlap = len(q & _tokens(m.content));
        if overlap > 0 {
            scored.append((0.0 - (overlap * m.salience), seq, m));
            seq += 1;
        }
    }
    scored.sort();
    picked: list[Memory] = [t[2] for t in scored[:k]];
    for m in picked { m.uses += 1; }
    return picked;
}

def memory_context(mems: list[Memory]) -> str {
    if not mems { return ""; }
    return "What the agent remembers:\n" + "\n".join(["- " + m.content for m in mems]) + "\n";
}

# The learning hook: distill durable facts from a completed task.
sem distill = """From a completed TASK and its RESULT, extract 0-3 DURABLE facts worth
remembering for future tasks (stable preferences, environment facts, conventions the
user relies on). Skip anything one-off or already obvious. Return a JSON list of short
strings; return [] if nothing is worth keeping.""";
def distill(task: str, result: str) -> list[str] by router();

# Grounded verification — the quality gate the bare ok/success counter cannot give.
# A compiled run can EXIT ok yet be WRONG (empty, echoed input, off-task). The
# grader judges the actual artifact against the task and scores it.
obj EvalVerdict {
    has score: int = 0;        # 0-100: how well RESULT accomplishes TASK
    has passed: bool = False;  # did it satisfy the task at all
    has reason: str = "";      # one concise sentence
}

sem judge_result = """You are a STRICT grader. Given a TASK and the RESULT a procedure
produced, decide whether the result correctly and completely accomplishes the task.
Be harsh: score LOW (<40) if the result is empty, merely echoes/repeats the task or its
input, ignores the instruction, is truncated, or is only partially right. Score HIGH
(>80) only when it fully and correctly satisfies the task. Judge the ARTIFACT, not the
intent.""";
def judge_result(task: str, result: str) -> EvalVerdict by router();


def mcp_servers() -> list {
    soul = awaken();
    out: list = [];
    for s in [soul -->[?:McpServer]] {
        d: dict = {"name": s.name, "transport": s.transport, "enabled": s.enabled};
        if s.transport == "stdio" { d["command"] = s.command; d["args"] = s.args; }
        else { d["url"] = s.url; }
        out.append(d);
    }
    return out;
}

def mcp_json() -> str {
    return json.dumps(mcp_servers());
}

def add_mcp(name: str, transport: str, target: str, args: list[str]) -> str {
    # target = executable (stdio) or url (http/sse). Mutates the graph; no file written.
    soul = awaken();
    srv = None;
    for s in [soul -->[?:McpServer]] { if s.name == name { srv = s; } }
    if srv is None { srv = McpServer(name=name); soul +>:Provides:+> srv; }
    srv.transport = transport;
    srv.enabled = True;
    if transport == "stdio" { srv.command = target; srv.args = args; }
    else { srv.url = target; }
    return "registered mcp server '" + name + "' (" + transport + ")";
}

def remove_mcp(name: str) -> str {
    soul = awaken();
    for s in [soul -->[?:McpServer]] { if s.name == name { del s; return "removed mcp server '" + name + "'"; } }
    return "no such mcp server: " + name;
}

def mcp_status() -> list {
    servers = mcp_servers();
    out: list = [];
    for srv in servers {
        tools = [];
        try { tools = [t.name for t in tools_for([srv])]; } except Exception as e { tools = ["<unreachable: " + str(e)[:60] + ">"]; }
        out.append({"name": srv["name"], "transport": srv["transport"], "tools": tools});
    }
    return out;
}

# ---------------------------------------------------------------------------
# Skill registration — three ingress forms, cheapest-effort to most-control:
#   SKILL.md (frontier lifts) | AG-IR (compile only) | OSP module (drop-in).
# Each becomes a TaskGraph on the graph, routable on the next task.
# ---------------------------------------------------------------------------

def run_compiled(tg: TaskGraph, task: str, context: str, skill: str) -> dict {
    # Small model executes the compiled OSP. The compiled PROCEDURE is
    # class-general; instance-specific semantic memory is injected here, at run
    # time, as a context preamble on the task — never baked into the procedure.
    # The user's registered MCP servers are exposed to the run's live tools.
    run_input = (context + "\nTask: " + task) if context else task;
    res = execute_module(tg.module, run_input, SMALL_NAME, skill, WORKDIR, 1800, mcp_json(), tg.signature);
    tg.runs += 1;
    if res["ok"] { tg.successes += 1; }
    a = Attempt(task=task, ok=bool(res["ok"]), model=SMALL_NAME, summary=str(res["report"])[:400], at_ms=now_ms());
    tg +>:Ran:+> a;
    return res;
}


def library() -> list {
    # The agent's compiled capability, latest version per signature.
    reg = [root -->][?:Registry];
    if not reg { return []; }
    out = [];
    for tg in latest_by_sig([reg[0] -->][?:TaskGraph]) {
        out.append({
            "signature": tg.signature, "version": tg.version, "origin": tg.origin,
            "runs": tg.runs, "successes": tg.successes, "module": tg.module,
            "intent": tg.intent   # what the skill is for — the MCP tool description
        });
    }
    return out;
}

def describe_soul() -> dict {
    soul = awaken();
    mems = [soul -->[?:Memory]];
    regs = [soul -->[?:Registry]];
    nskills = len(latest_by_sig([regs[0] -->[?:TaskGraph]])) if regs else 0;
    return {
        "name": soul.name, "persona": soul.persona, "ethos": soul.ethos,
        # EFFECTIVE tiers, not the graph values they shadow — the chat banner reads
        # `chat_model` to tell you who you are talking to, and in claude mode the
        # graph still says gpt-4o-mini while every word comes from Claude.
        "frontier_model": _effective_tier("frontier", soul.frontier_model),
        "small_model": _effective_tier("small", soul.small_model),
        "router_model": _effective_tier("router", soul.router_model if soul.router_model else soul.small_model),
        "chat_model": _effective_tier("chat", soul.chat_model if soul.chat_model else soul.frontier_model),
        "workspace": (soul.workspace if soul.workspace else "~/.sigil/workspace"),
        "sandbox": (soul.sandbox if soul.sandbox else "off"),
        "verbose": soul.verbose,
        "channels": soul.channels, "prompt_mode": soul.prompt_mode,
        "auto_eval": soul.auto_eval, "eval_threshold": soul.eval_threshold,
        "memories": [{"content": m.content, "kind": m.kind, "uses": m.uses} for m in mems],
        "skills": nskills
    };
}

def configure(key: str, value: str) -> str {
    # Mutate the soul (config) on the graph — no file is ever written.
    soul = awaken();
    if key == "persona" { soul.persona = value; }
    elif key == "frontier_model" { soul.frontier_model = value; }
    elif key == "small_model" { soul.small_model = value; }
    elif key == "router_model" { soul.router_model = value; }
    elif key == "name" { soul.name = value; }
    elif key == "add_ethos" { soul.ethos = soul.ethos + [value]; }
    elif key == "add_channel" { soul.channels = soul.channels + [value]; }
    elif key == "auto_eval" { soul.auto_eval = value.lower() in ["1", "true", "yes", "on"]; }
    elif key == "eval_threshold" { soul.eval_threshold = int(value); }
    elif key == "prompt_mode" {
        if value not in ["full", "minimal", "none"] { return "prompt_mode must be one of: full | minimal | none"; }
        soul.prompt_mode = value;
    }
    elif key == "tool_allow" { soul.tool_allow = [x.strip() for x in value.split(",") if x.strip()]; }
    elif key == "tool_deny" { soul.tool_deny = [x.strip() for x in value.split(",") if x.strip()]; }
    elif key == "tool_profile" { soul.tool_profile = value; }
    elif key == "recall_mode" {
        if value not in ["lexical", "vector", "hybrid"] { return "recall_mode must be one of: lexical | vector | hybrid"; }
        soul.recall_mode = value;
    }
    elif key == "embed_model" { soul.embed_model = value; }
    elif key == "chat_model" { soul.chat_model = value; }
    elif key == "workspace" { soul.workspace = value; }
    elif key == "verbose" {
        soul.verbose = value.lower() in ["1", "true", "yes", "on"];
        return "verbose = " + ("on" if soul.verbose else "off");
    }
    elif key == "sandbox" {
        # Default is `off`: Sigil's job is to drive the tools and agents already on
        # this machine, which containment would cut it off from. `jail`/`docker` are
        # there for when you'd rather have the boundary than the reach.
        if value not in ["off", "jail", "docker"] { return "sandbox must be one of: off | jail | docker"; }
        soul.sandbox = value;
    }
    else { return "unknown key: " + key; }
    return key + " = " + value;
}

# ---------------------------------------------------------------------------
# Config-mutation tools — the chat agent (chat_agent.jac) calls these to change
# the agent's own settings mid-conversation: the model tier, persona, or prompt
# mode. Each just wraps `configure`, so the change persists on the graph.
# ---------------------------------------------------------------------------
def cfg_set_model(tier: str, name: str) -> str { return configure(tier + "_model", name); }
sem cfg_set_model = "Change one of the agent's model tiers.";
sem cfg_set_model.tier = "Which tier: 'frontier' (builds skills), 'small' (runs them), 'router', or 'chat'.";
sem cfg_set_model.name = "The model name, e.g. 'gpt-4o', 'gpt-4o-mini', or 'ollama_chat/qwen3:8b'.";

def cfg_set_persona(text: str) -> str { return configure("persona", text); }
sem cfg_set_persona = "Set the agent's persona — its voice and character.";
sem cfg_set_persona.text = "The new persona description.";

def cfg_set_prompt_mode(mode: str) -> str { return configure("prompt_mode", mode); }
sem cfg_set_prompt_mode = "Set how much context wraps the agent: 'full', 'minimal', or 'none'.";
sem cfg_set_prompt_mode.mode = "One of: full | minimal | none.";

# --- Tool policy (allow / deny / groups / profile) --------------------------
def tool_group_set(name: str, csv: str) -> str {
    soul = awaken();
    g = dict(soul.tool_groups); g[name] = csv; soul.tool_groups = g;
    return "tool group '" + name + "' = " + csv;
}

def _expand_policy(soul: Soul) -> dict {
    # profile = a group whose tools join the allow-list
    allow = [str(x) for x in soul.tool_allow];
    deny = [str(x) for x in soul.tool_deny];
    prof = str(soul.tool_profile);
    if prof and (prof in soul.tool_groups) {
        for t in str(soul.tool_groups.get(prof, "")).split(",") { tt = t.strip(); if tt and (tt not in allow) { allow.append(tt); } }
    }
    return {"allow": allow, "deny": deny};
}

def tool_allowed(name: str) -> bool {
    eff = _expand_policy(awaken());
    if (name in eff["deny"]) or ("*" in eff["deny"]) { return False; }
    if eff["allow"] { return (name in eff["allow"]) or ("*" in eff["allow"]); }
    return True;
}

def tools_policy_info() -> dict {
    soul = awaken();
    eff = _expand_policy(soul);
    return {"allow": soul.tool_allow, "deny": soul.tool_deny, "profile": soul.tool_profile,
            "groups": dict(soul.tool_groups), "effective_allow": eff["allow"], "effective_deny": eff["deny"]};
}

def _publish_tool_policy(soul: Soul) {
    # expand the Soul policy into env the run subprocess + compiler binding both read
    eff = _expand_policy(soul);
    os.environ["SIGIL_TOOL_ALLOW"] = ",".join([str(x) for x in eff["allow"]]);
    os.environ["SIGIL_TOOL_DENY"] = ",".join([str(x) for x in eff["deny"]]);
}

# ---------------------------------------------------------------------------
# Eval / relearn / forget — grounded quality management of the skill library.
#   eval    : run a skill on a probe task, judge the artifact, record the score.
#   relearn : discard a degraded procedure and re-author it FRESH (frontier).
#   forget  : remove a skill entirely (all versions, attempts, module files).
# ---------------------------------------------------------------------------
def _find_skill(reg: Registry, signature: str) -> TaskGraph | None {
    # Latest version of the skill with this signature, or None.
    matches = [c for c in latest_by_sig([reg -->][?:TaskGraph]) if c.signature == signature];
    return matches[0] if matches else None;
}


def forget(signature: str) -> dict {
    # Remove a compiled skill entirely — every version, its attempts, and the
    # lowered module files on disk. Clears a stale/degenerate procedure.
    reg = [root -->][?:Registry][0];
    removed = 0;
    for tg in [reg -->][?:TaskGraph] {
        if tg.signature == signature {
            for a in [tg -->][?:Attempt] { del a; }
            if tg.module and os.path.exists(tg.module) { os.remove(tg.module); }
            del tg;
            removed += 1;
        }
    }
    return {"signature": signature, "removed": removed};
}

def teach(fact: str, kind: str = "fact") -> str {
    # Write a durable memory directly onto the graph.
    soul = awaken();
    remember(soul, fact, kind);
    return "remembered (" + kind + "): " + fact;
}

def recollect(query: str, k: int = 8) -> list {
    soul = awaken();
    return [{"content": m.content, "kind": m.kind, "uses": m.uses} for m in recall(soul, query, k)];
}

# ---------------------------------------------------------------------------
# Live observability — a snapshot of the agent's own graph (for the visualizer)
# and a tail of the token stream (every LLM call captured by sigil_observe).
# ---------------------------------------------------------------------------
def _nid(prefix: str, n: int) -> str { return prefix + str(n); }

def graph_snapshot() -> VGraph {
    # Serialize the whole agent graph as typed nodes/edges for the visualizer.
    soul = awaken();
    g = VGraph();
    g.nodes.append(VNode(id="soul", label=soul.name, group="soul", detail=soul.persona));
    regs = [soul -->[?:Registry]];
    reg = regs[0] if regs else None;
    if reg is not None {
        g.nodes.append(VNode(id="registry", label="registry", group="registry"));
        g.edges.append(VEdge(src="soul", kind="owns", dst="registry"));
    }
    servers = [soul -->[?:McpServer]];
    for s in servers {
        sid = _nid("mcp:", len(g.nodes));
        g.nodes.append(VNode(id=sid, label=s.name, group="mcp",
                             detail=s.transport + (" " + s.command if s.command else " " + s.url)));
        g.edges.append(VEdge(src="soul", kind="provides", dst=sid));
    }
    mi = 0;
    seen_mem: dict = {};
    for m in [soul -->[?:Memory]] {
        if m.content in seen_mem { continue; }
        seen_mem[m.content] = True;
        mid = _nid("mem:", mi); mi += 1;
        g.nodes.append(VNode(id=mid, label=m.content[:40], group="memory",
                             detail=m.kind + " · used " + str(m.uses) + "x"));
        g.edges.append(VEdge(src="soul", kind="remembers", dst=mid));
    }
    by_id: dict = {};
    ti = 0;
    if reg is not None {
        # latest version per signature (collapses duplicate registrations, like library())
        skills = latest_by_sig([reg -->[?:TaskGraph]]);
        for tg in skills {
            tid = _nid("tg:", ti); ti += 1;
            by_id[jid(tg)] = tid;
            g.nodes.append(VNode(id=tid, label=tg.signature + " v" + str(tg.version), group="skill",
                                 detail=tg.origin + " · " + str(tg.successes) + "/" + str(tg.runs) + " ok"));
            g.edges.append(VEdge(src="registry", kind="compiled", dst=tid));
        }
        for tg in skills {
            tid = str(by_id[jid(tg)]);
            for prev in [tg -->[?:TaskGraph]] {
                if jid(prev) in by_id { g.edges.append(VEdge(src=tid, kind="mutated-from", dst=str(by_id[jid(prev)]))); }
            }
            ai = 0;
            for a in [tg -->[?:Attempt]] {
                if ai >= 3 { break; }
                aid = tid + ":a" + str(ai); ai += 1;
                g.nodes.append(VNode(id=aid, label=("ok" if a.ok else "fail"),
                                     group=("attempt-ok" if a.ok else "attempt-fail"), detail=a.task[:60]));
                g.edges.append(VEdge(src=tid, kind="ran", dst=aid));
            }
        }
    }
    g.skills = ti; g.memories = mi; g.mcp = len(servers);
    return g;
}

def observability_tail(n: int = 120) -> VObs {
    import from .sigil_observe { read_tail }
    recs = read_tail(os.path.join(WORKDIR, "observability", "live.jsonl"), n);
    o = VObs();
    for raw in recs {
        r: dict = dict(raw);
        c = VCall(
            model=str(r.get("model", "?")),
            signature=str(r.get("signature", "")),
            prompt_tokens=int(r.get("prompt_tokens", 0) or 0),
            completion_tokens=int(r.get("completion_tokens", 0) or 0),
            reasoning_tokens=int(r.get("reasoning_tokens", 0) or 0),
            cache_read_tokens=int(r.get("cache_read_tokens", 0) or 0),
            cost_usd=float(str(r.get("cost_usd", 0) or 0)),
            content=str(r.get("content", "") or ""),
            reasoning=str(r.get("reasoning_content", "") or ""),
            tools=", ".join([str(t) for t in (r.get("tool_calls", []) or [])])
        );
        o.calls.append(c);
        o.tin += c.prompt_tokens; o.tout += c.completion_tokens; o.treason += c.reasoning_tokens;
        o.cost += c.cost_usd;
    }
    o.n = len(o.calls);
    return o;
}

# ---------------------------------------------------------------------------
# Server-mode endpoints (`jac start observatory.jac`) — the OpenClaw-style drop-in: a
# channel adapter POSTs to these. Swap `:pub` -> `:priv` and each user gets an
# isolated root graph (their own soul, skills, MCP servers) with JWT auth, for
# free. `has` fields are the request body; `report` is the response.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# HTTP endpoints.
#
# Every one of these resolves through `report_for`, which runs the request in a
# fresh `jac run` process against the agent's real graph — it does NOT touch the
# server's own root. That is not indirection for its own sake: measured, a server
# reports `skills: 0` while the CLI reports 9, and a `teach` through the server
# returned "remembered" while the fact landed in no anchor in the store. The
# Observatory was a window onto an empty, unsaved agent.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Routing without a compiler.
#
# The full agent's `solve` walker compiles on a miss, mutates on a failure and
# relearns on a bad grade — all frontier work. A runtime that shipped without the
# compiler cannot do any of that, and must not pretend to: on a miss it says so.
# This is the entry an ejected agent runs on.
# ---------------------------------------------------------------------------
walker solve_known {
    has task: str;
    has skill: str = "";
    has result: str = "";
    has trace: str = "";
    has signature: str = "";

    can enter with Root entry {
        soul = awaken();
        regs = [-->][?:Registry];
        if not regs {
            self.trace += "no skill library on this agent\n";
            self.result = "This agent has no skills.";
            self.trace += "DONE fail\n";
            disengage;
        }
        reg = regs[0];
        ctx = "";
        if PROMPT_MODE != "none" {
            mems = recall(soul, self.task, 5);
            ctx = memory_context(mems);
            if mems { self.trace += "recall -> " + str(len(mems)) + " memory\n"; }
        }
        compiled_lib: list[TaskGraph] = latest_by_sig([reg -->][?:TaskGraph]);
        known = [c.signature for c in compiled_lib];
        if not known {
            self.trace += "no skill library on this agent\n";
            self.result = "This agent has no skills.";
            self.trace += "DONE fail\n";
            disengage;
        }
        verdict = str(self.skill) if self.skill else classify(self.task, known);
        self.trace += "route -> " + verdict + "\n";
        matches: list[TaskGraph] = [c for c in compiled_lib if c.signature == verdict];
        if not matches {
            # A miss is an honest answer here, not a compile.
            self.trace += "MISS -> no skill covers this task\n";
            self.result = ("No skill on this agent covers that. It ships with: "
                           + ", ".join(known) + ".");
            self.trace += "DONE fail\n";
            disengage;
        }
        target: TaskGraph = matches[0];
        self.signature = target.signature;
        self.trace += "HIT " + target.signature + " -> run\n";
        res = run_compiled(target, self.task, ctx, self.skill);
        self.result = str(res["report"]);
        if res["ok"] and soul.auto_eval {
            try {
                ev = judge_result(self.task, self.result);
                target.last_score = ev.score;
                target.last_eval = ev.reason;
                self.trace += "eval -> " + str(ev.score) + "/100 (" + ev.reason + ")\n";
            } except Exception as e {
                self.trace += "eval skipped (" + str(e)[:80] + ")\n";
            }
        }
        if res["ok"] {
            try {
                facts = distill(self.task, self.result);
                for f in facts { remember(soul, f, "fact"); }
                if facts { self.trace += "learned -> " + str(len(facts)) + " memory\n"; }
            } except Exception as e {
                self.trace += "learn skipped (" + str(e)[:80] + ")\n";
            }
        }
        self.trace += ("DONE ok" if res["ok"] else "DONE fail") + "\n";
    }
}

def solve_known_task(task: str, skill: str = "") -> dict {
    w = root spawn solve_known(task=task, skill=skill);
    return {"signature": w.signature, "result": w.result, "trace": w.trace};
}


# ---------------------------------------------------------------------------
# Compile progress rendering. Pure string formatting with no compiler import,
# so an ejected runtime can still render a build view it did not produce.
# ---------------------------------------------------------------------------
glob _STAGE_LABELS: dict = {"spec": "spec loop", "spine": "workflow spine",
                            "flows": "annotator flows", "assemble": "assemble",
                            "gates": "gates", "repair": "repair",
                            "author": "claude authoring", "autofix": "mechanical fixes",
                            "bind": "env/par bind"};

def compile_stage_label(stage: str) -> str {
    return str(_STAGE_LABELS.get(stage, stage));
}

def compile_stage_line(ev: dict) -> str {
    # One-line summary of a finished stage: what it produced, not that it ran.
    s = str(ev["stage"]);
    if s == "spec" {
        m = "ok" if (ev["sound"] and ev["complete"] and not ev["drift"]) else "issues";
        return str(ev["rules"]) + " rules · " + str(ev["rounds"]) + " rounds · " + m;
    } elif s == "spine" {
        return str(ev["nodes"]) + " nodes · " + str(ev["edges"]) + " edges · " + str(ev["rounds"]) + " rounds" + ((" · " + str(ev["issues"]) + " issues") if ev["issues"] else "");
    } elif s == "flows" {
        return str(ev["carries"]) + " carries · " + str(ev["tools"]) + " tools · " + str(ev["knowledge"]) + " knowledge · " + str(ev["hil"]) + " HIL";
    } elif s == "author" {
        return str(ev["lines"]) + " IR lines";
    } elif s == "assemble" {
        return "clean" if not ev["issues"] else (str(ev["issues"]) + " gate issues");
    } elif s == "gates" {
        return ("compile ✓" if ev["g4"] else "compile ✗") + ((" · " + str(ev["repairs"]) + " IR repairs") if ev["repairs"] else "");
    } elif s == "autofix" {
        n_fx = int(ev.get("fixes", 0));
        return (str(n_fx) + " fix(es) applied") if n_fx else "nothing to fix";
    } elif s == "bind" {
        # the SkillRT-inspired mechanical passes: G7 env binding + G8 concurrency
        g7 = int(ev.get("g7_issues", 0));
        g8 = int(ev.get("g8_issues", 0));
        po = int(ev.get("par_opps", 0));
        parts: list = ["env ✓" if not g7 else ("env: " + str(g7) + " unbound")];
        if g8 { parts.append("par: " + str(g8) + " false-parallel"); }
        if po { parts.append(str(po) + " par opportunities"); }
        return " · ".join(parts);
    }
    return "";
}

def compile_stage_secs(ev: dict) -> str {
    secs = float(ev.get("secs", 0.0));
    return (str(int(secs // 60)) + "m " + str(int(secs % 60)) + "s") if secs >= 60.0 else (("%.1f" % secs) + "s");
}


# ---------------------------------------------------------------------------
# The two seams where the compiler plugs in.
#
# `agent.jac` and the tool-belt call `solve_task` and `sigil_compile` without
# knowing whether this build has a compiler. The full Sigil registers itself on
# import; an ejected runtime never does, and gets honest answers instead of
# import errors. This is what lets one set of capability modules serve both.
# ---------------------------------------------------------------------------
glob _SOLVER: any = None;     # the compiling router, when one exists
glob _COMPILER: any = None;   # compile_skill, when one exists

def set_solver(fn: any) -> None {
    _SOLVER = fn;
    return None;
}

def set_compiler(fn: any) -> None {
    _COMPILER = fn;
    return None;
}

def compiler_available() -> bool {
    return _COMPILER is not None;
}

def compile_via_seam(source: str, eject: bool, eject_path: str, on_event: any) -> dict {
    # The tool-belt's compile, routed through the seam. Callers check
    # `compiler_available()` first; this is the guard for anyone who did not.
    if _COMPILER is None {
        return {"ok": False, "signature": "", "issues": ["no compiler in this build"],
                "compile_errors": "", "result": ""};
    }
    return dict(_COMPILER(source, eject, eject_path, on_event, False));
}

def solve_task(task: str, skill: str = "") -> dict {
    # With a compiler: route, and compile / mutate / relearn on a miss or a bad
    # grade. Without one: route to a shipped skill, and say so on a miss.
    if _SOLVER is not None {
        return dict(_SOLVER(task, skill));
    }
    return solve_known_task(task, skill);
}
