"""Prometheus — a self-evolving agent that IS an object-spatial graph.

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
import from byllm.lib { Model }
import from compiler.compiler { transpile_ir }
import from prom_runtime {
    write_module, execute_module, default_contract, repo_root
}

# ---------------------------------------------------------------------------
# The two-tier cascade. Frontier crystallizes (expensive, rare); small executes
# (cheap, hot); router classifies (cheap). Names are env-overridable so the same
# graph runs against gpt-5 + qwen3 locally or any pair.
# ---------------------------------------------------------------------------
glob FRONTIER_NAME: str = os.getenv("PROM_FRONTIER", "gpt-5");
glob SMALL_NAME: str    = os.getenv("PROM_SMALL", "ollama_chat/qwen3:32b");
glob ROUTER_NAME: str   = os.getenv("PROM_ROUTER", os.getenv("PROM_SMALL", "ollama_chat/qwen3:32b"));

glob frontier: Model = Model(model_name=FRONTIER_NAME);
glob small: Model    = Model(model_name=SMALL_NAME);
glob router: Model   = Model(model_name=ROUTER_NAME);

glob WORKDIR: str  = repo_root();
glob CONTRACT: str = default_contract();
glob ETHOS: str    = "";   # the soul's operating principles, rebound from the graph at awaken()

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

Return ONLY the AG-IR text (starting with the '---' frontmatter), no commentary.

===== ETHOS =====
{ethos}
===== AG-IR CONTRACT =====
{contract}""";
def author_agir(intent: str, task: str, ethos: str, contract: str) -> str by frontier();

sem revise_agir = """Revise the PRIOR AG-IR so the compiled agent ALSO handles the new
TASK it failed or under-covered, given the FAILURE signal. Preserve everything that
works; extend types/tools/operations minimally and surgically. Keep the same top-level
name/signature. Return ONLY the full revised AG-IR text.

===== ETHOS =====
{ethos}
===== AG-IR CONTRACT =====
{contract}""";
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
edge Remembers {}      # Soul -> Memory     (semantic memory)
edge Owns {}           # Soul -> Registry
edge Anchored {}       # root -> Registry   (the skill library, hung off the persistent root)
edge Crystallized {}   # Registry -> TaskGraph
edge Ran {}            # TaskGraph -> Attempt
edge MutatedFrom {}    # TaskGraph(new) -> TaskGraph(old)  (evolution lineage)

# --- Identity / config (OpenClaw's SOUL, but a node — not a SOUL.md) --------
node Soul {
    has name: str = "prometheus";
    has persona: str = "";        # voice / character
    has ethos: list[str] = [];    # operating principles, woven into crystallization
    has frontier_model: str = ""; # cognition config — lives on the graph, not env
    has small_model: str = "";
    has router_model: str = "";
    has channels: list[str] = []; # where the agent is reachable (pure config, on the graph)
}

node Spec {
    has kind: str = "agir-contract";
    has body: str = "";           # the crystallizer's contract text, seeded onto the graph
}

# --- Semantic memory: durable facts the agent carries across tasks ----------
node Memory {
    has content: str;
    has kind: str = "fact";       # fact | preference | observation
    has salience: float = 1.0;
    has uses: int = 0;
}

node Registry {
    has name: str = "prometheus";
}

node TaskGraph {
    has signature: str;
    has intent: str;
    has agir: str;         # the frontier-authored AG-IR (the contract)
    has module: str;       # path to the lowered OSP on disk
    has version: int = 1;
    has origin: str = "frontier";   # 'frontier' | 'mutation'
    has runs: int = 0;
    has successes: int = 0;
}

node Attempt {
    has task: str;
    has ok: bool;
    has model: str;
    has summary: str = "";
}

# ---------------------------------------------------------------------------
# Graph operations (deterministic — no model calls except the byLLM defs above).
# ---------------------------------------------------------------------------
def latest_by_sig(crystals: list) -> list {
    # Keep only the highest-version TaskGraph per signature.
    best: dict = {};
    for c in crystals {
        cur = best.get(c.signature);
        if (cur is None) or (c.version > cur.version) { best[c.signature] = c; }
    }
    return list(best.values());
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

def awaken() -> Soul {
    global frontier, small, router, SMALL_NAME, CONTRACT, ETHOS;
    found = [root -->[?:Soul]];
    if found {
        soul = found[0];
    } else {
        soul = Soul(
            name="prometheus",
            persona="A pragmatic operator that crystallizes tasks into reliable, minimal procedures and runs them cheaply.",
            ethos=[
                "Prefer mechanized structure over prose.",
                "Never leave a step unembodied.",
                "Ground verification in the real artifact, not a proxy.",
                "Reuse a crystallized procedure before authoring a new one."
            ],
            frontier_model=os.getenv("PROM_FRONTIER", "gpt-5"),
            small_model=os.getenv("PROM_SMALL", "ollama_chat/qwen3:32b"),
            router_model=os.getenv("PROM_ROUTER", ""),
            channels=["cli"]
        );
        root +>:Embodies:+> soul;
        reg = Registry();
        root +>:Anchored:+> reg;
        soul +>:Owns:+> reg;
        soul +>:Knows:+> Spec(kind="agir-contract", body=default_contract());
    }
    # rebind cognition from the graph
    frontier = model_for(soul.frontier_model);
    small = model_for(soul.small_model);
    SMALL_NAME = soul.small_model;
    router = model_for(soul.router_model if soul.router_model else soul.small_model);
    ETHOS = "\n".join(["- " + e for e in soul.ethos]);
    specs = [soul -->[?:Spec]];
    if specs { CONTRACT = specs[0].body; }
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

def recall(soul: Soul, query: str, k: int) -> list[Memory] {
    q = _tokens(query);
    # tuple = (-score, seq, memory); seq is a strict tie-breaker so nodes never compare
    scored: list = [];
    seq = 0;
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

def crystallize(reg: Registry, intent: str, task: str) -> TaskGraph {
    # Frontier builds an AG-IR for the task CLASS, compiler lowers it, we persist it.
    sig = name_signature(task);
    agir = author_agir(intent, task, ETHOS, CONTRACT);
    osp = transpile_ir(agir, sig);
    path = write_module(osp, sig, 1, WORKDIR);
    tg = TaskGraph(signature=sig, intent=intent, agir=agir, module=path,
                   version=1, origin="frontier");
    reg +>:Crystallized:+> tg;
    return tg;
}

def mutate(reg: Registry, tg: TaskGraph, task: str, failure: str) -> TaskGraph {
    # Frontier revises an existing procedure into a new version node (lineage kept).
    new_agir = revise_agir(tg.agir, task, failure, ETHOS, CONTRACT);
    v = tg.version + 1;
    osp = transpile_ir(new_agir, tg.signature);
    path = write_module(osp, tg.signature, v, WORKDIR);
    nt = TaskGraph(signature=tg.signature, intent=tg.intent, agir=new_agir,
                   module=path, version=v, origin="mutation");
    reg +>:Crystallized:+> nt;
    nt +>:MutatedFrom:+> tg;
    return nt;
}

def run_crystal(tg: TaskGraph, task: str, context: str, skill: str) -> dict {
    # Small model executes the crystallized OSP. The crystallized PROCEDURE is
    # class-general; instance-specific semantic memory is injected here, at run
    # time, as a context preamble on the task — never baked into the procedure.
    run_input = (context + "\nTask: " + task) if context else task;
    res = execute_module(tg.module, run_input, SMALL_NAME, skill, WORKDIR);
    tg.runs += 1;
    if res["ok"] { tg.successes += 1; }
    a = Attempt(task=task, ok=bool(res["ok"]), model=SMALL_NAME, summary=str(res["report"])[:400]);
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

    can enter with `root entry {
        soul = awaken();                       # identity + config + contract, all on the graph
        reg = [-->][?:Registry][0];

        # --- semantic memory: recall durable facts relevant to this task ----
        mems = recall(soul, self.task, 5);
        ctx = memory_context(mems);
        if mems { self.trace += "recall -> " + str(len(mems)) + " memory\n"; }

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

        self.result = str(res["report"]);

        # --- self-evolution: learn durable facts from the completed task ----
        if res["ok"] {
            facts = distill(self.task, self.result);
            for f in facts { remember(soul, f, "fact"); }
            if facts { self.trace += "learned -> " + str(len(facts)) + " memory\n"; }
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
        "channels": soul.channels,
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
    else { return "unknown key: " + key; }
    return key + " = " + value;
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
