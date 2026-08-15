"""Sigil — a skill compiler whose compiled skills, config and memory ARE one object-spatial graph.

    frontier model  --compile-->  AG-IR  --compile-->  OSP  --persist-->  a node
    small model     --execute-->      the compiled node's OSP
    frontier model  --mutate-->       a new version node (lineage on the graph)

The agent's *memory* and its *capability* are the same graph. A task routes
through it: a HIT re-runs a compiled procedure on a cheap model; a MISS
compiles a new one with the frontier model; a partial match MUTATES an
existing procedure into a new version. What persists is the *procedure* — the
typed AG-IR + its lowered OSP + run statistics — not the run artifacts.
"""

import os;
import json;
import from .sigil_mcp { digest, tools_for }
import from .sigil_claude_cc { install as install_claude_cc, is_claude_cc }
import from .compiler.mechanical.compiler { transpile_ir }
import from .compiler.mechanical.toolib { builtin_catalogue }
import from .sigil_runtime {
    write_module, execute_module, default_contract, repo_root, agir_name, install_osp,
    skill_description
}
import from .sigil_api { report_for }
import from .sigil_cron { now_ms }
import from jaclang.byllm.lib { Model, ModelPool }

# The runtime half lives in sigil_core (see its docstring for why). Re-exported
# here so every existing `import from .sigil { ... }` keeps resolving.
import from .sigil_core {
    _find_skill,
    FRONTIER_NAME, SMALL_NAME, ROUTER_NAME, CLAUDE_TIERS,
    cur_frontier, cur_small, cur_router,
    WORKDIR, CONTRACT, ETHOS, PROMPT_MODE, classify,
    Embodies, Knows, Provides, Remembers, Owns, Anchored, Crystallized, Ran, MutatedFrom,
    Soul, Spec, McpServer, Memory, Registry, TaskGraph, Attempt,
    latest_by_sig, model_for, use_claude_code, verbose_mode, claude_mode,
    bind_chat_model, model_alias, model_set_fallback, models_info, awaken,
    remember, recall, memory_context, distill, EvalVerdict, judge_result,
    mcp_servers, mcp_json, add_mcp, remove_mcp, mcp_status, run_compiled,
    library, describe_soul, configure, cfg_set_model, cfg_set_persona, cfg_set_prompt_mode,
    tool_group_set, tool_allowed, tools_policy_info, forget, teach, recollect,
    graph_snapshot, observability_tail, solve_known, solve_known_task,
    solve_task, compile_stage_label, compile_stage_line, compile_stage_secs,
    set_solver, set_compiler, compiler_available
}

sem name_signature = """Coin a short, stable, kebab-case signature naming the CLASS
of task (never this one instance): e.g. 'pdf-extract', 'slack-digest',
'invoice-parse', 'csv-to-chart'. Two tasks of the same kind must get the same name.""";
def name_signature(task: str) -> str by cur_router()();

sem author_agir = """You are the frontier compiler. Emit a COMPLETE AG-IR (the
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
def author_agir(intent: str, task: str, ethos: str, tools: str, contract: str) -> str by cur_frontier()();

sem fix_agir = """The PRIOR AG-IR failed to compile with the given ERROR. Return a CORRECTED
AG-IR that is VALID YAML and conforms to the CONTRACT — fix only what the error indicates
(commonly: a code body that must become a `field: |` block scalar or a quoted string, an
unescaped colon, or a bad indent). Return ONLY the AG-IR text.""";
def fix_agir(prior_agir: str, error: str, contract: str) -> str by cur_frontier()();

sem revise_agir = """Revise the PRIOR AG-IR so the compiled agent ALSO handles the new
TASK it failed or under-covered, given the FAILURE signal. Preserve everything that
works; extend types/tools/operations minimally and surgically. Keep the same top-level
name/signature. Honor the given ETHOS and conform to the given AG-IR CONTRACT. Return
ONLY the full revised AG-IR text.""";
def revise_agir(prior_agir: str, task: str, failure: str, ethos: str, contract: str) -> str by cur_frontier()();

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

def _persist(reg: Registry, sig: str, intent: str, agir: str, module: str, origin: str, version: int,
             skill_src: str = "") -> TaskGraph {
    tg = TaskGraph(signature=sig, intent=intent, agir=agir, module=module,
                   version=version, origin=origin, skill_src=skill_src);
    reg +>:Crystallized:+> tg;
    return tg;
}

def next_version(reg: Registry, sig: str) -> int {
    # Registering a signature that already exists must land ABOVE it. A fresh
    # compile used to persist at a hardcoded v1 under an existing v13 — real on
    # the graph, but latest_by_sig can never route to it, so the recompile the
    # user just paid for stayed invisible while the drifted lineage kept firing.
    top = 0;
    for tg in [reg -->][?:TaskGraph] {
        if (tg.signature == sig) and (tg.version > top) { top = tg.version; }
    }
    return top + 1;
}

def lineage_src(reg: Registry, sig: str) -> str {
    # The ORIGINAL skill document, wherever it survives in the lineage: the
    # newest version of this signature still carrying a non-empty skill_src.
    # Mutations used to drop the source, so once one mutation landed, every
    # later relearn re-authored from a one-line task paraphrase — each
    # generation drifting further from the skill that was actually written.
    best_v = 0;
    src = "";
    for tg in [reg -->][?:TaskGraph] {
        if (tg.signature == sig) and str(tg.skill_src).strip() and (tg.version > best_v) {
            best_v = tg.version;
            src = tg.skill_src;
        }
    }
    return src;
}

def _transpile_error(e: any) -> str {
    # What the repair pass is handed. A bare `TypeError: list indices must be
    # integers or slices, not dict` names no section and no shape, so repair
    # re-authored the same mistake every round and the run died three identical
    # deaths. Carry the exception type and the transpiler frame that raised it, so
    # both the model and a human reading the CLI have somewhere to start.
    import traceback;
    where = "";
    try {
        tb = traceback.extract_tb(e.__traceback__);
        if tb {
            last = tb[-1];
            where = "  [at " + str(last.filename).split("/")[-1] + ":" + str(last.lineno) + " in " + str(last.name) + "]";
        }
    } except Exception as e2 {}
    return (type(e).__name__ + ": " + str(e))[:400] + where;
}

def _lower(agir: str, sig: str) -> dict {
    # Compile the AG-IR; on a compile/parse failure, let the frontier REPAIR it and
    # retry (self-healing compilation). Returns {ok, osp, agir}.
    cur = agir;
    err = "";
    for i in range(3) {
        try {
            osp = transpile_ir(cur, sig);
            if "def run(" in osp { return {"ok": True, "osp": osp, "agir": cur}; }
            err = "compiled module has no run() entrypoint";
        } except Exception as e { err = _transpile_error(e); }
        cur = fix_agir(cur, err, CONTRACT);
    }
    return {"ok": False, "osp": "", "agir": cur, "error": err};
}

def _compile_fresh(reg: Registry, sig: str, intent: str, task: str, version: int, origin: str) -> TaskGraph {
    # Author a FRESH AG-IR with the frontier for a KNOWN signature/version — the reusable
    # core behind first compilation AND relearn (which discards a degraded procedure
    # and re-authors from scratch, rather than revising it like mutate does).
    tools = digest(mcp_servers()) + chr(10) + builtin_catalogue();
    agir = author_agir(intent, task, ETHOS, tools, CONTRACT);
    low = _lower(agir, sig);
    if not low["ok"] {
        # Don't persist an empty module: it would later "run" as a no-op and surface
        # as a confusing small-model failure. Fail loudly with the real compile error.
        raise RuntimeError("compile '" + sig + "': AG-IR did not compile to a runnable procedure: " + str(low.get("error", "unknown")));
    }
    path = write_module(str(low["osp"]), sig, version, WORKDIR);
    return _persist(reg, sig, intent, str(low["agir"]), path, origin, version);
}

def compile_task(reg: Registry, intent: str, task: str) -> TaskGraph {
    # Frontier builds an AG-IR for the task CLASS (binding any registered MCP tools),
    # compiler lowers it (repairing on failure), we persist it as v1.
    sig = name_signature(task);
    return _compile_fresh(reg, sig, intent, task, 1, "frontier");
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
    # The source document rides every generation: a mutation that dropped
    # skill_src cut the whole lineage off from the skill it was compiled from,
    # and every later relearn re-authored from a task paraphrase instead.
    src = tg.skill_src if str(tg.skill_src).strip() else lineage_src(reg, tg.signature);
    nt = _persist(reg, tg.signature, tg.intent, str(low["agir"]), path, "mutation", v, skill_src=src);
    nt +>:MutatedFrom:+> tg;
    return nt;
}

# ---------------------------------------------------------------------------
# BYO MCP servers — registered on the graph (config), exposed to compiled
# agents via byLLM's native McpClient. Adding one takes effect on the next run.
# ---------------------------------------------------------------------------

def register_skill(source: str, kind: str) -> dict {
    soul = awaken();
    reg = [soul -->[?:Registry]][0];
    if kind == "agir" {
        # source is raw AG-IR text — compile only, no model call.
        sig = agir_name(source);
        osp = transpile_ir(source, sig);
        v = next_version(reg, sig);
        path = write_module(osp, sig, v, WORKDIR);
        tg = _persist(reg, sig, "registered AG-IR", source, path, "registered-agir", v);
    } elif kind == "osp" {
        # source is a path to a precompiled OSP .jac module — drop it in.
        sig = agir_name(source);
        v = next_version(reg, sig);
        path = install_osp(source, sig, WORKDIR, v);
        tg = _persist(reg, sig, "registered OSP module", "", path, "registered-osp", v);
    } else {
        # source is SKILL.md text — ONE compile pathway: the exact gated
        # compiler the `compile` verb runs (raise2 by default; SIGIL_FRONTEND
        # selects legacy/staged). register-skill is an alias for compile, not
        # a second engine — the old one-shot lift_skill slot and the
        # SIGIL_AI_LIFT side door are gone.
        r = compile_skill(source);
        if not r.get("ok") {
            raise RuntimeError("compile " + str(r.get("status", "failed")) + " for '"
                               + str(r.get("signature", "?")) + "':\n" + str(r.get("explain") or ""));
        }
        return {"signature": r["signature"], "version": r.get("version", 1),
                "origin": r.get("origin", "compiled-skill-raise2"), "module": r["module"]};
    }
    return {"signature": tg.signature, "version": tg.version, "origin": tg.origin, "module": tg.module};
}

# --- Compile progress, rendered once ---------------------------------------
# `compile_skill` reports each lift stage through a `progress` callback. Both
# front-ends (the CLI's live build view and chat's tool trace) want the same two
# strings out of an event, so they live here rather than being written twice and
# drifting apart.
def lint_skill(source: str, name: str = "") -> dict {
    # The SKILL LINTER pre-pass: extract the spec (the same loop compile runs)
    # and draft guarded fix suggestions for its findings. Returns
    # {"spec": SpecResult, "findings": list[LintFinding]} — the CLI reviews
    # findings with the human and, when nothing is accepted, hands "spec" back
    # to compile_skill (pre_spec) so extraction is not paid for twice.
    import from .compiler.ai.spec_loop { extract_spec, pin_lift_llm, strip_frontmatter }
    import from .compiler.ai.lint { lint_findings }
    awaken();
    pin_lift_llm(cur_frontier());
    body = strip_frontmatter(source);
    nm = name if name else agir_name(source);
    sr = extract_spec(body, nm);
    return {"spec": sr, "findings": lint_findings(body, sr)};
}

def compile_skill(source: str, eject: bool = False, eject_path: str = "",
                  progress: any = None, agent: bool = False,
                  skill_dir: str = "", strict: bool = False,
                  ask: any = None, frontend: str = "", pre_spec: any = None) -> dict {
    # `sigil compile SKILL.md [-e [out.jac]]` — the fix-forward AI lift:
    # spec loop -> spine -> flows -> assemble -> autofix chain + gates +
    # bounded repair. Only `failed` (no runnable module) refuses to persist —
    # the CLI prints the explain note. Anything runnable is SET IN THE TREE
    # (a TaskGraph on the Registry) with its findings riding the result;
    # `--strict` (or SIGIL_STRICT=1) restores fail-on-any-finding. skill_dir
    # lets the autofixes embody sibling files ("See FORMS.md") at compile time.
    # With eject, the module is ALSO written out as one runnable .jac program.
    # LAZY imports — see the register_skill note on the jac-test topology bug.
    import from .compiler.ai.lift { lift, pin_all_lift_llms, set_lift_progress }
    import from .compiler.ai.eject { eject_program, write_program }
    import from .compiler.ai.report { explain, strict_mode }
    soul = awaken();
    reg = [soul -->[?:Registry]][0];
    set_lift_progress(progress);
    sig = agir_name(source);
    # FRONT-END SELECTION. Default is raise2 (faithfulness-first). The legacy staged/
    # direct lift and the Claude agent author stay available behind flags:
    #   default            raise2
    #   --agent            agent_lift
    #   SIGIL_FRONTEND=legacy|staged   the pre-raise2 lift() (staged forces the spine pipeline)
    fe = frontend if frontend else os.environ.get("SIGIL_FRONTEND", "");
    if (not agent) and (fe not in ["legacy", "lift", "staged"]) {
        return _compile_raise2(source, sig, reg, eject, eject_path, progress, skill_dir, strict, ask, pre_spec,
                               next_version(reg, sig));
    }
    pin_all_lift_llms(cur_frontier());
    if fe == "staged" { os.environ["SIGIL_STAGED"] = "1"; }
    if agent {
        # `--agent`: keep the grounded spec loop and the gate battery, but let a
        # Claude Code session author the AG-IR against the compile oracle instead
        # of the staged slot pipeline. Opt-in — see compiler/ai/author_agent.jac
        # for what that trades away.
        import from .compiler.ai.author_agent { agent_lift }
        lr = agent_lift(source, sig, progress);
    } else {
        lr = lift(source, sig, skill_dir=skill_dir);
    }
    issues = lr.spec_issues + lr.spine_issues + lr.assemble_issues + lr.gate_issues;
    if (lr.status == "failed") or ((strict or strict_mode()) and not lr.ok) {
        return {"ok": False, "status": lr.status, "signature": sig, "issues": issues,
                "findings": lr.findings, "fixes": lr.fixes,
                "compile_errors": lr.compile_errors, "repairs": lr.repairs,
                "env": lr.env_report, "par": lr.par_report, "explain": explain(lr)};
    }
    v = next_version(reg, sig);
    path = write_module(lr.module_src, sig, v, WORKDIR);
    desc = skill_description(source);
    tg = _persist(reg, sig, desc if desc else "compiled from SKILL.md (AI compiler)",
                  lr.ir_text, path, "compiled-skill", v, skill_src=source);
    ejected = "";
    if eject {
        ep = eject_path if eject_path else (sig.replace("-", "_") + ".jac");
        ejected = write_program(eject_program(lr.module_src, sig), ep);
    }
    return {"ok": True, "status": lr.status, "signature": tg.signature, "module": tg.module,
            "issues": issues, "findings": lr.findings, "fixes": lr.fixes,
            "repairs": lr.repairs, "eject": ejected,
            "env": lr.env_report, "par": lr.par_report, "explain": explain(lr)};
}

def _compile_raise2(source: str, sig: str, reg: Registry, eject: bool, eject_path: str,
                    progress: any, skill_dir: str, strict: bool, ask: any,
                    pre_spec: any = None, version: int = 1, origin: str = "compiled-skill-raise2") -> dict {
    # The DEFAULT front-end: the faithfulness-first raise. Faithfulness FAILS the
    # compile (an agent that violates the skill is not a success); underspecified
    # modality is assumed MAYBE + warned, or asked inline via the TUI asker (`ask`,
    # provided by the CLI when --clarify is set). --strict additionally makes any
    # assumed-Maybe warning fatal (CI: force the author to make the skill specific).
    import from .compiler.ai.raise2 { raise2, explain2, pin_raise2_llms }
    import from .compiler.ai.eject { eject_program, write_program }
    import from .compiler.ai.report { strict_mode }
    pin_raise2_llms(cur_frontier());
    rr = raise2(source, sig, skill_dir=skill_dir, ask=ask, pre=pre_spec);

    findings: list = [];
    for d in rr.proof.dropped { findings.append({"gate": "faith", "severity": "error", "message": str(d.message)}); }
    for a in rr.proof.added { findings.append({"gate": "faith", "severity": "error", "message": str(a.message)}); }
    hard_warn = (strict or strict_mode()) and (len(rr.warnings) > 0);
    ok = rr.ok and (not hard_warn);
    note = explain2(rr);
    if rr.warnings {
        note = note + chr(10) + chr(10) + "skill quality:" + chr(10)
             + chr(10).join(["  " + str(w) for w in rr.warnings]);
    }
    if not ok {
        return {"ok": False, "status": rr.status, "signature": sig,
                "issues": [str(f["message"]) for f in findings],
                "findings": findings, "fixes": [], "repairs": rr.repairs,
                "warnings": rr.warnings, "compile_errors": rr.compile_errors,
                "env": [], "par": [], "explain": note};
    }
    path = write_module(rr.module_src, sig, version, WORKDIR);
    desc = skill_description(source);
    tg = _persist(reg, sig, desc if desc else "compiled from SKILL.md (raise2)",
                  rr.ir_text, path, origin, version, skill_src=source);
    ejected = "";
    if eject {
        ep = eject_path if eject_path else (sig.replace("-", "_") + ".jac");
        ejected = write_program(eject_program(rr.module_src, sig), ep);
    }
    return {"ok": True, "status": rr.status, "signature": tg.signature, "module": tg.module,
            "version": tg.version, "origin": tg.origin,
            "issues": [], "findings": findings, "fixes": [], "repairs": rr.repairs,
            "warnings": rr.warnings, "eject": ejected, "env": [], "par": [], "explain": note};
}


def clean_verdict(raw: str, known: list[str]) -> str {
    # The router's verdict is matched EXACTLY against known signatures, but
    # models decorate answers — "`sig`", quotes, a trailing period, a full
    # sentence. An exact matcher then reads a perfect HIT as a MISS and the
    # run detours into a fresh compile. Strip the decoration; if the reply is
    # prose that names exactly one known signature, take that signature.
    s = str(raw).strip();
    for q in ["`", "\"", "'"] { s = s.replace(q, ""); }
    s = s.strip().rstrip(".");
    if (s in known) or (s == "NONE") or s.startswith("MUTATE:") { return s; }
    hits = [k for k in known if k in s];
    if len(hits) == 1 {
        return ("MUTATE:" + hits[0]) if ("MUTATE" in s.upper()) else hits[0];
    }
    return s;
}

def select_target(reg: Registry, compiled_lib: list[TaskGraph], verdict: str, task: str) -> TaskGraph {
    # HIT -> existing procedure; PARTIAL -> mutate it; MISS -> compile a new one.
    if (verdict == "NONE") or (not compiled_lib) {
        return compile_task(reg, task, task);
    }
    if verdict.startswith("MUTATE:") {
        sig = verdict.split(":", 1)[1].strip();
        for c in compiled_lib { if c.signature == sig {
            return mutate(reg, c, task, "router flagged partial coverage");
        } }
        return compile_task(reg, task, task);
    }
    for c in compiled_lib { if c.signature == verdict { return c; } }
    return compile_task(reg, task, task);
}

def route_note(verdict: str, tg: TaskGraph) -> str {
    if verdict == "NONE" { return "MISS -> compiled " + tg.signature + " (frontier)\n"; }
    if verdict.startswith("MUTATE:") { return "PARTIAL -> mutated " + tg.signature + " v" + str(tg.version) + " (frontier)\n"; }
    return "HIT " + tg.signature + " -> run on small model\n";
}

# ---------------------------------------------------------------------------
# The one entry walker. Route -> (hit: run | miss: compile+run | partial:
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
        compiled_lib: list[TaskGraph] = latest_by_sig([reg -->][?:TaskGraph]);
        known = [c.signature for c in compiled_lib];
        # An explicitly NAMED skill is the route: `solve <task> <skill>` (the CLI's
        # second positional, the chat runner's use_skill) means THAT procedure.
        # Consulting the router anyway made the named skill a suggestion the
        # router could overrule — a deterministic pick, spelled out in the trace.
        if self.skill and (self.skill in known) {
            verdict = str(self.skill);
            self.trace += "route -> " + verdict + " (forced)\n";
        } else {
            verdict = clean_verdict(classify(self.task, known), known) if known else "NONE";
            self.trace += "route -> " + verdict + "\n";
        }

        tg: TaskGraph = select_target(reg, compiled_lib, verdict, self.task);
        self.trace += route_note(verdict, tg);
        self.signature = tg.signature;
        res = run_compiled(tg, self.task, ctx, self.skill);

        # --- escalation valve: cheap model fails -> frontier mutate + retry --
        if not res["ok"] {
            self.trace += "small-model FAIL -> frontier mutate + retry\n";
            tg = mutate(reg, tg, self.task, str(res["error"]));
            res = run_compiled(tg, self.task, ctx, self.skill);
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
                    self.trace += "eval FAIL -> relearn + retry\n";
                    prev = tg;
                    tg = _recompile(reg, prev, "", "relearn");
                    tg +>:MutatedFrom:+> prev;
                    self.signature = tg.signature;
                    res = run_compiled(tg, self.task, ctx, self.skill);
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
def solve_full_task(task: str, skill: str = "") -> dict {
    w = root spawn solve(task=task, skill=skill);
    return {"signature": w.signature, "result": w.result, "trace": w.trace};
}

with entry {
    # Register the compiling half with the core. An ejected runtime never runs
    # this module, so its seams stay unset and it routes HIT-or-honest-miss.
    set_solver(solve_full_task);
    set_compiler(compile_skill);
}


def eval_skill(signature: str, probe: str = "") -> dict {
    # Grounded verification: run the current skill on a probe task (defaults to the
    # skill's own intent) and score whether the output truly accomplishes it.
    awaken();
    reg = [root -->][?:Registry][0];
    tg = _find_skill(reg, signature);
    if tg is None { return {"ok": False, "error": "no such skill: " + signature}; }
    task = probe if probe else tg.intent;
    res = run_compiled(tg, task, "", "");
    ev = judge_result(task, str(res["report"]));
    tg.last_score = ev.score;
    tg.last_eval = ev.reason;
    return {
        "ok": True, "signature": signature, "version": tg.version,
        "score": ev.score, "passed": ev.passed, "reason": ev.reason,
        "result": str(res["report"])[:400]
    };
}

def _recompile(reg: Registry, tg: TaskGraph, hint: str = "", origin: str = "relearn") -> TaskGraph {
    # THE recompile pathway — one core behind manual `relearn` and the solve
    # loop's eval-triggered relearn, and it reuses the MAIN compiler: a skill
    # born from a SKILL.md re-enters the same gated raise the `compile` verb
    # runs (its stored source + optional guidance, version bumped); only a
    # task-born procedure (no source document) re-authors via the frontier
    # task compiler. Guidance rides the skill text itself, so the spec loop
    # grounds it like any other obligation.
    # Prefer the ORIGINAL skill document even when this version lost it: walk
    # the lineage for the newest surviving skill_src before falling back to
    # task-born re-authoring, which only paraphrases.
    src = tg.skill_src if str(tg.skill_src).strip() else lineage_src(reg, tg.signature);
    if str(src).strip() {
        if hint { src = src + "\n\n## Relearn guidance\n" + hint + "\n"; }
        r = _compile_raise2(src, tg.signature, reg, False, "", None, "", False, None, None,
                            tg.version + 1, origin);
        if not r.get("ok") {
            raise RuntimeError("recompile " + str(r.get("status", "failed")) + " for '"
                               + tg.signature + "':\n" + str(r.get("explain") or ""));
        }
        nt = _find_skill(reg, tg.signature);
        return nt if nt else tg;
    }
    intent = (tg.intent + "\nExtra guidance: " + hint) if hint else tg.intent;
    return _compile_fresh(reg, tg.signature, intent, tg.intent, tg.version + 1, origin);
}

def relearn(signature: str, hint: str = "") -> dict {
    # Discard the current (degraded) procedure and recompile it FROM SCRATCH —
    # same signature, bumped version, lineage kept. Manual counterpart to the
    # solve loop's automatic eval-triggered relearn; both ride _recompile.
    awaken();
    reg = [root -->][?:Registry][0];
    tg = _find_skill(reg, signature);
    if tg is None { return {"ok": False, "error": "no such skill: " + signature}; }
    nt = _recompile(reg, tg, hint, "relearn");
    nt +>:MutatedFrom:+> tg;
    return {"ok": True, "signature": signature, "version": nt.version, "origin": "relearn", "module": nt.module};
}


walker:pub api_solve {
    has task: str;
    has skill: str = "";
    can run with Root entry { report report_for("solve", {"task": self.task, "skill": self.skill}); }
}

walker:pub api_add_mcp {
    has name: str;
    has target: str;
    has transport: str = "stdio";
    has args: list[str] = [];
    can run with Root entry {
        report report_for("add_mcp", {"name": self.name, "transport": self.transport,
                                      "target": self.target, "args": self.args});
    }
}

walker:pub api_register_skill {
    has source: str;          # SKILL.md text / AG-IR text / OSP module path
    has kind: str = "md";     # md | agir | osp
    can run with Root entry { report report_for("register_skill", {"source": self.source, "kind": self.kind}); }
}

walker:pub api_teach {
    has fact: str;
    has kind: str = "fact";
    can run with Root entry { report report_for("teach", {"fact": self.fact, "kind": self.kind}); }
}

walker:pub api_soul {
    can run with Root entry { report report_for("soul", {}); }
}

walker:pub api_configure {
    has key: str;
    has value: str;
    can run with Root entry { report report_for("configure", {"key": self.key, "value": self.value}); }
}

walker:pub api_recall {
    has query: str;
    has k: int = 8;
    can run with Root entry { report report_for("recall", {"query": self.query, "k": self.k}); }
}

walker:pub api_library {
    can run with Root entry { report report_for("library", {}); }
}

walker:pub api_eval {
    has signature: str;
    has probe: str = "";
    can run with Root entry { report report_for("eval", {"signature": self.signature, "probe": self.probe}); }
}

walker:pub api_relearn {
    has signature: str;
    has hint: str = "";
    can run with Root entry { report report_for("relearn", {"signature": self.signature, "hint": self.hint}); }
}

walker:pub api_forget {
    has signature: str;
    can run with Root entry { report report_for("forget", {"signature": self.signature}); }
}

walker:pub api_mcp {
    can run with Root entry { report report_for("mcp", {}); }
}

walker:pub api_graph {
    can run with Root entry { report report_for("graph", {}); }
}

walker:pub api_observability {
    has n: int = 120;
    can run with Root entry { report report_for("observability", {"n": self.n}); }
}


# --- Ops surface: the dashboard's read (+tick) endpoints. Same seam as the
# rest — report_for runs each request against the agent's real graph. --------

walker:pub api_cron_list {
    can run with Root entry { report report_for("cron_list", {}); }
}

walker:pub api_cron_runs {
    has name: str;
    can run with Root entry { report report_for("cron_runs", {"name": self.name}); }
}

walker:pub api_cron_enable {
    has name: str;
    has on: bool = True;
    can run with Root entry { report report_for("cron_enable", {"name": self.name, "on": self.on}); }
}

walker:pub api_cron_remove {
    has name: str;
    can run with Root entry { report report_for("cron_remove", {"name": self.name}); }
}

walker:pub api_skill_agir {
    has signature: str;
    can run with Root entry { report report_for("skill_agir", {"signature": self.signature}); }
}

walker:pub api_tasks {
    has n: int = 30;
    can run with Root entry { report report_for("tasks", {"n": self.n}); }
}

walker:pub api_hooks {
    can run with Root entry { report report_for("hooks", {}); }
}

walker:pub api_channels {
    can run with Root entry { report report_for("channels", {}); }
}

walker:pub api_approvals {
    can run with Root entry { report report_for("approvals", {}); }
}
