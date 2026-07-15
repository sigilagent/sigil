"""Sigil — a self-evolving agent that IS an object-spatial graph.

    frontier model  --crystallize-->  AG-IR  --compile-->  OSP  --persist-->  a node
    small model     --execute-->      the crystallized node's OSP
    frontier model  --mutate-->       a new version node (lineage on the graph)

The agent's *memory* and its *capability* are the same graph. A task routes
through it: a HIT re-runs a crystallized procedure on a cheap model; a MISS
crystallizes a new one with the frontier model; a partial match MUTATES an
existing procedure into a new version. What persists is the *procedure* — the
typed AG-IR + its lowered OSP + run statistics — not the run artifacts.
"""

import os;
import json;
import from .sigil_mcp { digest, tools_for }
import from jaclang.byllm.lib { Model, ModelPool }
import from .compiler.compiler { transpile_ir }
import from .sigil_runtime {
    write_module, execute_module, default_contract, repo_root, agir_name, install_osp
}
import from .sigil_cron { now_ms }
import from .views { VNode, VEdge, VGraph, VCall, VObs }

# ---------------------------------------------------------------------------
# The two-tier cascade. Frontier crystallizes (expensive, rare); small executes
# (cheap, hot); router classifies (cheap). Names are env-overridable so the same
# graph runs against gpt-5 + qwen3 locally or any pair.
# ---------------------------------------------------------------------------
glob FRONTIER_NAME: str = os.getenv("SIGIL_FRONTIER", "gpt-5");
glob SMALL_NAME: str    = os.getenv("SIGIL_SMALL", "ollama_chat/qwen3:32b");
glob ROUTER_NAME: str   = os.getenv("SIGIL_ROUTER", os.getenv("SIGIL_SMALL", "ollama_chat/qwen3:32b"));

# A tier holds a single Model, or a ModelPool (fallback chain) once configured.
glob frontier: any = Model(model_name=FRONTIER_NAME);
glob small: any    = Model(model_name=SMALL_NAME);
glob router: any   = Model(model_name=ROUTER_NAME);

glob WORKDIR: str  = repo_root();
glob CONTRACT: str = default_contract();
glob ETHOS: str    = "";   # the soul's operating principles, rebound from the graph at awaken()
glob PROMPT_MODE: str = "full";  # full | minimal | none — how much context wraps the crystallizer/run

# ---------------------------------------------------------------------------
# Cognition — the ONLY model calls in the system. Everything else is graph
# mechanics + deterministic compile/run.
# ---------------------------------------------------------------------------
sem classify = """Route a TASK against the agent's KNOWN crystallized task-type
signatures. Return EXACTLY one of:
  - a signature from KNOWN, if the crystallized procedure already covers this task;
  - 'MUTATE:<signature>' if a known type is close but must be extended to fit;
  - 'NONE' if no known type fits and a new procedure must be crystallized.
Judge by the *class* of task, not surface wording.""";
def classify(task: str, known: list[str]) -> str by router();

sem name_signature = """Coin a short, stable, kebab-case signature naming the CLASS
of task (never this one instance): e.g. 'pdf-extract', 'slack-digest',
'invoice-parse', 'csv-to-chart'. Two tasks of the same kind must get the same name.""";
def name_signature(task: str) -> str by router();

sem author_agir = """You are the frontier crystallizer. Emit a COMPLETE AG-IR (the
YAML-with-frontmatter contract below) that a compiler lowers to a runnable OSP agent
covering the whole CLASS of task the INTENT names — not merely this instance.

Maximize mechanizable structure so a WEAK model can execute it faithfully: prefer
typed slots over free prose, embodied/runnable tool bodies over prose pointers, and
ordered operation pipelines over ad-hoc dispatch. Every tool must carry a runnable
command or an explicit snippet; never leave a step as a bare description.

Honor the agent's ETHOS (its operating principles) in how you shape the procedure.

If REGISTERED TOOLS are listed, bind the relevant ones as live-integration tools
(embodiment rung-0) by their EXACT name — the runtime dispatches those names to the
user's MCP servers. Do not script a tool the user has already provided.

You are given the agent's ETHOS (operating principles to honor), any REGISTERED TOOLS
(bind the relevant ones by their EXACT name — the runtime dispatches those names to the
user's MCP servers; do not script a tool the user already provides), and the AG-IR
CONTRACT (the exact schema to conform to).

CRITICAL: the output MUST be VALID YAML. Put every code snippet, command, or multi-line
body in a YAML block scalar (`field: |` then indented lines) or a quoted string — NEVER
emit a raw `::py::` block, and never leave an unescaped `:` inside an unquoted value.
Prefer an embodied `command:` (a runnable shell command) over inline code.

Return ONLY the AG-IR text (starting with the '---' frontmatter), no commentary.""";
def author_agir(intent: str, task: str, ethos: str, tools: str, contract: str) -> str by frontier();

sem fix_agir = """The PRIOR AG-IR failed to compile with the given ERROR. Return a CORRECTED
AG-IR that is VALID YAML and conforms to the CONTRACT — fix only what the error indicates
(commonly: a code body that must become a `field: |` block scalar or a quoted string, an
unescaped colon, or a bad indent). Return ONLY the AG-IR text.""";
def fix_agir(prior_agir: str, error: str, contract: str) -> str by frontier();

sem revise_agir = """Revise the PRIOR AG-IR so the compiled agent ALSO handles the new
TASK it failed or under-covered, given the FAILURE signal. Preserve everything that
works; extend types/tools/operations minimally and surgically. Keep the same top-level
name/signature. Honor the given ETHOS and conform to the given AG-IR CONTRACT. Return
ONLY the full revised AG-IR text.""";
def revise_agir(prior_agir: str, task: str, failure: str, ethos: str, contract: str) -> str by frontier();

# ---------------------------------------------------------------------------
# The persistent agent graph. There are NO config files and NO markdown — the
# agent's identity, its knowledge, its skills and its memory are all nodes.
#
#   root --Embodies--> Soul --Knows----> Spec        (the AG-IR contract, on the graph)
#    |                  |   \--Remembers-> Memory     (semantic layer — durable facts)
#    |                  \--Owns---------> Registry
#   root --Anchored--> Registry --Crystallized--> TaskGraph   (procedural layer — skills)
#                                        TaskGraph --Ran------> Attempt   (episodic layer)
#                                        TaskGraph --MutatedFrom--> TaskGraph  (lineage)
# ---------------------------------------------------------------------------
edge Embodies {}       # root -> Soul       (the agent's identity/config, on the graph)
edge Knows {}          # Soul -> Spec       (the crystallizer's contract, on the graph)
edge Provides {}       # Soul -> McpServer  (registered external tool servers)
edge Remembers {}      # Soul -> Memory     (semantic memory)
edge Owns {}           # Soul -> Registry
edge Anchored {}       # root -> Registry   (the skill library, hung off the persistent root)
edge Crystallized {}   # Registry -> TaskGraph
edge Ran {}            # TaskGraph -> Attempt
edge MutatedFrom {}    # TaskGraph(new) -> TaskGraph(old)  (evolution lineage)

# --- Identity / config (OpenClaw's SOUL, but a node — not a SOUL.md) --------
node Soul {
    has name: str = "sigil";
    has persona: str = "";        # voice / character
    has ethos: list[str] = [];    # operating principles, woven into crystallization
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
    has workspace: str = "";           # sandboxed workspace dir the file tools are jailed to (default ~/.sigil/workspace)
    has sandbox_mode: str = "jail";    # how ws_exec is contained: jail (cwd-confined subprocess) | docker | off
}

node Spec {
    has kind: str = "agir-contract";
    has body: str = "";           # the crystallizer's contract text, seeded onto the graph
}

# --- External MCP servers the user registers (BYO tools), config on the graph
node McpServer {
    has name: str;
    has transport: str = "stdio"; # stdio | http | sse | streamable-http
    has command: str = "";        # stdio: executable
    has args: list[str] = [];
    has url: str = "";            # http/sse: endpoint
    has enabled: bool = True;
}

# --- Semantic memory: durable facts the agent carries across tasks ----------
node Memory {
    has content: str;
    has kind: str = "fact";       # fact | preference | observation
    has salience: float = 1.0;
    has uses: int = 0;
    has embedding: list = [];      # cached embedding vector (populated lazily in vector recall mode)
}

node Registry {
    has name: str = "sigil";
}

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
def latest_by_sig(crystals: list[TaskGraph]) -> list[TaskGraph] {
    # Keep only the highest-version TaskGraph per signature.
    best: dict = {};
    for c in crystals {
        cur = best.get(c.signature);
        if (cur is None) or (c.version > cur.version) { best[c.signature] = c; }
    }
    out: list[TaskGraph] = [];
    for c in crystals {
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
    return Model(model_name=name);
}

def _resolve_alias(soul: Soul, name: str) -> str {
    return str(soul.model_aliases.get(name, name));
}

def _bind_tier(soul: Soul, tier: str, tier_model: str) -> any {
    # Resolve the tier's model (through any alias) and, if the tier has a fallback
    # chain configured, return a byLLM ModelPool that fails over primary -> fallbacks.
    primary = _resolve_alias(soul, tier_model);
    fb = str(soul.model_fallbacks.get(tier, "")).strip();
    if not fb { return Model(model_name=primary); }
    models: list = [Model(model_name=primary)];
    for m in fb.split(",") {
        mm = _resolve_alias(soul, m.strip());
        if mm { models.append(Model(model_name=mm)); }
    }
    return ModelPool(models=models, strategy="fallback");
}

def bind_chat_model() -> any {
    # The model that powers chat-mode + sub-agents. Chat is the user-facing surface and
    # has no crystallized procedure to lean on, so it wants the STRONG model: the `chat`
    # tier falls back to `frontier` (not `small` — the small tier is for executing
    # already-crystallized skills). Rebound from the graph so `configure chat_model` takes
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
    return {
        "frontier": soul.frontier_model, "small": soul.small_model,
        "router": (soul.router_model if soul.router_model else soul.small_model),
        "aliases": dict(soul.model_aliases), "fallbacks": dict(soul.model_fallbacks)
    };
}

def awaken() -> Soul {
    global frontier, small, router, SMALL_NAME, CONTRACT, ETHOS, PROMPT_MODE;
    found = [root -->[?:Soul]];
    if found {
        soul = found[0];
    } else {
        soul = Soul(
            name="sigil",
            persona="A pragmatic operator that crystallizes tasks into reliable, minimal procedures and runs them cheaply.",
            ethos=[
                "Prefer mechanized structure over prose.",
                "Never leave a step unembodied.",
                "Ground verification in the real artifact, not a proxy.",
                "Reuse a crystallized procedure before authoring a new one."
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
    SMALL_NAME = soul.small_model;
    router = _bind_tier(soul, "router", soul.router_model if soul.router_model else soul.small_model);
    ETHOS = "\n".join(["- " + e for e in soul.ethos]);
    router = model_for(soul.router_model if soul.router_model else soul.small_model);
    PROMPT_MODE = soul.prompt_mode if soul.prompt_mode else "full";
    # ethos is woven into crystallization only in full mode; minimal/none keep the
    # crystallizer to the structural contract (contract is always required for valid AG-IR).
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

# The self-evolving hook: distill durable facts from a completed task.
sem distill = """From a completed TASK and its RESULT, extract 0-3 DURABLE facts worth
remembering for future tasks (stable preferences, environment facts, conventions the
user relies on). Skip anything one-off or already obvious. Return a JSON list of short
strings; return [] if nothing is worth keeping.""";
def distill(task: str, result: str) -> list[str] by router();

# Grounded verification — the quality gate the bare ok/success counter cannot give.
# A crystallized run can EXIT ok yet be WRONG (empty, echoed input, off-task). The
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

def _persist(reg: Registry, sig: str, intent: str, agir: str, module: str, origin: str, version: int) -> TaskGraph {
    tg = TaskGraph(signature=sig, intent=intent, agir=agir, module=module,
                   version=version, origin=origin);
    reg +>:Crystallized:+> tg;
    return tg;
}

def _lower(agir: str, sig: str) -> dict {
    # Compile the AG-IR; on a compile/parse failure, let the frontier REPAIR it and
    # retry (self-healing crystallization). Returns {ok, osp, agir}.
    cur = agir;
    err = "";
    for i in range(3) {
        try {
            osp = transpile_ir(cur, sig);
            if "def run(" in osp { return {"ok": True, "osp": osp, "agir": cur}; }
            err = "compiled module has no run() entrypoint";
        } except Exception as e { err = str(e)[:400]; }
        cur = fix_agir(cur, err, CONTRACT);
    }
    return {"ok": False, "osp": "", "agir": cur, "error": err};
}

def _crystallize_fresh(reg: Registry, sig: str, intent: str, task: str, version: int, origin: str) -> TaskGraph {
    # Author a FRESH AG-IR with the frontier for a KNOWN signature/version — the reusable
    # core behind first crystallization AND relearn (which discards a degraded procedure
    # and re-authors from scratch, rather than revising it like mutate does).
    tools = digest(mcp_servers());
    agir = author_agir(intent, task, ETHOS, tools, CONTRACT);
    low = _lower(agir, sig);
    if not low["ok"] {
        # Don't persist an empty module: it would later "run" as a no-op and surface
        # as a confusing small-model failure. Fail loudly with the real compile error.
        raise RuntimeError("crystallize '" + sig + "': AG-IR did not compile to a runnable procedure: " + str(low.get("error", "unknown")));
    }
    path = write_module(str(low["osp"]), sig, version, WORKDIR);
    return _persist(reg, sig, intent, str(low["agir"]), path, origin, version);
}

def crystallize(reg: Registry, intent: str, task: str) -> TaskGraph {
    # Frontier builds an AG-IR for the task CLASS (binding any registered MCP tools),
    # compiler lowers it (repairing on failure), we persist it as v1.
    sig = name_signature(task);
    return _crystallize_fresh(reg, sig, intent, task, 1, "frontier");
}

def mutate(reg: Registry, tg: TaskGraph, task: str, failure: str) -> TaskGraph {
    # Frontier revises an existing procedure into a new version node (lineage kept).
    new_agir = revise_agir(tg.agir, task, failure, ETHOS, CONTRACT);
    v = tg.version + 1;
    low = _lower(new_agir, tg.signature);
    if not low["ok"] {
        # Keep the prior working version rather than persisting an empty mutation.
        raise RuntimeError("mutate '" + tg.signature + "' v" + str(v) + ": revised AG-IR did not compile: " + str(low.get("error", "unknown")));
    }
    path = write_module(str(low["osp"]), tg.signature, v, WORKDIR);
    nt = _persist(reg, tg.signature, tg.intent, str(low["agir"]), path, "mutation", v);
    nt +>:MutatedFrom:+> tg;
    return nt;
}

# ---------------------------------------------------------------------------
# BYO MCP servers — registered on the graph (config), exposed to crystallized
# agents via byLLM's native McpClient. Adding one takes effect on the next run.
# ---------------------------------------------------------------------------
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
sem lift_skill = """Lift this SKILL.md (or prose skill description) into a COMPLETE AG-IR:
a typed graph a compiler lowers to a runnable OSP agent covering the skill's whole task
CLASS. Maximize mechanizable structure; bind any given REGISTERED TOOLS by exact name;
honor the given ETHOS and conform to the given AG-IR CONTRACT. Return ONLY the AG-IR text.""";
def lift_skill(skill_md: str, ethos: str, tools: str, contract: str) -> str by frontier();

def register_skill(source: str, kind: str) -> dict {
    soul = awaken();
    reg = [soul -->[?:Registry]][0];
    if kind == "agir" {
        # source is raw AG-IR text — compile only, no model call.
        sig = agir_name(source);
        osp = transpile_ir(source, sig);
        path = write_module(osp, sig, 1, WORKDIR);
        tg = _persist(reg, sig, "registered AG-IR", source, path, "registered-agir", 1);
    } elif kind == "osp" {
        # source is a path to a precompiled OSP .jac module — drop it in.
        sig = agir_name(source);
        path = install_osp(source, sig, WORKDIR);
        tg = _persist(reg, sig, "registered OSP module", "", path, "registered-osp", 1);
    } else {
        # source is SKILL.md text — frontier lifts it to an AG-IR, then compile.
        agir = lift_skill(source, ETHOS, digest(mcp_servers()), CONTRACT);
        sig = agir_name(agir);
        osp = transpile_ir(agir, sig);
        path = write_module(osp, sig, 1, WORKDIR);
        tg = _persist(reg, sig, "lifted from SKILL.md", agir, path, "lifted-skill", 1);
    }
    return {"signature": tg.signature, "version": tg.version, "origin": tg.origin, "module": tg.module};
}

def run_crystal(tg: TaskGraph, task: str, context: str, skill: str) -> dict {
    # Small model executes the crystallized OSP. The crystallized PROCEDURE is
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

def select_target(reg: Registry, crystals: list[TaskGraph], verdict: str, task: str) -> TaskGraph {
    # HIT -> existing procedure; PARTIAL -> mutate it; MISS -> crystallize a new one.
    if (verdict == "NONE") or (not crystals) {
        return crystallize(reg, task, task);
    }
    if verdict.startswith("MUTATE:") {
        sig = verdict.split(":", 1)[1].strip();
        for c in crystals { if c.signature == sig {
            return mutate(reg, c, task, "router flagged partial coverage");
        } }
        return crystallize(reg, task, task);
    }
    for c in crystals { if c.signature == verdict { return c; } }
    return crystallize(reg, task, task);
}

def route_note(verdict: str, tg: TaskGraph) -> str {
    if verdict == "NONE" { return "MISS -> crystallized " + tg.signature + " (frontier)\n"; }
    if verdict.startswith("MUTATE:") { return "PARTIAL -> mutated " + tg.signature + " v" + str(tg.version) + " (frontier)\n"; }
    return "HIT " + tg.signature + " -> run on small model\n";
}

# ---------------------------------------------------------------------------
# The one entry walker. Route -> (hit: run | miss: crystallize+run | partial:
# mutate+run), then escalate on a small-model failure (frontier mutate + retry).
# ---------------------------------------------------------------------------
walker solve {
    has task: str;
    has skill: str = "";
    has result: str = "";
    has trace: str = "";
    has signature: str = "";

    can enter with Root entry {
        soul = awaken();                       # identity + config + contract, all on the graph
        reg = [-->][?:Registry][0];

        # --- semantic memory: recall durable facts relevant to this task ----
        # prompt_mode gates run-time context: none = bare task (no memory injected).
        ctx = "";
        if PROMPT_MODE != "none" {
            mems = recall(soul, self.task, 5);
            ctx = memory_context(mems);
            if mems { self.trace += "recall -> " + str(len(mems)) + " memory\n"; }
        }
        self.trace += "prompt-mode: " + PROMPT_MODE + "\n";

        # --- route through the procedural library ---------------------------
        crystals: list[TaskGraph] = latest_by_sig([reg -->][?:TaskGraph]);
        known = [c.signature for c in crystals];
        verdict = classify(self.task, known) if known else "NONE";
        self.trace += "route -> " + verdict + "\n";

        tg: TaskGraph = select_target(reg, crystals, verdict, self.task);
        self.trace += route_note(verdict, tg);
        self.signature = tg.signature;
        res = run_crystal(tg, self.task, ctx, self.skill);

        # --- escalation valve: cheap model fails -> frontier mutate + retry --
        if not res["ok"] {
            self.trace += "small-model FAIL -> frontier mutate + retry\n";
            tg = mutate(reg, tg, self.task, str(res["error"]));
            res = run_crystal(tg, self.task, ctx, self.skill);
            self.signature = tg.signature;
        }

        # --- grounded-eval valve: a run can EXIT ok yet be WRONG (empty / echoed /
        # off-task). Judge the artifact; if it fails and auto_eval is on, RELEARN the
        # procedure from scratch (frontier) and retry once. This is the automatic
        # relearn trigger — the quality gate the bare ok/success counter cannot give.
        if res["ok"] and soul.auto_eval {
            try {
                ev = judge_result(self.task, str(res["report"]));
                tg.last_score = ev.score;
                tg.last_eval = ev.reason;
                self.trace += "eval -> " + str(ev.score) + "/100 (" + ev.reason + ")\n";
                if ev.score < soul.eval_threshold {
                    self.trace += "eval FAIL -> relearn (frontier) + retry\n";
                    prev = tg;
                    tg = _crystallize_fresh(reg, prev.signature, prev.intent, self.task, prev.version + 1, "relearn");
                    tg +>:MutatedFrom:+> prev;
                    self.signature = tg.signature;
                    res = run_crystal(tg, self.task, ctx, self.skill);
                }
            } except Exception as e {
                self.trace += "eval skipped (" + str(e)[:80] + ")\n";
            }
        }

        self.result = str(res["report"]);

        # --- self-evolution: learn durable facts from the completed task ----
        # Best-effort: a failure in the (optional) learn step must never discard a
        # completed task's result. Distillation is enrichment, not part of the task.
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

# ---------------------------------------------------------------------------
# Programmatic entrypoints.
# ---------------------------------------------------------------------------
def solve_task(task: str, skill: str = "") -> dict {
    w = root spawn solve(task=task, skill=skill);
    return {"signature": w.signature, "result": w.result, "trace": w.trace};
}

def library() -> list {
    # The agent's crystallized capability, latest version per signature.
    reg = [root -->][?:Registry];
    if not reg { return []; }
    out = [];
    for tg in latest_by_sig([reg[0] -->][?:TaskGraph]) {
        out.append({
            "signature": tg.signature, "version": tg.version, "origin": tg.origin,
            "runs": tg.runs, "successes": tg.successes, "module": tg.module
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
        "frontier_model": soul.frontier_model, "small_model": soul.small_model,
        "router_model": (soul.router_model if soul.router_model else soul.small_model),
        "chat_model": (soul.chat_model if soul.chat_model else soul.frontier_model),
        "workspace": (soul.workspace if soul.workspace else "~/.sigil/workspace"),
        "sandbox_mode": (soul.sandbox_mode if soul.sandbox_mode else "jail"),
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
    elif key == "sandbox_mode" {
        if value not in ["jail", "docker", "off"] { return "sandbox_mode must be one of: jail | docker | off"; }
        soul.sandbox_mode = value;
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
    # expand the Soul policy into env the run subprocess + crystallizer binding both read
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

def eval_skill(signature: str, probe: str = "") -> dict {
    # Grounded verification: run the current skill on a probe task (defaults to the
    # skill's own intent) and score whether the output truly accomplishes it.
    awaken();
    reg = [root -->][?:Registry][0];
    tg = _find_skill(reg, signature);
    if tg is None { return {"ok": False, "error": "no such skill: " + signature}; }
    task = probe if probe else tg.intent;
    res = run_crystal(tg, task, "", "");
    ev = judge_result(task, str(res["report"]));
    tg.last_score = ev.score;
    tg.last_eval = ev.reason;
    return {
        "ok": True, "signature": signature, "version": tg.version,
        "score": ev.score, "passed": ev.passed, "reason": ev.reason,
        "result": str(res["report"])[:400]
    };
}

def relearn(signature: str, hint: str = "") -> dict {
    # Discard the current (degraded) procedure and re-crystallize it FROM SCRATCH with
    # the frontier — same signature, bumped version, lineage kept. Manual counterpart
    # to the solve loop's automatic eval-triggered relearn.
    awaken();
    reg = [root -->][?:Registry][0];
    tg = _find_skill(reg, signature);
    if tg is None { return {"ok": False, "error": "no such skill: " + signature}; }
    intent = (tg.intent + "\nExtra guidance: " + hint) if hint else tg.intent;
    nt = _crystallize_fresh(reg, signature, intent, tg.intent, tg.version + 1, "relearn");
    nt +>:MutatedFrom:+> tg;
    return {"ok": True, "signature": signature, "version": nt.version, "origin": "relearn", "module": nt.module};
}

def forget(signature: str) -> dict {
    # Remove a crystallized skill entirely — every version, its attempts, and the
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
            g.edges.append(VEdge(src="registry", kind="crystallized", dst=tid));
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
walker:pub api_solve {
    has task: str;
    has skill: str = "";
    can run with Root entry { report solve_task(self.task, self.skill); }
}

walker:pub api_add_mcp {
    has name: str;
    has target: str;
    has transport: str = "stdio";
    has args: list[str] = [];
    can run with Root entry { report add_mcp(self.name, self.transport, self.target, self.args); }
}

walker:pub api_register_skill {
    has source: str;          # SKILL.md text / AG-IR text / OSP module path
    has kind: str = "md";     # md | agir | osp
    can run with Root entry { report register_skill(self.source, self.kind); }
}

walker:pub api_teach {
    has fact: str;
    has kind: str = "fact";
    can run with Root entry { report teach(self.fact, self.kind); }
}

walker:pub api_soul {
    can run with Root entry { report describe_soul(); }
}

walker:pub api_configure {
    has key: str;
    has value: str;
    can run with Root entry { report configure(self.key, self.value); }
}

walker:pub api_recall {
    has query: str;
    has k: int = 8;
    can run with Root entry { report recollect(self.query, self.k); }
}

walker:pub api_library {
    can run with Root entry { report library(); }
}

walker:pub api_eval {
    has signature: str;
    has probe: str = "";
    can run with Root entry { report eval_skill(self.signature, self.probe); }
}

walker:pub api_relearn {
    has signature: str;
    has hint: str = "";
    can run with Root entry { report relearn(self.signature, self.hint); }
}

walker:pub api_forget {
    has signature: str;
    can run with Root entry { report forget(self.signature); }
}

walker:pub api_mcp {
    can run with Root entry { report mcp_status(); }
}

walker:pub api_graph {
    can run with Root entry { report graph_snapshot(); }
}

walker:pub api_observability {
    has n: int = 120;
    can run with Root entry { report observability_tail(self.n); }
}
