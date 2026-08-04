"""AI compiler — the DIRECT front-end: one grounded frontier pass authors the AG-IR.

The staged pipeline (spine -> flows -> assemble) authors the AG-IR through many
slot calls and emits verbose, machine-assembled IR. Real-run verification of the
golden cookbook showed a frontier model, handed the authoring guide + a few
gate-clean golden examples + the FROZEN rule set, writes a leaner, correct AG-IR
in a single pass — with the same grounding, because the spec loop still runs in
front and the same gate battery still runs behind.

    STAGED:  spec loop -> spine -> flows -> assemble -> fix-forward tail
    DIRECT:  spec loop -> [ one frontier call: guide + goldens + frozen spec ] -> fix-forward tail
             ^^^^^^^^^                                                           ^^^^^^^^^^^^^^^^
             kept: grounding                                                     kept: the ladder

`lift()` defaults to DIRECT and falls back to STAGED when the direct pass fails
to compile or misses rule coverage. `_views_from_ir` reconstructs exactly the
view slice the gates read from the authored YAML — a parse, not a second opinion.
"""

import os;
import yaml;
import from pathlib { Path }
import from jaclang.byllm.lib { Model }
import from .spec_loop { RuleSet }
import from .workflow { AgirNode, WorkflowView }
import from .flows { ViewBundle, KnowledgeItem, KnowledgeView, ToolDef }
import from .ir_views { NodeType, Owner }

glob direct_llm: any = Model(model_name="gpt-4o-mini");
glob _DIRECT_PINNED: bool = False;

def pin_direct_llm(m: any) -> None {
    direct_llm = m;
    _DIRECT_PINNED = True;
}

# ---------------------------------------------------------------------------
# the authoring slot
# ---------------------------------------------------------------------------
sem author_agir_direct = """You are the front-end of the Sigil AG-IR compiler.
Author ONE AG-IR YAML document for the given SKILL, obeying the GUIDE exactly and
grounded in the FROZEN RULE SET. Keep it minimal and idiomatic: one node per
obligation, code tools where the work is mechanical (bind a builtin by name with
no body), model slots only for genuine judgment, carries typed across every
model->code boundary, never a carry named with a bare tool-parameter name. Every
MANDATORY STEP/IO rule id in the frozen set MUST appear in some node's traces_to.
Study the EXAMPLES for the exact shape. Output ONLY the raw AG-IR YAML (starting
with the '---' frontmatter) — no prose, no explanation, no markdown fences.""";
sem author_agir_direct.guide = "The complete AG-IR authoring guide. Obey it exactly.";
sem author_agir_direct.examples = "Gate-clean golden AG-IRs to mimic in shape and idiom.";
sem author_agir_direct.skill = "The SKILL.md being compiled.";
sem author_agir_direct.rules = "The frozen, grounded rule set the AG-IR is audited against.";
def author_agir_direct(guide: str, examples: str, skill: str, rules: str) -> str by direct_llm();

# ---------------------------------------------------------------------------
# guide + golden few-shot, resolved relative to this file (src/compiler/ai/)
# ---------------------------------------------------------------------------
def _docs_base() -> str {
    here = os.path.dirname(os.path.abspath(__file__));
    return os.path.abspath(os.path.join(here, "..", "..", ".."));
}

def _guide_text() -> str {
    p = Path(os.path.join(_docs_base(), "docs", "reference", "writing-ag-ir.md"));
    try { return p.read_text() if p.exists() else ""; } except Exception { return ""; }
}

# A code example (toolib + task-filename binding) and a model example (typed
# model->code boundary) — the two shapes that most anchor idiom without bloating
# the prompt. Env GOLDEN_FEWSHOT overrides the picks (comma-separated names).
glob _FEWSHOT_DEFAULT: list = ["word_frequency", "contact_to_csv"];

def _golden_fewshot() -> str {
    d = os.path.join(_docs_base(), "docs", "reference", "agir-cookbook");
    picks: list = _FEWSHOT_DEFAULT;
    env = os.environ.get("GOLDEN_FEWSHOT", "");
    if env { picks = [str(x).strip() for x in env.split(",") if str(x).strip()]; }
    blocks: list = [];
    for name in picks {
        p = Path(os.path.join(d, str(name) + ".agir"));
        if p.is_file() {
            blocks.append("# --- example: " + str(name) + " ---\n" + p.read_text());
        }
    }
    return "\n\n".join(blocks);
}

def _rules_md(spec: RuleSet) -> str {
    lines: list[str] = [
        "# Frozen rule set for '" + spec.skill_name + "'",
        "",
        "Already extracted and grounded: every quote appears verbatim in the skill.",
        "Every MANDATORY STEP/IO rule must appear in some node's `traces_to`.",
        ""
    ];
    for r in spec.rules {
        lines.append("- **" + r.id + "** · " + str(r.kind.name) + " · " + str(r.modality.name)
                     + (" · when: " + r.condition if r.condition else ""));
        lines.append("  > " + r.quote.replace("\n", " "));
    }
    if spec.sub_resources {
        lines.append("");
        lines.append("Sibling resources the skill delegates to: " + ", ".join(spec.sub_resources));
    }
    return "\n".join(lines);
}

def _strip_fence(s: str) -> str {
    t = str(s or "").strip();
    if t.startswith("```") {
        lines = t.splitlines()[1:];
        if lines and lines[-1].strip().startswith("```") { lines = lines[:-1]; }
        t = "\n".join(lines);
    }
    return t.strip();
}

# The public entry: one authoring pass. Returns {"ir_text": <IR or "">, "notes": [...]}.
def author_direct(skill: str, spec: RuleSet, name: str) -> dict {
    notes: list = [];
    guide = _guide_text();
    if not guide { notes.append("direct author: guide not found — authoring against sem only"); }
    examples = _golden_fewshot();
    ir: str = "";
    try {
        ir = _strip_fence(author_agir_direct(guide, examples, skill, _rules_md(spec)));
        notes.append("direct author: " + str(len(ir.splitlines())) + " IR lines");
    } except Exception as e {
        notes.append("direct author failed: " + str(e)[:200]);
        ir = "";
    }
    return {"ir_text": ir, "notes": notes};
}

# ---------------------------------------------------------------------------
# _views_from_ir — reconstruct the gate-read view slice from the authored YAML.
# (Duplicated from author_agent.jac to keep the DIRECT path free of the
# sigil_claude_cc / agent_run dependency the AGENT front-end carries.)
# ---------------------------------------------------------------------------
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
