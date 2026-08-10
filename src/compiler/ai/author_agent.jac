"""AI compiler — an ALTERNATE front-end: a Claude Code agent authors the AG-IR.

The gated LIFT front-end (spec_loop -> workflow -> flows -> assemble) authors the
AG-IR through byLLM slots, one narrow judgment at a time, because that is how you
keep an unfaithful skill from slipping through. This module keeps the part that
carries the guarantee and replaces the part that does not.

    LIFT:   spec loop -> spine -> flows -> assemble -> G1 · G4 · G5
    AGENT:  spec loop -> [ a Claude Code session writes agent.ir ] -> G1 · G4 · G5
            ^^^^^^^^^                                                ^^^^^^^^^^^^
            kept: grounding                                          kept: the gates

What is kept is the **spec loop** — every rule must quote the skill verbatim, so a
hallucinated obligation is dropped mechanically — and the **gate battery**, run
against whatever the agent produced. What is replaced is the staged authoring: an
agent with a workspace and the compile oracle on the command line can draft, run
`sigil gate`, read the diagnostic and iterate, which is a loop no single slot call
can do.

The trade is real and it is the reason this is opt-in (`--agent`): LIFT's view
repair routes each issue back to the flow that owns it, and its coverage critics
hunt for dropped obligations across several rounds. Here there is one agent and
three gates. It is faster and it uses one subscription instead of a frontier key —
it is not more trustworthy. Honest framing: **agent-authored, gate-verified.**

The gates need view objects that LIFT builds as it goes and an authored IR does
not carry, so `_views_from_ir` reconstructs exactly the slice they read —
deterministically, from the YAML. Nothing here re-judges the IR; parsing is not
authoring.
"""

import os;
import shutil;
import tempfile;
import time;
import yaml;
import from pathlib { Path }
import from .lift_types { Modality, RuleKind }
import from .ir_views { LiftResult, NodeType, Owner }
import from .spec_loop { extract_spec, strip_frontmatter, RuleSet, Rule }
import from .workflow { AgirNode, WorkflowView }
import from .flows { ViewBundle, KnowledgeItem, KnowledgeView, ToolDef }
import from .gates { compile_gate, gate_standalone, gate_struct_cov }
import from .report { finding, auto_gate, status_of }
import from .repair { repair_compile_loop, _sigil_bin }
import from src.sigil_claude_cc { agent_run, AUTHOR }
import from src.sigil_runtime { repo_root }

# The full alphabet the mechanical half accepts. Partial coverage here would be
# worse than useless: an unmapped type silently becomes GEN_RAW, i.e. a CODE node
# the compiler gates by construction would be read back as a model slot.
glob _NODE_TYPES: dict[str, NodeType] = {
    "GEN-RAW": NodeType.GEN_RAW, "GEN-ENUM": NodeType.GEN_ENUM,
    "GEN-FILL": NodeType.GEN_FILL, "GEN-EDIT": NodeType.GEN_EDIT,
    "ROUTE": NodeType.ROUTE, "LOOP": NodeType.LOOP, "SPAWN": NodeType.SPAWN,
    "CALL": NodeType.CALL, "SENSE": NodeType.SENSE, "ACT": NodeType.ACT,
    "CODE": NodeType.CODE, "TERMINAL": NodeType.TERMINAL
};


def _as_list(v: any) -> list[str] {
    if isinstance(v, list) { return [str(x) for x in v]; }
    if v is None { return []; }
    return [str(v)];
}


def _views_from_ir(ir_text: str) -> tuple[WorkflowView, ViewBundle] {
    # Rebuild the slice of LIFT's views the gates actually read:
    #   G5 wants node id / owner / traces_to;  G1 wants tool body|command and
    #   knowledge content. Everything else stays default — this is a parse, not
    #   a second opinion about the IR.
    body = str(ir_text or "");
    if body.lstrip().startswith("---") {
        parts = body.lstrip().split("---", 2);
        if len(parts) >= 3 { body = parts[2]; }
    }
    try { ir = yaml.safe_load(body) or {}; } except Exception { ir = {}; }
    if not isinstance(ir, dict) { ir = {}; }

    nodes: list[AgirNode] = [];
    for raw in (ir.get("nodes") or []) {
        if not isinstance(raw, dict) { continue; }
        nodes.append(AgirNode(
            id=str(raw.get("id", "")),
            ntype=_NODE_TYPES.get(str(raw.get("type", "GEN-RAW")).upper(), NodeType.GEN_RAW),
            owner=(Owner.CODE if str(raw.get("owner", "model")).lower() == "code" else Owner.MODEL),
            doc=str(raw.get("doc", "")),
            reads=_as_list(raw.get("reads")),
            writes=_as_list(raw.get("writes")),
            surface=str(raw.get("surface", "")),
            traces_to=_as_list(raw.get("traces_to"))
        ));
    }

    tools: list[ToolDef] = [];
    raw_tools = ir.get("tools") or {};
    if isinstance(raw_tools, dict) {
        for (tname, td) in raw_tools.items() {
            if not isinstance(td, dict) { td = {}; }
            tools.append(ToolDef(
                name=str(tname), sig=str(td.get("sig", "")), surface=str(td.get("surface", "")),
                serves=_as_list(td.get("serves")), body=str(td.get("body", "") or ""),
                command=str(td.get("command", "") or ""), traces_to=str(td.get("traces_to", "") or "")
            ));
        }
    }

    knowledge: list[KnowledgeItem] = [];
    raw_kn = ir.get("knowledge") or {};
    if isinstance(raw_kn, dict) {
        for (kkey, ki) in raw_kn.items() {
            content = str(ki.get("content", "") or "") if isinstance(ki, dict) else str(ki or "");
            resident = _as_list(ki.get("resident_on")) if isinstance(ki, dict) else [];
            knowledge.append(KnowledgeItem(key=str(kkey), content=content, resident_on=resident));
        }
    }

    return (WorkflowView(nodes=nodes), ViewBundle(kn=KnowledgeView(tools=tools, knowledge=knowledge)));
}


def _rules_md(spec: RuleSet) -> str {
    # The frozen rule set as the agent's anchor. Ids matter most: they are what a
    # node's `traces_to` names, and what G5 audits against.
    lines: list[str] = [
        "# Frozen rule set for '" + spec.skill_name + "'",
        "",
        "Already extracted and grounded: every quote below appears verbatim in",
        "SKILL.md. This is the contract your AG-IR is audited against. Every",
        "MANDATORY STEP/IO rule must appear in some node's `traces_to`.",
        ""
    ];
    for r in spec.rules {
        lines.append("- **" + r.id + "** · " + str(r.kind.name) + " · " + str(r.modality.name)
                     + (" · when: " + r.condition if r.condition else "")
                     + (" · binds: " + r.binds if r.binds not in ["", "agent"] else ""));
        lines.append("  > " + r.quote.replace("\n", " "));
        if r.statement { lines.append("  = " + r.statement.replace("\n", " ")); }
        for al in r.aliases { lines.append("  ~ also stated as: " + str(al).replace("\n", " ")); }
    }
    if spec.sub_resources {
        lines.append("");
        lines.append("Sibling resources the skill delegates to: " + ", ".join(spec.sub_resources));
    }
    return "\n".join(lines);
}


def _must_trace(spec: RuleSet) -> list[str] {
    out: list[str] = [];
    for r in spec.rules {
        if r.modality != Modality.MANDATORY { continue; }
        if (r.kind != RuleKind.STEP) and (r.kind != RuleKind.IO) { continue; }
        if r.binds not in ["", "agent"] { continue; }   # not the agent's to perform
        out.append(r.id);
    }
    return out;
}


def _brief(name: str, must: list[str]) -> str {
    return (
        "Author the AG-IR for this skill.\n\n"
        + "Read, in this order:\n"
        + "  1. `writing-agir/SKILL.md` — how to write an AG-IR. Follow it.\n"
        + "  2. `SKILL.md` — the skill you are compiling.\n"
        + "  3. `rules.md` — the frozen rule set your IR is audited against.\n"
        + "  4. `agir-template.md` — the compiler-exact YAML shape.\n\n"
        + "Write `agent.ir`, then verify it:\n\n"
        + "    " + _sigil_bin() + " gate agent.ir " + name + "\n\n"
        + "Run that after every edit; it is the compile oracle, and it exits "
        + "nonzero while the IR is broken. Keep going until it prints `gate: ok`.\n\n"
        + "These MANDATORY rules must each appear in some node's `traces_to`, or "
        + "the coverage gate rejects the IR:\n    "
        + (", ".join(must) if must else "(none)") + "\n\n"
        + "Edit `agent.ir` only. When the gate passes and every rule above is "
        + "traced, stop and reply with the single word DONE."
    );
}


def _stage(work: str, skill: str, spec: RuleSet, name: str) -> None {
    # The workspace IS the agent's context: the meta-skill, the skill, the frozen
    # rules, and the contract. Nothing else is on its path.
    Path(os.path.join(work, "SKILL.md")).write_text(skill);
    Path(os.path.join(work, "rules.md")).write_text(_rules_md(spec));
    Path(os.path.join(work, "agent.ir")).write_text("");
    contracts = os.path.join(repo_root(), "contracts");
    os.makedirs(os.path.join(work, "writing-agir"), exist_ok=True);
    shutil.copy(os.path.join(contracts, "writing-agir", "SKILL.md"),
                os.path.join(work, "writing-agir", "SKILL.md"));
    for ref in ["agir-template.md", "agir-standard.md", "agir-primitives.md"] {
        src = os.path.join(contracts, ref);
        if os.path.exists(src) { shutil.copy(src, os.path.join(work, ref)); }
    }
}


def author_agir(skill: str, spec: RuleSet, name: str) -> dict {
    # Run the authoring session. Returns {"ir_text": <authored IR or "">, "notes": [...]}.
    # Never raises into the compile: a failed session is an empty IR and an issue.
    work = tempfile.mkdtemp(prefix="sigil_author_");
    notes: list[str] = [];
    out: str = "";
    try {
        _stage(work, skill, spec, name);
        r = agent_run(
            prompt=_brief(name, _must_trace(spec)),
            cwd=work,
            model=os.getenv("SIGIL_CLAUDE_FRONTIER", "claude-cc/opus"),
            max_turns=int(os.getenv("SIGIL_CLAUDE_AUTHOR_TURNS", "80")),
            persona=AUTHOR
        );
        out = Path(os.path.join(work, "agent.ir")).read_text();
        notes.append("author session: " + str(r.get("num_turns", "?")) + " turns, "
                     + str(len(out.splitlines())) + " IR lines, $"
                     + ("%.3f" % float(r.get("total_cost_usd") or 0.0)));
    } except Exception as e {
        notes.append("author session failed: " + str(e)[:200]);
        out = "";
    } finally {
        try { shutil.rmtree(work); } except Exception {  }
    }
    return {"ir_text": out, "notes": notes};
}


def agent_lift(skill: str, name: str, progress: any = None) -> LiftResult {
    # The `--agent` front-end, shaped to return the same LiftResult as lift() so
    # compile_skill persists and ejects it through the identical path.
    def _emit(ev: dict) -> None {
        if progress {
            try { progress(ev); } except Exception {  }
        }
    }

    _t0 = time.time();
    _emit({"stage": "spec", "state": "start"});
    skill = strip_frontmatter(skill);
    sr = extract_spec(skill, name);
    _emit({"stage": "spec", "state": "done", "secs": time.time() - _t0,
           "rules": len(sr.spec.rules), "rounds": sr.verdict.rounds,
           "sound": sr.verdict.sound, "complete": sr.verdict.complete,
           "drift": sr.verdict.drift});
    spec_issues: list = [];
    if not sr.verdict.sound { spec_issues.append("spec not sound: dropped " + ", ".join(sr.verdict.ungrounded)); }
    if not sr.verdict.complete { spec_issues.append("spec incomplete: uncovered " + " | ".join(sr.verdict.uncovered)); }
    if sr.verdict.drift { spec_issues.append("modality drift: " + " | ".join(sr.verdict.drift_notes)); }

    _t1 = time.time();
    _emit({"stage": "author", "state": "start"});
    au = author_agir(skill, sr.spec, name);
    ir_text: str = str(au["ir_text"]).strip();
    notes: list = list(au["notes"]);
    _emit({"stage": "author", "state": "done", "secs": time.time() - _t1,
           "lines": len(ir_text.splitlines())});
    if not ir_text {
        return LiftResult(ok=False, status="failed", spec_issues=spec_issues,
                          gate_issues=["author: the agent produced no AG-IR"],
                          findings=[finding("compile", "author: the agent produced no AG-IR")],
                          repairs=notes);
    }

    # Same oracle, same bounded repair loop the gated front-end uses — but with
    # the agent escalation disarmed. The authoring session has ALREADY iterated
    # against this oracle; letting the repair loop spawn a second session to fix
    # what the first one left would double the cost to re-run the same loop.
    _t2 = time.time();
    _emit({"stage": "gates", "state": "start"});
    prev_esc = os.environ.get("SIGIL_CLAUDE_REPAIR", "");
    os.environ["SIGIL_CLAUDE_REPAIR"] = "";
    try {
        ro = repair_compile_loop(ir_text, name);
    } finally {
        os.environ["SIGIL_CLAUDE_REPAIR"] = prev_esc;
    }
    for a in ro.attempts { notes.append(a); }
    g4 = ro.verdict;
    ir_text = ro.ir_text;

    (wf, vb) = _views_from_ir(ir_text);
    gate_issues: list = gate_standalone(vb);
    if g4.ok {
        sc = gate_struct_cov(sr.spec, wf, g4.module_src);
        for i in sc.issues { gate_issues.append(i); }
    }
    _emit({"stage": "gates", "state": "done", "secs": time.time() - _t2,
           "g4": g4.ok, "repairs": len(ro.attempts)});

    findings: list = [finding(auto_gate(str(g), "G1"), str(g)) for g in gate_issues]
                   + [finding("spec", str(s)) for s in spec_issues];
    status = status_of(g4.ok, findings, [], notes);
    ok = g4.ok and (not spec_issues) and (not gate_issues);
    return LiftResult(
        ok=ok, ir_text=ir_text, module_src=g4.module_src, compile_errors=g4.errors,
        spec_issues=spec_issues, gate_issues=gate_issues, repairs=notes,
        status=status, findings=findings
    );
}
