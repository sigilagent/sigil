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

Return ONLY the AG-IR text (starting with the '---' frontmatter), no commentary.

===== AG-IR CONTRACT =====
{contract}""";
def author_agir(intent: str, task: str, contract: str) -> str by frontier();

sem revise_agir = """Revise the PRIOR AG-IR so the compiled agent ALSO handles the new
TASK it failed or under-covered, given the FAILURE signal. Preserve everything that
works; extend types/tools/operations minimally and surgically. Keep the same top-level
name/signature. Return ONLY the full revised AG-IR text.

===== AG-IR CONTRACT =====
{contract}""";
def revise_agir(prior_agir: str, task: str, failure: str, contract: str) -> str by frontier();

# ---------------------------------------------------------------------------
# The persistent agent graph.
#   root --Anchored--> Registry --Crystallized--> TaskGraph --Ran--> Attempt
#                                        TaskGraph(new) --MutatedFrom--> TaskGraph(old)
# ---------------------------------------------------------------------------
edge Anchored {}       # root -> Registry  (the agent, hung off the persistent root)
edge Crystallized {}   # Registry -> TaskGraph
edge Ran {}            # TaskGraph -> Attempt
edge MutatedFrom {}    # TaskGraph(new) -> TaskGraph(old)  (evolution lineage)

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

def crystallize(reg: Registry, intent: str, task: str) -> TaskGraph {
    # Frontier builds an AG-IR for the task CLASS, compiler lowers it, we persist it.
    sig = name_signature(task);
    agir = author_agir(intent, task, CONTRACT);
    osp = transpile_ir(agir, sig);
    path = write_module(osp, sig, 1, WORKDIR);
    tg = TaskGraph(signature=sig, intent=intent, agir=agir, module=path,
                   version=1, origin="frontier");
    reg +>:Crystallized:+> tg;
    return tg;
}

def mutate(reg: Registry, tg: TaskGraph, task: str, failure: str) -> TaskGraph {
    # Frontier revises an existing procedure into a new version node (lineage kept).
    new_agir = revise_agir(tg.agir, task, failure, CONTRACT);
    v = tg.version + 1;
    osp = transpile_ir(new_agir, tg.signature);
    path = write_module(osp, tg.signature, v, WORKDIR);
    nt = TaskGraph(signature=tg.signature, intent=tg.intent, agir=new_agir,
                   module=path, version=v, origin="mutation");
    reg +>:Crystallized:+> nt;
    nt +>:MutatedFrom:+> tg;
    return nt;
}

def run_crystal(tg: TaskGraph, task: str, skill: str) -> dict {
    # Small model executes the crystallized OSP; record the attempt + stats on the graph.
    res = execute_module(tg.module, task, SMALL_NAME, skill, WORKDIR);
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
        reg = [-->][?:Registry];
        if not reg {
            r = Registry();
            here +>:Anchored:+> r;
            visit r;
        } else {
            visit reg[0];
        }
    }

    can route with Registry entry {
        crystals: list[TaskGraph] = latest_by_sig([-->][?:TaskGraph]);
        known = [c.signature for c in crystals];
        verdict = classify(self.task, known) if known else "NONE";
        self.trace += "route -> " + verdict + "\n";

        tg: TaskGraph = select_target(here, crystals, verdict, self.task);
        self.trace += route_note(verdict, tg);
        self.signature = tg.signature;
        res = run_crystal(tg, self.task, self.skill);

        # Escalation safety-valve: if the cheap model fails on a crystallized
        # procedure, the frontier mutates it once and we retry.
        if not res["ok"] {
            self.trace += "small-model FAIL -> frontier mutate + retry\n";
            tg = mutate(here, tg, self.task, str(res["error"]));
            res = run_crystal(tg, self.task, self.skill);
            self.signature = tg.signature;
        }

        self.result = str(res["report"]);
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
